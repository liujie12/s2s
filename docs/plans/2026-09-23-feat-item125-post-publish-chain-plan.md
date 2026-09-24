# [125] post 发布链后端实现（media 两步直传 + precheck + POST /posts + 完整度三档 + 乐观锁）

**Created:** 2026-09-23
**artifact_contract:** ce-unified-plan/v1
**artifact_readiness:** implementation-ready
**product_contract_source:** ce-plan-bootstrap
**execution:** code

---

## Goal Capsule

**Objective（结果）**：后端 `post` 域从空包变为可落库的发布链路——前端已完的发布页（分支 `item/124-frontend-publish`，527/527）能与真服务端到端联调，`POST /media/upload/ticket` → `POST /media/{id}/commit` → `POST /posts/precheck` → `POST /posts` 四接口全路径可调用。

**Means（选定路线）**：在 `common/geo` 落地 `GridIdCalculator`（KTD1），`post` 域新增 entity/mapper/service/controller/dto 五类文件；OSS 用真阿里云 SDK（KTD2）；图片审核 Batch1 用 Noop 立即 `pass`（KTD3）。复用 [123] 已建的 `SensitiveWordChecker` 接口、`CryptoFacade`、`ErrorCode` 枚举。

**权威层级**：DDL（`V1__init_schema.sql`）> 详设后端 §5.3/§5.4 > openapi 契约 > 本计划。

**停止条件**：任一验收点出现「设计文档未覆盖的口径」时停，先问用户，禁在业务代码自创口径（编码规范红线）。

---

## Product Contract

### Summary

实现 post 域四接口 + 两个基础设施件，覆盖发布链路全部后端侧行为：媒体两步直传（OSS 直传票据 + commit 二次校验）、发布预检（不落库、blocks 一次性给全）、发布落库（contact 双列加密 + grid_id + 完整度三档 STORED 生成列 + 乐观锁 version）。

### Problem Frame

[121] 工程初始化、[122] 横切链、[123] auth 域、[124] category 域已完成。`post` 域当前只有 `package-info.java` 占位，`/posts`、`/media/*` 全 404。前端发布页已按 openapi 契约用 mock 跑通（527/527），但无真服务可联调。发布是五大 P0 闭环（账号→发布→地图→详情→联系）的第二环，不落地发布，后续 [126] 地图、[127] 详情、[128] 联系全部无法真链路验证。

### Requirements

#### R1: OSS 直传票据签发（`POST /media/upload/ticket`）

- **入参**：`filename` / `size` / `content_type`（enum `image/jpeg`、`image/png`、`image/webp`）
- **校验**：`content_type` ∉ 白名单 或 `size` > 上限 → `40001`
- **行为**：服务端生成 `media_id` 与 `object_key`（客户端不可指定）→ INSERT `post_media`（`post_id=NULL` 孤儿行，`audit_status='pending'`）→ 返回带签名的短时效 `upload_url`（真 OSS SDK 签名）
- **安全**：客户端不持长期密钥；桶不开公共读，`url` 均为带签名临时地址

#### R2: 媒体提交确认（`POST /media/{media_id}/commit`）

- **入参**：路径 `media_id`
- **行为**：`HeadObject` 二次校验实际 `size` 与 `content-type`（不信客户端）→ 审核任务（Batch1 Noop → `audit_status='pass'`）→ 原图删除与本次 commit **同事务**同步完成（禁 `@Async`）→ 返回 `MediaCommitResult`
- **硬规则**：`audit_status != pass` 的 `media_id` 不得出现在任何非本人可见响应中（`MediaAssembler.toDto(entity, isOwner)` 视角分流，禁在 controller 判视角）
- **同事务**：commit 后对象不可覆写

#### R3: 发布预检（`POST /posts/precheck`）

- **行为**：校验项与 `POST /posts` 完全一致但**不写库**；通过时 `data.passed=true`；发现问题仍返回 200 + `code=0`，由 `data.blocks[]` 一次性列出全部阻断项
- **阻断项**：敏感词 `40901`、图片未过审 `40902`、类目禁发 `40303`、高敏类目资质 `40302`、未实名发布上限 `40304`
- **出参**：`PrecheckResult{passed, blocks[{code,message,field}], completeness_level, derived{required_full,address_precise,leaf_matched}}`

#### R4: 发布帖子（`POST /posts`）

- **入参**：`PostCreateRequest`（必填 `type`/`leaf_category_id`/`title`/`lng`/`lat`/`contact_type`/`contact_value`）
- **落库派生字段（客户端传了也被忽略）**：`l2_category_id`（STORED `leaf_category_id DIV 100`）、`completeness_level`（STORED 三条件计数映射）、`grid_id`（`GridIdCalculator.of(lng,lat)`）、`expire_at`（now + `NfrPostLifecycle.validDays`）、`version`（初始 0）
- **流程（十步）**：幂等+参数校验 → 类目校验（banned→`40303`；sensitive 且无资质→`40302`）→ 未实名上限（`40304`，Batch1 开关关）→ 敏感词全文过滤→`40901` → 媒体校验（media_ids 全部属当前用户；`reject`→`40902`，`pending`/`pass` 放行）→ `grid_id` 计算 → contact 双列加密（AAD=`post_id`，**先 INSERT 拿 id 再 UPDATE 密文**）→ 三条件写 `completeness_conditions` → `expire_at` 计算 → 异步埋点 `post_published`
- **contact 加密**：`CryptoFacade.encrypt(contact_value, aad=post_id)` → `contact_value_enc` + `key_version`（**无 `contact_hash` 列**，见 KTD4）
- **出参**：`PostDetail`（必带 `version`，不含完整联系方式）

#### R5: grid_id 计算（`GridIdCalculator`）

- 算法（三方逐位一致，整数微度域）：`floor(x*100000 + FLOOR_EPSILON)/100000` → `floorDiv(micro, 450)` → `"{gx}_{gy}"`，`STEP_MICRO=450`、`FLOOR_EPSILON=1e-9`
- 10 条测试向量（含第 9 条中间微度断言 `-2`）全绿；算法落 `common/geo/GridIdCalculator.java`

#### R6: 完整度三档

- `completeness_level` 为 STORED 生成列，由 `completeness_conditions` JSON 三布尔（`required_full`/`address_precise`/`leaf_matched`）计数映射 `3→2 / 2→1 / else→0`
- 服务端写入 `completeness_conditions`，生成列自动派生；**STORED 列不入 insert/update SQL**（否则 `ERROR 3105`）

#### R7: 敏感词 / 图片审核接线

- 敏感词：`SensitiveWordChecker.check(text)`（Noop 桩，[123] 已建）作用于 `title`+`desc`+`attributes` → `40901`
- 图片审核：`post.MediaService.isRejected(mediaId)`（查 `post_media.audit_status='reject'`）→ `40902`；`pending`/`pass` 放行（对齐 openapi「pending 允许提交发布」）

#### R8: 乐观锁

- `post.version` `@Version`；`PATCH /posts/{id}/status` 缺 `version` → `40001` **不兜底**；更新影响 0 行 → `40903`（本条目仅落 `version` 初始化 0 + 乐观锁异常映射；`PATCH /posts/{id}/status` 完整实现属 [127]）

### Scope Boundaries

#### In Scope

- `common/geo/GridIdCalculator`（+10 向量单测）
- `common/constants/NfrPost` / `NfrMedia` 常量类
- `post` 域 entity/mapper/service/controller/dto 全套
- OSS 客户端（真阿里云 SDK）+ media 两步直传
- precheck + POST /posts
- 完整度三档、乐观锁 version 初始化、contact 双列加密

#### Out of Scope

- `GET /posts/{id}`、`PATCH /posts/{id}/status`、`GET /posts/mine`（[127]）
- `/map/pins`、`/posts/search`、`GridIdCalculator` 三端对拍（[126]）
- contact 解密 `GET /posts/{id}/contact`（[128]，`CryptoFacade` 解密调用点）
- AI 域真实敏感词/图片审核（Batch2）
- cert 真 SDK（Batch2）
- 前端发布页改动（已完，另分支收口）

#### Deferred to Follow-Up Work

- openapi.yaml 字段命名修正（`attributes`→`template_values`、`description`→`desc`、删除 `contact_hash` 描述，见 KTD4）
- OSS 真桶联调（需真 Bucket + AK/SK 与用户侧环境就绪）

### Key Decisions

#### KD1: GridIdCalculator 落地 [125]（session-settled: user-directed）

- **决策**：`common/geo/GridIdCalculator.java` 随 [125] 落地，[126] 只做三端 10 向量对拍
- **chosen over**: 严格按 backlog 留在 [126]、[125] 临时内联
- **reason**: POST /posts 发布时必须算 `grid_id`；共享逻辑下沉 `common`，避免重复实现与 [126] 返工

#### KD2: OSS 用真阿里云 SDK（session-settled: user-directed）

- **决策**：media 两步直传接真阿里云 OSS SDK（签名 URL、`HeadObject`、对象删除）
- **chosen over**: dev 桩（mock 票据/HeadObject）
- **reason**: 用户定案；「原图删除同事务」的失败注入测试通过 mock OSS 客户端接口覆盖，不因真 SDK 而缺测

#### KD3: 图片审核 Batch1 立即 pass（session-settled: user-directed）

- **决策**：media commit 后 `audit_status` 立即置 `pass`（Noop 审核）
- **chosen over**: 置 `pending`（审核中）
- **reason**: Batch1 无真实审核任务，置 `pending` 会让发布链卡死；`40902` 路径用 mock 注入测试覆盖

### Success Criteria

- [ ] 四接口（ticket/commit/precheck/`POST /posts`）可调用（curl 实测，OSS 用 dev 桩兜底验收，真 SDK 代码路径完整）
- [ ] `GridIdCalculator` 10 向量全绿（含第 9 条中间微度 `-2` 断言）
- [ ] `POST /posts` 落库后 `l2_category_id`/`completeness_level` 由 STORED 生成列正确派生
- [ ] contact 密文 `CryptoFacade.encrypt` 往返一致（AAD=`post_id`）
- [ ] 敏感词/图片审核/类目禁发/资质/上限 五条阻断项全路径可触发
- [ ] `mvn test` 全绿（基线只增不减）

---

## Planning Contract

### Key Technical Decisions

#### KTD1: GridIdCalculator 整数微度域实现

- **位置**：`src/main/java/com/s2s/server/common/geo/GridIdCalculator.java`
- **签名**：`public static String of(double lng, double lat)`
- **算法**（详设 §5.4.1 逐字）：
  - `floorToMicroDegree(deg) = (long) Math.floor(deg * 100_000d + FLOOR_EPSILON)`（`Math.floor` 非 `(long)` 截断——第 9 条向量依赖；`FLOOR_EPSILON=1e-9` 补偿 `0.00450` 的 FP 误差，第 3 条向量依赖）
  - `gx = Math.floorDiv(lngMicro, STEP_MICRO)`，`STEP_MICRO = 450`
  - 返回 `gx + "_" + gy`
- **常量**：步长 `450` 微度、精度 `100_000` 须为命名常量，禁写死数字（红线「不复制字面量」）
- **测试**：10 向量全绿，第 9 条额外断言中间微度 `-2`

#### KTD2: OSS 客户端抽象与真 SDK

- **接口**：`post/OssClient`（`signUploadUrl` / `headObject` / `processImage`（剥离 EXIF 生成展示图）/ `deleteObject`），真实现 `AliyunOssClient` 接阿里云 SDK
- **依赖**：`pom.xml` 新增阿里云 OSS SDK 依赖（版本以 `context7`/官方 Maven 仓库为准，禁编造）
- **凭证**：`s2s.secrets.oss-access-key-id/secret`（[121] 已占位，`SecretsProperties` 已绑定）
- **失败注入**：`deleteObject` 抽象成接口方法，测试用 mock 抛异常验证「原图删除同事务回滚」（KTD6）
- **Batch1 联调开关**：保留 dev 直传开关（若真桶未就绪，dev 环境可切桩，但**生产路径为真 SDK**）

#### KTD3: STORED 生成列只读映射

- `PostEntity` 上 `l2CategoryId`、`completenessLevel` 标注只读（`@TableField(insertStrategy=NEVER, updateStrategy=NEVER)` 或等效）
- `insert`/`update` SQL 中**不出现**这两列名（否则 `ERROR 3105`）
- 单测断言：MyBatis 生成的 insert 语句列清单不含 `l2_category_id`/`completeness_level`（§7.2 ⑥）

#### KTD4: contact 双列范式（无 contact_hash）

- `post` 表 contact 仅 `contact_value_enc VARBINARY` + `key_version TINYINT`（DDL 权威，无 `contact_hash` 列）
- **依据**：contact 按 `post_id` 1:1 查询，无需等值盲索引；openapi 描述里的 `contact_hash` 是陈旧笔误
- **加密**：`CryptoFacade.encrypt(contact_value, aad=post_id)` → 密文落 `contact_value_enc`、版本落 `key_version`
- **顺序陷阱**（详设 §5.3.2 第 7 步）：AAD 绑定 `post_id`，须同事务「INSERT（`contact_value_enc` 写空 `byte[]` 占位、`key_version=0`）→ 取自增 id → UPDATE 真实密文」（`contact_value_enc`/`key_version` 均 NOT NULL，禁写 NULL）
- **AAD 格式**：`String.valueOf(postId)`（无前缀/后缀，编码规范 §4.8「联系方式 post_id」）；[128] 解密用同一格式逐字节一致
- **命名漂移**（契约 vs DDL，实现须显式映射）：openapi `attributes`→DDL `template_values`、`description`→DDL `desc`、`attributes` 三条件→DDL `completeness_conditions`。DTO 用契约名，Entity 用 `@TableField` 显式映射 DDL 列名

#### KTD5: 发布校验组件复用（precheck 与 POST 共享）

- 五条校验（敏感词/图片/类目禁发/资质/上限）抽为独立 `PostValidator`，`precheck` 与 `POST /posts` 共用
- `precheck` 收集全部阻断项入 `blocks[]`（不抛异常、不逐条打断）；`POST /posts` 命中即抛对应 `BizException`
- 敏感词 `SensitiveWordChecker`（Noop）复用 [123] 接口；图片 `MediaService.isRejected`（post 域 reject 判定，不复用 auth 域 `MediaAuditChecker`）

#### KTD6: 原图删除同事务（剥离 EXIF + 生成展示图 + 删原图）

- **语义**（安全方案 §5.2/§5.3，🔴 阻塞 P0）：commit 链路「客户端直传含 GPS 原图 → 服务端剥离 GPS/设备/拍摄时间生成展示图 → 删除含 GPS 原图 → commit 返回」；删原图与 commit 同一 `@Transactional` 方法同步完成，禁 `@Async`/消息队列/定时补偿
- **图片处理机制**（session-settled: user-directed）：阿里云 OSS 图片处理（服务端 style）剥离 EXIF 生成展示图；原图删除走 `deleteObject`
- **失败注入测试**：mock `OssClient` 处理/删除抛异常 → 断言 commit 整体回滚（`post_media` 无残留）（§7.2 ⑩）
- **自检**（安全方案 S5）：含 GPS 照片 commit 后 `curl '<展示图 URL>?x-oss-process=image/info'` 无 GPS 字段；原图对象名访问 404/403

#### KTD7: 完整度三条件计算

- `required_full`：模板必填字段全部有值（对齐 `template` 的 `required` 标记）
- `address_precise`：`address` 精确到门牌（入参 `address_precise` 布尔）
- `leaf_matched`：`leaf_category_id` 为合法叶子节点（非中间节点）
- 三布尔写入 `completeness_conditions` JSON，`completeness_level` 由生成列派生

#### KTD8: post_media 归属列（session-settled: user-directed）

- **决策**：V2 Flyway 迁移给 `post_media` 加 `user_id BIGINT NOT NULL`，ticket 签发写 owner，commit/发布按 `WHERE id=? AND user_id=当前用户` 校验归属
- **chosen over**: object_key 编码归属
- **reason**: 最标准可审计，直接支撑「media 属当前用户」校验与「非本人不可见」视角分流（`MediaAssembler.toDto(entity, isOwner)` 的 isOwner 由 user_id 判定）

### Assumptions

- contact 无 `contact_hash` 列（DDL + 详设权威，openapi 描述为陈旧笔误）
- Batch1 敏感词检测为 Noop（`40901` 路径用 mock 注入测试覆盖）
- 未实名发布上限（`40304`）Batch1 由开关关闭（同 `40301`，cert 域延后致全员 `realname_status='none'`）；开关配置键需新增（现有 `system_config` 无发布上限键，见 Open Questions）
- `NfrPostLifecycle.validDays=7` 来自 Dart `nfr_constants.dart`，Java 侧建 `NfrPost` 常量类镜像（单源真源，不复制字面量）
- OSS 真桶联调依赖用户侧环境（真 Bucket + AK/SK）；curl 实测用 dev 桩兜底验收，真 SDK 代码路径完整实现（session-settled: user-directed）
- 媒体校验谓词：`reject → 40902`（`pending` 允许提交发布，对齐 openapi 三态双视角）；`MediaService` 实现 reject 判定，不复用 auth 域 `MediaAuditChecker`（其 `!= pass` 语义与 post 域冲突）

### Open Questions

- `40304` 发布上限开关的配置键命名与落库方式（V2 迁移 seed 新键 vs 代码常量短路）——**延后到 [127] 状态机一并处理**（session-settled: user-directed，2026-09-23）

### Dependencies

| 依赖 | 状态 | 说明 |
| --- | --- | --- |
| [124] category 域 | ✅ 完成 | `category_version`/`TemplateService` 可复用 |
| [123] crypto 基础件 | ✅ 完成 | `CryptoFacade`/`BlindIndex` 复用 |
| [123] moderation 接口 | ✅ 完成 | `SensitiveWordChecker` 接口 + Noop 桩（图片 reject 判定由 post 域 `MediaService` 自实现） |
| [122] 横切链 | ✅ 完成 | 幂等拦截器（`POST /posts` 幂等键）、限频 |
| 阿里云 OSS SDK 依赖 | ⚠️ 待加 | `pom.xml` 新增，版本以官方仓库为准 |
| OSS 真桶环境 | ⚠️ 用户侧 | 真桶联调阻塞，dev 桩兜底 |

---

## Implementation Units

### Unit Index

| U-ID | 标题 | 文件 | 依赖 |
| --- | --- | --- | --- |
| U1 | 持久层 entity/mapper | `post/entity/PostEntity`、`post/entity/PostMediaEntity`、`post/mapper/*` | 无 |
| U2 | GridIdCalculator + Nfr 常量 | `common/geo/GridIdCalculator`、`common/constants/NfrPost`、`NfrMedia` | 无 |
| U3 | post 域 DTO + 契约对齐 | `post/dto/*`（6 个） | 无 |
| U4 | media 两步直传 + OSS 客户端 | `post/OssClient`、`post/MediaService`、`post/MediaController` | U1、U2 |
| U5 | 发布校验（precheck + 校验组件） | `post/PostValidator`、`post/PrecheckService`、`post/PostController`（precheck） | U1、U3、U4 |
| U6 | POST /posts 发布主链 | `post/PostService`、`post/PostController`（createPost） | U1、U2、U3、U5 |
| U7 | 集成测试 + 安全断言 + 契约示范 | `post/*IntegrationTest`、`test/contract/post_contract_test.dart` | U4、U5、U6 |

### U1. 持久层 entity/mapper

**Goal:** 建立 `post`/`post_media` 两张表的 entity 与 mapper，STORED 生成列只读映射。

**Requirements:** R6（STORED 列）、R8（version 乐观锁）

**Files:**
- `src/main/java/com/s2s/server/post/entity/PostEntity.java`
- `src/main/java/com/s2s/server/post/entity/PostMediaEntity.java`
- `src/main/java/com/s2s/server/post/mapper/PostMapper.java`
- `src/main/java/com/s2s/server/post/mapper/PostMediaMapper.java`
- `src/main/resources/db/migration/V2__add_post_media_user_id.sql`（`post_media` 加 `user_id BIGINT NOT NULL`）

**Approach:**
- `PostEntity` 逐列对齐 `V1__init_schema.sql` `post` 表（`type`/`status`/`contact_channel`/`audit_status` 用 String，`DATETIME`→`LocalDateTime`，`JSON`→String 或 JsonNode，`DECIMAL`→BigDecimal，`TINYINT`→Integer）
- `l2CategoryId`、`completenessLevel` 标注只读（`@TableField(insertStrategy=FieldStrategy.NEVER, updateStrategy=FieldStrategy.NEVER)`），确保 insert/update SQL 不含这两列
- `version` 标 `@Version`（乐观锁）
- `contactValueEnc` 用 `byte[]`（映射 `VARBINARY`）、`keyVersion` Integer
- 命名漂移映射：`@TableField("template_values") templateValues`、`@TableField("desc") desc`

**Test scenarios:**
- MyBatis 生成 insert SQL 的列清单不含 `l2_category_id`/`completeness_level`（§7.2 ⑥）
- `post_media` entity 字段与 DDL 逐列对齐（含 `audit_status` 三态）

**Verification:** `mvn test` 全绿；entity 能带数据源启动。

### U2. GridIdCalculator + Nfr 常量

**Goal:** 落地 `GridIdCalculator`（10 向量全绿）与 post/media NFR 常量类。

**Requirements:** R5（grid_id）、R4（expire_at 常量）

**Files:**
- `src/main/java/com/s2s/server/common/geo/GridIdCalculator.java`
- `src/main/java/com/s2s/server/common/constants/NfrPost.java`
- `src/main/java/com/s2s/server/common/constants/NfrMedia.java`
- `src/test/java/com/s2s/server/common/geo/GridIdCalculatorTest.java`

**Approach:**
- `GridIdCalculator` 按详设 §5.4.1 整数微度域实现，步长/精度为命名常量
- `NfrPost`：`VALID_DAYS=7`（镜像 Dart `NfrPostLifecycle.validDays`）
- `NfrMedia`：`MAX_MEDIA_COUNT=9`、`ALLOWED_CONTENT_TYPES={image/jpeg,image/png,image/webp}`、`MAX_SIZE_BYTES=20MB`（session-settled: user-directed，2026-09-23）

**Test scenarios:**
- 10 条测试向量全绿
- 第 9 条 `(-0.000015,-0.000015)` 额外断言中间微度 `-2`（暴露 `(long)` 截断错误）

**Verification:** `GridIdCalculatorTest` 10/10 绿。

### U3. post 域 DTO + 契约对齐

**Goal:** 建立 post 域全部 DTO，字段与 openapi 契约逐字对齐（snake_case JSON）。

**Requirements:** R1、R2、R3、R4 的出入参结构

**Files:**
- `src/main/java/com/s2s/server/post/dto/UploadTicket.java`
- `src/main/java/com/s2s/server/post/dto/MediaCommitResult.java`
- `src/main/java/com/s2s/server/post/dto/PostDraft.java`
- `src/main/java/com/s2s/server/post/dto/PostCreateRequest.java`
- `src/main/java/com/s2s/server/post/dto/PrecheckResult.java`
- `src/main/java/com/s2s/server/post/dto/PostDetail.java`

**Approach:**
- record + `@JsonNaming(SnakeCaseStrategy)` + Bean Validation（对齐 [123] DTO 范式）
- `PostDraft` 字段全部非必填（供 precheck 半成品）；`PostCreateRequest` 继承并声明必填项
- 契约名→DDL 名漂移在 Entity 层映射，DTO 层保持契约名（`attributes`/`description`）

**Test scenarios:** `Test expectation: none — DTO 无逻辑，字段对齐由 U7 契约示范测试覆盖`

**Verification:** DTO 字段与 openapi 契约逐字对齐（人工对稿 + U7 契约测试）。

### U4. media 两步直传 + OSS 客户端

**Goal:** 实现 ticket 签发 + commit 二次校验，OSS 用真阿里云 SDK，原图删除同事务。

**Requirements:** R1、R2、R7（图片审核 MediaService）

**Files:**
- `src/main/java/com/s2s/server/post/OssClient.java`（接口）
- `src/main/java/com/s2s/server/post/AliyunOssClient.java`（真实现）
- `src/main/java/com/s2s/server/post/MediaService.java`（含 media reject 判定 + 归属校验）
- `src/main/java/com/s2s/server/post/MediaAssembler.java`（`toDto(entity, isOwner)` 视角分流）
- `src/main/java/com/s2s/server/post/MediaController.java`（`createUploadTicket`、`commitMedia`）
- `pom.xml`（改：阿里云 OSS SDK 依赖）
- `src/test/java/com/s2s/server/post/MediaServiceTest.java`

**Approach:**
- `createUploadTicket`：校验 content_type ∈ 白名单、size ≤ 上限（→`40001`）→ 生成 `media_id`+`object_key`（`object_key` 用 UUID 随机，禁含客户端 filename）→ INSERT `post_media`（`post_id=NULL`，`audit_status='pending'`，写 `user_id`）→ 签名 `upload_url`
- `commitMedia`：`@Transactional` → `HeadObject` 二次校验 → 归属校验（`WHERE id=? AND user_id=当前用户`）→ OSS 图片处理剥离 EXIF 生成展示图 → Noop 审核置 `audit_status='pass'` → 删除含 GPS 原图同事务（KTD6）
- `MediaService` 提供 `isRejected(mediaId)`（查 `post_media.audit_status='reject'` 抛 `40902`，`pending`/`pass` 放行）；归属校验按 `user_id`

**Test scenarios:**
- content_type 不在白名单 → `40001`；size 超限 → `40001`
- commit `HeadObject` 实际 size 与声明不符 → 拒绝
- commit 成功 → `audit_status='pass'`
- 原图删除同事务回滚：mock `OssClient` 处理/删除抛异常 → 断言事务回滚（§7.2 ⑩）
- `isRejected` 对 `reject` 媒体抛 `40902`；`pending`/`pass` 放行
- 归属校验：非本人 `user_id` 的 media_id 提交/发布被拒

**Verification:** `MediaServiceTest` 全绿；commit 事务回滚注入测试通过。

### U5. 发布校验（precheck + 校验组件）

**Goal:** 实现五条阻断项校验 + `POST /posts/precheck`（不落库、blocks 一次性给全）。

**Requirements:** R3、R7

**Files:**
- `src/main/java/com/s2s/server/post/PostValidator.java`
- `src/main/java/com/s2s/server/post/PrecheckService.java`
- `src/main/java/com/s2s/server/post/PostController.java`（`precheckPost` 方法）
- `src/test/java/com/s2s/server/post/PrecheckServiceTest.java`

**Approach:**
- `PostValidator` 五校验：敏感词（`SensitiveWordChecker`→`40901`）、图片（`MediaService.isRejected`→`40902`）、类目禁发（`CategoryService` banned→`40303`）、高敏资质（sensitive 且无资质→`40302`）、未实名上限（`40304`，开关关）
- `precheck` 收集全部阻断项入 `blocks[]`，仍返回 200 + `code=0`；`derived` 返回三条件预演算

**Test scenarios:**
- 命中多阻断项 → `blocks[]` 一次性含全部（不逐条打断）
- 无阻断 → `passed=true`、`blocks=[]`
- 敏感词 mock 命中 → block code `40901`
- 类目 banned → `40303`；高敏无资质 → `40302`

**Verification:** `PrecheckServiceTest` 全绿；五条阻断项全路径可触发。

### U6. POST /posts 发布主链

**Goal:** 实现发布落库十步流程，contact 双列加密 + grid_id + 完整度三档 + 乐观锁。

**Requirements:** R4、R5、R6、R8

**Files:**
- `src/main/java/com/s2s/server/post/PostService.java`
- `src/main/java/com/s2s/server/post/PostController.java`（`createPost` 方法）
- `src/test/java/com/s2s/server/post/PostServiceTest.java`

**Approach:**
- 十步流程按详设 §5.3.2 逐条实现（幂等 → 类目 → 上限 → 敏感词 → 媒体 → grid_id → contact 加密 → 三条件 → expire_at → 埋点）
- contact 加密：同事务「INSERT（`contact_value_enc` 写空 `byte[]` 占位）→ 取自增 id → UPDATE 真实密文」，AAD=`String.valueOf(postId)`（KTD4）
- `completeness_conditions` JSON 写入三布尔（KTD7），`completeness_level` 由生成列派生
- `version` 初始 0（`@Version` 自动）；埋点 `post_published` 异步产出

**Test scenarios:**
- 发布成功 → `PostDetail` 必带 `version=0`，`l2_category_id`/`completeness_level` 正确派生
- contact 密文 `CryptoFacade.encrypt(contact_value, aad=post_id)` 往返一致
- 敏感词 mock 命中 → `40901`；媒体未过审 → `40902`
- 类目禁发 → `40303`；高敏无资质 → `40302`
- 乐观锁 `version` 初始 0；后续 `PATCH` 缺 version → `40001`（[127] 完整实现，本单元素初始化 + 异常映射）
- 幂等：同 `Idempotency-Key` 重放返首次结果

**Verification:** `PostServiceTest` 全绿；curl 实测发布落库。

### U7. 集成测试 + 安全断言 + 契约示范

**Goal:** 补齐跨层集成测试、§7.2 安全断言、前端契约示范测试（baseUrl 切真服务断言不改）。

**Requirements:** R1–R8 全链路

**Files:**
- `src/test/java/com/s2s/server/post/PostIntegrationTest.java`
- `test/contract/post_contract_test.dart`（前端契约示范）

**Approach:**
- 后端集成测试覆盖：STORED 生成列不入 insert/update（§7.2 ⑥）、原图删除同事务回滚（§7.2 ⑩）、五条阻断项全路径、乐观锁 0 行→`40903`、contact 密文无 `contact_hash` 列写入
- 前端契约示范测试 baseUrl 切真服务，断言一行不改（[123] 契约范式）

**Test scenarios:**
- 集成测试扫描 insert/update SQL 无 STORED 列名
- 原图删除 mock 失败 → 事务回滚，`post_media` 无残留
- 五条阻断项端到端可触发（`40901`/`40902`/`40303`/`40302`/`40304`）
- 契约示范测试真服务断言一行不改

**Verification:** `mvn test` + `flutter test test/contract/` 全绿。

---

## Verification Contract

- **后端**：`mvn test` 全绿（基线只增不减；[123] 收口时 163/163，本条目新增 post 域测试后只增）
- **后端静态**：`ErrorCode` 总数仍 25、无重复、`code/100==httpStatus`（§7.2 ① 不因本条目破坏）
- **前端契约**：`flutter test test/contract/post_contract_test.dart` baseUrl 切真服务，断言一行不改
- **守门**：G-Q2 密钥扫描通过（OSS AK/SK 不入库）；G-Q1 后门码登记（若有 debug 桩）
- **不适用**：`release:validate`（本条目为后端，不出前端 release 包）

## Definition of Done

- [ ] 四接口真服务可调用，curl 实测发布落库成功
- [ ] `GridIdCalculator` 10 向量全绿（含第 9 条中间微度断言）
- [ ] STORED 生成列不入 insert/update（§7.2 ⑥ 单测断言通过）
- [ ] 原图删除同事务回滚失败注入测试通过（§7.2 ⑩）
- [ ] 五条阻断项（`40901`/`40902`/`40303`/`40302`/`40304`）全路径可触发
- [ ] contact 密文 AAD=`post_id` 往返一致，无 `contact_hash` 列写入
- [ ] 乐观锁 `version` 初始 0，缺 version → `40001` 不兜底
- [ ] `mvn test` 全绿（基线只增不减）
- [ ] 无废弃/实验代码残留（干净 diff）
- [ ] 说明文档进度记录更新（[125] 标记完成 + 结果说明）
