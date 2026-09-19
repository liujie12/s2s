# 编码规范（找鸭找 · s2s）

> 版本：v1.1（2026-09-09）
> 适用范围：Batch1 全部前后端代码 —— 后端 `com.s2s.server`（Java 21 + Spring Boot 3，工程待初始化）与前端 [lib/](file:///d:/developer/code/aicoding/s2s/lib)（Flutter / Dart，改造既有工程）。
> 定位：**只汇编已定案的编码纪律，不新设计口径**。每条标注依据源章节名（不写行号）；与依据源冲突时以依据源为准，先回写本规范再编码。

---

## 0. 总则

### 0.1 依据源

| 简称 | 文档 | 简称 | 文档 |
| --- | --- | --- | --- |
| 详设 | [前后端详细设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/design/前后端详细设计文档.md) | 部署 | [部署架构设计文档.md](file:///d:/developer/code/aicoding/s2s/deploy/docs/部署架构设计文档.md) |
| 架构 | [系统总体架构设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/系统总体架构设计文档.md) | 数据库 | [数据库设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/database/数据库设计文档.md) |
| 技术栈 | [技术栈选型说明.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/技术栈选型说明.md) | 契约 | [openapi.yaml](file:///d:/developer/code/aicoding/s2s/docs/api/openapi.yaml) |
| 安全 | [系统安全设计方案.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/系统安全设计方案.md) | PRD | [PRD.md](file:///d:/developer/code/aicoding/s2s/docs/PRD.md) |
| 可观测 | [可观测性架构方案.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/可观测性架构方案.md) | 常量真源 | [nfr_constants.dart](file:///d:/developer/code/aicoding/s2s/lib/nfr_constants.dart) |
| DevSecOps | [DevSecOps接入方案.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/DevSecOps接入方案.md) | | |

### 0.2 三条全局硬纪律（违反以缺陷论处）

| 纪律 | 落地要求 | 出处 |
| --- | --- | --- |
| **不复制字面量** | 阈值、TTL、上限、超时、批次大小只引用常量名：Dart 用 `NfrPerf`/`NfrCache`/`NfrApi` 等，Java 在 `common` 建同名常量类逐一对应 | 详设 §0.1 |
| **不新增错误码** | 唯一口径源 PRD §12.5（24 错误码 + `0` = 25 枚举）；代码侧禁止占号，新增只能由需求侧在 PRD 定案 | 详设 §0.1、§2.3 |
| **不凭位置信重试** | 重试/重放/重发靠显式「containsKey 才写」保全 `Idempotency-Key` 与 `X-Interaction-Id`，不得依赖拦截器顺序——两种 dio 行为下只有显式判断恒对 | 详设 §11.1.1 |

### 0.3 未覆盖主题

先查依据源；依据源也没有的，按 §10「通用基线（非项目定案）」执行，**不得在业务代码中自创口径**。

---

## 1. 组件抽提与代码复用（反冗余硬要求）

### 1.1 总原则

1. **同一逻辑出现第 2 次前必须提取为共享实现**，禁止复制-粘贴改名字。逻辑包括：常量、正则、分支判断、序列化映射、键拼装、异常映射、限频/幂等/解密等横切动作。
2. 提取落点按复用半径分层，禁止越级：
   - 跨域复用 → 后端 `common/`、前端 `lib/core/`；
   - 域内复用 → 域内私有方法/类，**不上浮**到 common；
   - 跨端同算法（grid_id、缓存键五要素、错误码表）→ 双端各一份实现，靠**共用测试向量/对照单测**保证逐位一致（这是跨语言镜像，双端各有唯一实现处，不算冗余）。
3. **禁止防御性复制**：把 common 组件代码抄进业务域、把 `lib/core` 工具抄进 feature，发现即缺陷。

### 1.2 唯一实现处清单（业务代码只准调用，不准内联重写）

**后端（详设 §1.2、§2、§3、§4）：**

| 组件 | 唯一职责 |
| --- | --- |
| `ResponseBodyWrapper` | 唯一响应套壳与 `request_id` 注入处；controller 直接返 DTO，禁手写 `ApiResponse.ok(...)` |
| `GlobalExceptionHandler` | 唯一异常→错误码映射处；**唯一写 `Retry-After` 头的位置** |
| `ErrorCode` | 唯一错误码定义处 |
| `IdempotencyInterceptor` | 唯一幂等判定处（Key 校验、SETNX、首次响应缓存） |
| `RateLimiter` + `RateLimitKeys` | 唯一限频计数与键命名处 |
| `CryptoFacade` | **全系统唯一解密入口**（Batch1 调用点 == 1）；`BlindIndex`/`AeadCipher` 为唯一加解密原语 |
| `GridIdCalculator` | 唯一网格算法（Java 侧） |
| `AuditLogWriter` | 唯一 `audit_log` 写入处 |

**前端（详设 §10–§17）：**

| 组件 | 唯一职责 |
| --- | --- |
| `HeaderInterceptor` | 唯一请求头注入处（三头 containsKey 才写、Authorization 每次重写） |
| `AuthRefreshInterceptor` | 唯一 40101 单飞续期处 |
| `RetryInterceptor` | **全局唯一重试点**；`lib/features/` 禁 `for` 循环重试 |
| `EnvelopeInterceptor` / `unwrap` | 唯一拆信封处（先拆信封再判 code） |
| `ApiErrorCode` | 唯一错误码与行为映射处；各 catch 点禁自造处理 |
| `gridIdOf` | 唯一网格算法（Dart 侧） |
| `buildPinCacheKey` | 唯一 Pin 缓存键拼装处 |
| `TrackReporter.buildBatch` | 唯一埋点组批处（含批次换新键例外） |
| `NfrXxx` 常量类 | 唯一 NFR 阈值承载处 |

### 1.3 反冗余验收口径（机器可判优先）

| 判定动作 | 期望 |
| --- | --- |
| 静态扫描 `lib/features/` | 无 `for` 循环重试（详设 §14.2） |
| 静态扫描 `lib/` | `values.byName` 零命中（详设 §10.3） |
| 静态扫描 `gridIdOf` 所在文件 | 无 `~/`、无 `.toInt()`（详设 §16.3） |
| 后端调用点计数 | `CryptoFacade.decrypt` == 1；业务代码写 `Retry-After` header 零命中；controller 手写 `ApiResponse` 包装零命中 |
| 代码评审 | PR 中出现与 §1.2 组件职责重叠的代码、或复制字面量，直接打回 |

---

## 2. 命名与注释

### 2.1 命名

- 【双端】描述性英文命名，禁 `fn p()` 式神秘命名与单字母变量（循环下标除外）。
- 【双端】功能域前后端**同名同构**：后端包 `auth/category/post/map/contact/notify/cert/ai/track/task` ↔ 前端 `lib/features/<同名>/`，新增域两侧同时命名（详设 §1.3、§10.1）。
- 【双端】对外 JSON 一律 `snake_case` 与 OpenAPI 逐字一致；Dart 字段 camelCase，映射只写在 `fromJson`（详设 §2.1、§10.3）。
- 【SQL/数据】表列名以 DDL 为准；已裁定沿用 `post_media`（详设 §21 #3）。

### 2.2 注释（强制）

- 【双端】**所有函数必须有函数级注释**：功能描述、参数（`[param]`/`@param`）、返回值类型及用途；密度照抄详设代码范式。
- 【双端】注释解释「为什么」而非「做什么」；引用设计决策处带章节号（范式见 `nfr_constants.dart` 每个常量带 PRD 章节号）。
- 【后端】定时任务类注释写明「单实例前提：扩多实例须引入分布式锁」（详设 §6）。
- 【前端】`TrackReporter` 类注释写明「埋点批次每次组批换新幂等键」这一唯一例外（详设 §11.1.1、§17.4.1）。
- 【SQL/数据】每条 XML 查询附 EXPLAIN 结论注释，无结论视为未完成（详设 §7、技术栈 §7）。

---

## 3. 常量、错误码与配置

### 3.1 常量真源

- 【双端】NFR 阈值只存在于常量真源：Flutter `lib/nfr_constants.dart`（`const Xxx._();` + `static const`）；Java 在 `common` 建对应常量类，**值从 Dart 真源逐一抄录并注章节号**，业务代码一律引用（详设 §0.1）。
- 【双端】有效期、配额等业务天数只引用常量（如 `NfrPostLifecycle`），禁新造天数。
- 【例外登记】限频阈值 `RateLimitThresholds`（`common/constants`）为<b>服务端单端正源</b>——Dart 真源无 `NfrRateLimit` 类，因客户端被禁止本地预测剩余次数（§5.9「限频文案不承诺剩余次数」），阈值在 Dart 端无消费方，故不建 Dart 镜像，直接以详设 §3.4 键表为真源抄录（[122] KTD11，唯一允许 Java 独有 NFR 数字常量的类）。

### 3.2 错误码（详设 §2.3、§12；契约）

- 【后端】`ErrorCode(code, httpStatus, message, needRetryAfter)`；`code/100 == httpStatus`；`needRetryAfter=true` 共 **8 个**（`40105`、`42901`–`42907`）抛异常必须带剩余秒数，缺即实现缺陷。
- 【后端】`40305` 后台 RBAC 专用（App 端不返回）；`42906` 唯一不向用户呈现；`42907` 仅未登录请求生效。
- 【前端】`ApiErrorCode` = 24 服务端码 + `ok` + 本地负数码 `networkFailure(-1)` / `parseError(-2)`；行为映射 `autoRetry`/`promptWithRetryAfter`/`silentRequeue`/`forceRefetch`/`deterministicFail`/`refreshToken`（详设 §12.2 五类行为）。
- 【双端】总数、无重复、码对齐 HTTP 由单测断言（§7.2）。

### 3.3 配置与密钥（安全 §4/§10；部署；技术栈 §3/§5/§6）

- 【配置/出包】六类凭证（DB 密码、Redis 密码、HMAC pepper 列表、AEAD 主密钥列表、OSS AK/SK、短信/高德 Key）**不入仓库、不入镜像**；`application-*.yml` 只允许 `${VAR:?}` 占位，缺变量**启动快速失败**。
- 【配置/出包】`.env` 权限 600 不入库，禁写 `app.crypto.*` 带点号键名；`.env.example` 变量名与 yml `${}` 名**逐一对应**。
- 【后端】密钥按 `key_version` 列表结构绑定（`HMAC_PEPPERS_JSON`/`AEAD_MASTER_KEYS_JSON`）；pepper 独立介质备份，不与 DB 备份同介质。
- 【配置/出包】Dockerfile 禁 `COPY .env`（部署 G2）；compose 不映射端口；Redis 必 `requirepass`；对外 TLS ≥ 1.2。
- 【前端】高德 Key 仅 `--dart-define` 构建期注入，仓库只留占位，缺失走 `FallbackMapCanvas`（详设 §18.1）。
- 【后端】Maven 依赖显式版本，禁 `LATEST`/`RELEASE`/版本范围；版本由 `spring-boot-starter-parent` 托管（技术栈 §3）。
- 【前端】`pubspec.lock` 入库；CI 锁 Flutter 3.41.9 / Dart 3.11.5；`analysis_options.yaml` 仅 `include: package:flutter_lints/flutter.yaml`；依赖决策理由写在 `pubspec.yaml` 依赖旁。
- 【后端】MySQL 8.4 用 `binlog_expire_logs_seconds`（禁用 `expire_logs_days`）；Redis 锁 `maxmemory 128MB` + `volatile-lru` + AOF `everysec`；会话/Token/幂等键显式 TTL，不当唯一存储（兜底是 DB 唯一约束）（技术栈 §5/§6）。

---

## 4. 后端工程规范

### 4.1 底座与包结构（详设 §1；技术栈 §3）

- 单体单进程单模块，功能域垂直切分；**Java 21 不开虚拟线程**（退出条件：Java 24 或压测证明 I/O 阻塞）；单实例 `@Scheduled`，不引分布式锁。
- 根包 `com.s2s.server`，结构按详设 §1.2 逐字落地；`common` 三组件**必须先于第一个业务接口落地**（先写业务后补必返工）。

### 4.2 分层与域边界（详设 §1.3）

- 域内分层固定 `controller/service/mapper/entity/dto`（`map`、`track` 无 entity）；controller 只接参与返 DTO，mapper 只做数据访问。
- 域间只调对方 **service**，**禁跨域 mapper**；`common` 只被依赖、无 `@RestController`；循环依赖零容忍（下沉 common）。

### 4.3 响应包与异常（详设 §2.1、§2.2）

- 全部接口（含 `POST /track/events`，无例外）走 `ApiResponse<T>(code,message,data,requestId)` record；snake_case；失败 `data` 恒 null。
- 异常映射：`BizException`→取其 ErrorCode；Bean Validation/缺头→`40001`（message 拼字段名）；乐观锁 0 行→`40903`；其余→`50001`（**日志打全栈、响应体无堆栈**）。

### 4.4 横切链（详设 §3.1，顺序不可调换）

`RequestIdFilter → AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor → Controller`（限流必先于幂等）。`42907` 判定点在鉴权上下文**之后**：带有效 Token 的详情请求跳过该限频。

### 4.5 两个 ID 分工（详设 §3.2）

`interaction_id`：客户端生成、`X-Interaction-Id` 头、**仅日志串联**，严禁用于鉴权/限流/幂等。`request_id`：服务端生成、响应体字段、UI 报错唯一回显值；缓存命中时可不存在，不得判异常。

### 4.6 幂等（详设 §3.3；契约）

- Redis 键 `idem:{userId}:{key}`，TTL 引用 `NfrApi.idempotencyWindowHours`，值为首次**成功**响应完整 JSON。
- Key 正则：`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`；缺失/大写/v1 → `40001`，不放行。
- `SETNX` 占位；并发/重放轮询取首次响应**原样返回**（故意不校验请求体差异）；仅成功入缓存，失败**删占位键**（同 Key 重放重新执行）。

### 4.7 限频（详设 §3.4）

- 账号级一律 `user_id`（联系/AI/举报/熔断/埋点），不用手机号；渠道级（短信、登录失败）未登录无 `user_id` 时保留手机号维度。
- 限频响应**不区分命中维度**（账号/设备/IP/熔断），风控信息不外泄；`429` 段与 `40105` 必带整数秒 `Retry-After`。
- 埋点：强制登录态、`user_id` 只取登录态（请求体传了也忽略）、60 请求/min、单请求 ≤50 事件，超限 `42906`。
- 限频计数键允许 Redis 丢失（防滥用非账务）。

### 4.8 加解密（详设 §4；安全 §4）

- 双列范式：`xxx_hash BINARY(32)`（HMAC-SHA256+pepper，盲索引/唯一索引）+ `xxx_enc VARBINARY`（AES-GCM-256 随机 IV）+ `key_version TINYINT`；禁裸 SHA-256。
- 身份证 Batch1 只存 `id_card_hash` + `id_card_last4`，不存完整明文。
- AAD 绑定：身份 `user_id+identity_type`、真实姓名 `user_id`、联系方式 `post_id`；AAD 不匹配必须解密失败且有单测。
- `CryptoFacade` 唯一解密入口；每次解密**同步同事务**写 `audit_log`；Batch1 调用点仅 `ContactService#viewContact`，新增即架构变更须评审。

### 4.9 数据访问（详设 §7、§5.8）

- 不写外键；生成列 STORED 且**禁入 insert/update SQL**（否则 `ERROR 3105`）；禁跨库 JOIN；Flyway 管 schema；简单 CRUD 用 MyBatis-Plus，性能语句 XML + EXPLAIN。
- 乐观锁：`post.version` `@Version`；`PATCH /posts/{id}/status` 缺 `version` 返 `40001` **不兜底**；0 行→`40903`。
- 媒体 commit 服务端二次校验不信客户端；原图删除与业务写**同事务**、禁 `@Async`，须失败注入测试。
- 埋点落库固定写法：

```sql
INSERT INTO track_event_YYYYMM (...) VALUES (...)
ON DUPLICATE KEY UPDATE id = id
```

  严禁 `INSERT IGNORE`、严禁 `UPDATE props=VALUES(props)`；`ts` 用客户端上报值（`DATETIME(3)`），禁替换为服务端到达时刻；按 `ts` 归月表，缺表写 fallback。

### 4.10 定时任务（详设 §6，编号沿用原表）

- **#1** 到期下架守 `status IN ('active')`，**不守 version**；
- **#2** 月表预建必须 `CREATE TABLE ... LIKE`（逐列拼 DDL 漏 `uk_event_dedup`）；
- **#3** 过期月表整表 `DROP`（不用 DELETE）；
- **#7** 注销按 `user_id` 删**全部身份行**；
- **#9** 24h pending 媒体清理连 OSS 孤儿对象一起清。

### 4.11 日志与审计（可观测 §3/§4）

- 应用日志 JSON 单行落盘，必备 8 字段：`ts`（RFC3339 UTC）、`level`、`request_id`、`interaction_id`、`user_id`、`path`、`code`、`rt_ms`；配滚动与保留上限。
- **硬禁令**：日志不得出现完整手机号/身份证号/联系方式与 `Authorization` 头；审计白名单剔除 `phone/real_name/id_card/contact_value/*_enc/*_hash`；`audit_log` 与 `contact_event` 不互替。
- `rt_ms`（服务端）与 `duration_ms`（客户端）不互相顶替；同 `interaction_id` 的 `t_net_ms` 与 `rt_ms` 差 ≤50ms 由服务端交叉核对。
- `restart_window` 服务端启动自写（详设 §21 #1）。日志级别规则见 §10 通用基线。

### 4.12 输入校验（详设 §5.3/§5.4；契约）

- `page` 从 1 起；`page_size` 默认 20 上限 50；`/map/pins` 上限 500 Pin；响应 gzip ≤10KB、原始 ≤24KB。
- `/map/pins` 缓存键五要素缺任一 → `40001`，不做默认值兜底。
- 越权统一 `40305`（不用 404/裸 403）；敏感词 `40901`、图片驳回 `40902` 仅本人可见、禁发类目 `40303`；`unresolved_fields` 留空禁猜值；EXIF 强制剥离。

---

## 5. 前端工程规范

### 5.1 目录与依赖（详设 §10）

- 改造既有工程；新增 `lib/core/network/`（api_client、5 拦截器、api_exception、api_error_code）、`lib/core/cache/`、`lib/core/track/`。
- 不引第二个 HTTP 客户端；`mem_peak_mb` 不引库（Android 平台通道、iOS 报空）；不引 `json_serializable`/`freezed`，DTO 全手写。
- 不采集 IMEI/MAC/IDFA/OAID；设备标识用首次启动自生成 UUID（存 shared_preferences），注释标注「不可信、可被重置」。

### 5.2 DTO 与模型（详设 §10.3、§10.4）

- 可空性与 schema `required` 逐字对齐；**禁 `?? 默认值` 掩盖可空**；枚举显式 `switch` + `default` 降级，禁 `values.byName`；解析失败抛 `ApiException(parseError)`（message 含实际收到值），不返 null 不静默吞。
- 语义迁移：`category_id` 接受 `10101`；禁 `int get id => index`；`topCategoryOf` 找不到返 `null` 用中性配色兜底；该路径必须 release 包（或 `--no-enable-asserts`）验证；`supplyDemandFromApi` 两条 case 都有单测；`Listing.id` 为 `int`；`toApiRadius(city)=='city'` 且 ≠ `'null'`。

### 5.3 dio 五拦截器（详设 §11，顺序定死）

发出向：`HeaderInterceptor → GzipInterceptor → EnvelopeInterceptor → AuthRefreshInterceptor → RetryInterceptor`。

- 三头 containsKey 才写（`X-Interaction-Id`/`X-Device-Id`/`Idempotency-Key`）；`Authorization` 唯一每次重写，未登录不注入（不注入空串）。
- 幂等键仅 POST/PATCH 注入、GET 不注入；`X-Interaction-Id` 由交互起点生成、方法参数逐层透传（不用 Zone/全局变量），拦截器仅缺失时兜底。
- `unwrap` 先拆信封再判 code；`data=null`、`request_id=null` 均非错误；`Retry-After` 按整数秒 `int.tryParse`，失败回退默认退避。
- UI 报错唯一格式 `{message}（{request_id}）`；`request_id` 为 null 只显 message，**禁用 interaction_id 顶替**。
- gzip 是否手动注入为编码期第一天实测项，默认**不注入**，结论回写详设 §11.5。

### 5.4 错误码行为与续期（详设 §12、§13）

- `40101` 单飞续期：并发 401 只触发 **1 次** refresh，其余挂起重放；**不解析 JWT exp**、不做本地过期预判。
- `42901`–`42905`、`42907` 不自动重试（按 Retry-After 提示，用户显式操作）；`40903` 强制重取后由用户决定是否重发，**禁自动带新 version 重发**；`42906` 静默退回队列。
- 单飞三断言必测：refresh 调用 == 1、两键逐字沿用。

### 5.5 重试（详设 §14）

- 仅 `RetryInterceptor`：总共 2 次（全链路总数）；退避 1s/2s ±20% 抖动；连接 5s、读 10s、**`/map/pins` 读 3s**；`Retry-After` 优先。
- 禁网络层与业务层双重试；重试单测断言两键逐字相同且 `uuid.v4()` 全链路只调 1 次。

### 5.6 状态与竞态（详设 §15）

- Provider 链按 §15.1 异步化；筛选下推服务端，排序留客户端。
- `CancelToken`：发新请求前 cancel 旧请求，`ref.onDispose(token.cancel)`；**HTTP 请求取消，但 `result=cancelled` 埋点照常上报**（不计入分母、不污染 P95，但必须可见）。
- `AsyncValue` 三态逐页处理，禁 `.value!` 强解；loading 骨架屏（首屏不转圈）、空态≠错误态、error 按 §5.4 行为渲染。

### 5.7 缓存与 grid_id（详设 §16）

- 三层存储：键值（<10KB）shared_preferences；埋点队列 JSON Lines 追加写文件（path_provider，成功从头截断）；Pin/静态缓存内存 LRU + 文件。**队列与 Pin 缓存禁放 shared_preferences**。
- Pin 缓存键五要素齐备才发请求（客户端先自检）；叶子类目集合排序后再哈希；收到 `stale` 信号清空**全部** Pin 缓存且不阻塞交互。
- grid_id 三端逐位一致：步长 450 微度、整数微度域、**`.floor()` 向负无穷取整，禁 `~/` 与 `.toInt()`**；正则 `^-?\d+_-?\d+$`；端云共用 10 条向量，第 9 条 `(-0.000015,-0.000015)` 必须额外断言中间微度 == -2。

### 5.8 埋点（详设 §17；可观测 §4）

- `layer_switch` 12 字段以可观测 §4.1.1 为唯一权威定义，全量不采样；`network_type` 取不到报 `unknown` 禁猜 `wifi`；`mem_peak_mb` iOS 报空。
- **四段各自独立 `Stopwatch`（cache/net/agg/render），严禁由 duration_ms 减出；`duration_ms` 独立测，不是四段相加**；未开始段记 0；容差 ±1ms，超差剔除分母并告警；评审见减法即打回。
- 队列：持久化追加写、上限 2000、溢出丢最旧且 `dropped_count`+1（放批次信封元数据）、`ts` 取采集时刻毫秒精度、按 `ts` 归月、50 条/30s/进后台任一触发、失败（含 42906）退回队首不丢弃、回灌限速 50 条/秒批间 ≥1s、未登录事件登录后补报。
- 去重键三列（事件体 `interaction_id`/`ts`/`event`）**入队即冻结**，上报器只读取与序列化，禁补全/刷新；事件名与契约枚举逐字一致。
- 批次是幂等保全**唯一例外**：每次组批换新 `Idempotency-Key` 与批次级 `X-Interaction-Id`（语义「一次传输动作」）；事件体 id 与批次头互不覆盖；回灌限速与重试是两套机制，禁用重试驱动回灌。
- `track_drop_stat` Batch1 落日志（详设 §21 #5）。

### 5.9 平台能力与后门（详设 §18、§20）

- Android 四项权限运行时请求 + 拒绝降级（无定位用默认中心点不白屏）；iOS 补 `NSLocationWhenInUseUsageDescription` 与 `LSApplicationQueriesSchemes`；隐私门早于登录模态且不可关，同意前禁初始化第三方 SDK/读设备标识。
- 外呼：`canLaunchUrl` 返 false 不是报错，降级「复制 + Toast」；联系方式只来自 `GET /posts/{id}/contact` 且**用完即弃**（不缓存/不写日志/不进埋点）；外呼埋点不含号码。
- 限频文案**不承诺剩余次数**：42902 收到即把本地剩余刷 0；`42907` 无次数字段，禁本地累计预测，只说「浏览次数较多」+ 登录入口，登录后直接重试原请求。
- 后门 888888 三层：① `kDebugMode` 编译期包裹（**`assert` release 不编译，禁当兜底**）；② 产物 `grep -c '888888'` 与 `grep -c 'debugCode'` 双 0，非 0 中止删 APK；③ 源码 G-Q1 登记册双向核对。日志写 `build/release-gate.log` 随包归档。

---

## 6. 数据与 SQL

- 表结构以两份 V1 DDL 为准，变更走新 Flyway 版本；预留字段不造数据，以文档登记。
- 保留策略键由 `RetentionRuleCoverageTest` 逐值相等断言，改保留期必须同改常量与测试（数据库设计文档）。
- 月表预建 `LIKE`、清理整表 `DROP`；`uk_event_dedup(interaction_id, event_name, user_id, ts)` 是去重唯一落点。
- `key_version` DEFAULT 三分化：`user` 默认 0、`user_identity`/`post` 无 DEFAULT，按 DDL 现状不统一。
- `idx_pins_cover` 用响应契约真实 6 列复测，`Extra` 须 `Using where; Using index`；看板 SQL（Q1–Q7）单文件逐条附 EXPLAIN。
- `seed-perf.sql` 可重复执行、头部带库名断言；响应体积测量打满 500 条再量。
- **SQL 注入防护无明文项目口径**，按 §10 通用基线：`#{}` 预编译、禁 `${}` 接外部输入、动态列名/排序走白名单、LIKE 转义。

---

## 7. 测试与质量门禁

### 7.1 分层

- 单测每次提交前本地必跑；集成测试仅出包前跑（含全响应 JSON 扫描，不得现 `real_name`/`id_card`）。
- 后端：`mvn test` / `mvn verify`；前端：`flutter analyze` **0 issue**、`flutter test` 全绿（基线 303 项，截至 2026-09-09，只增不减）；CI 顺序 analyze → `test/gates/` → 全量。

### 7.2 必测断言清单（会失败的自动化，不靠人眼）

**后端（详设 §9）：** ① ErrorCode 总数 25、无重复、`code/100==httpStatus`、8 个 Retry-After 码带秒数；② 幂等四类必测输入（缺失/大写或 v1/同 Key 异体返首次/失败后同 Key 重执行）；③ grid_id 10 向量含第 9 条中间微度；④ 响应 JSON 无 `real_name`/`id_card`；⑤ `CryptoFacade.decrypt` 调用点 ==1；⑥ STORED 生成列不入 insert/update；⑦ PATCH status 缺 version → 40001；⑧ 任务 #1 守 status / #3 用 DROP / #7 按 user_id 全删；⑨ 埋点 SQL 为 `ON DUPLICATE KEY UPDATE id=id`、`ts` 取客户端值、月表 LIKE 预建；⑩ 六项安全断言：AAD 跨行失败、审计白名单、审计同事务回滚、原图删除同事务回滚、双身份注销全删、缺 pepper 启动失败。

**前端（详设 §19）：** 网络层（三头 containsKey + Authorization 重写；重试两键逐字同且 uuid 调 1 次；`/map/pins` 3s）；错误码（全集对齐；单飞三断言；不解析 JWT exp；总数 2 次 + features 无 for 重试）；模型契约（release 包 10101 渲染；无 values.byName；两 case 单测；`toApiRadius` 断言）；缓存网格（10 向量；无 `~/`/`.toInt()`；五要素自检；stale 全清；队列不在 shared_preferences）；埋点（四段无减法；独立 duration；dropped_count；unknown；cancelled 上报；批次换新键；混入新事件重批真写入；键不互覆；毫秒 ts；去重键冻结）；UI 出包（无 `.value!`；三降级路径；文案不承诺次数；权限运行时；release-gate 双 0）。

### 7.3 静态守门（CI 必跑，[test/gates/](file:///d:/developer/code/aicoding/s2s/test/gates)）

- G-Q1 后门码登记册双向核对；G-Q2 密钥扫描（PEM 头/阿里云 AK 不可豁免；弱判据三分支：概率排除→登记豁免→FAIL；凭据进 git 历史即泄露，唯一处置是控制台作废换密钥）；G-Q3 `deploy/scripts/*.sh` 模式位 100755。
- 契约守门 14 项：25 业务码（示例承载 = 24 − 40305）、码对齐 HTTP、写接口幂等头（`POST /posts/precheck` 凭「不写库」佐证豁免，占位接口按 x-batch 识别列名）、429/40105 必带整数秒 Retry-After。
- 后端工程初始化后，契约示范测试 baseUrl 从内存 mock 切真服务，**断言一行不改**。

### 7.4 压测口径（详设 §8）

读接口 P95 取服务端 `rt_ms`，逐接口单独出数；并发 20、5 分钟、弃前 30 秒预热；异机发压；CPU steal ≤10%，超标重跑最多 3 次。日志 grep 红线（扫描面含 `logs/`）必须留证；**扫描面为空是 SKIP 不是 PASS**；身份证项 Batch1 标 N/A 禁记通过（四态语义见部署 §14.5）。

---

## 8. 提交、分支与出包

- 分支/tag 遵循 [分支与版本标记规范.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/分支与版本标记规范.md)：条目即分支 `item/<条目号>-<短描述>`，验收后 `--no-ff` 并回；Conventional Commits。
- release 正式签名；出包前工作区干净；FAIL 物理删 APK；产物 SHA-256 与 `release-gate.log` 归档；`rel/*` tag 与 `APP_VERSION` 严格同值。
- CI 只装代码面判据；G1–G11 环境门禁留发版机由 `deploy.sh` 消费退出码（0 放行 / 1 中止 / 2 需 `--gate-allow-skip="理由"`，FAIL 不可豁免）。
- 每完成一个任务即更新 [说明文档.md](file:///d:/developer/code/aicoding/s2s/说明文档.md) 进度并标记 ToDoList；出错立即暂停修复、验证无误再推进。

---

## 9. 编码期待关闭缺口（详设 §21，编号沿用原表）

| # | 事项 |
| --- | --- |
| #1 | `restart_window` 补 DDL + 服务端启动自写 |
| #2 | 聚合切换阈值 POC 实测校准后回写常量，**不在编码期猜** |
| #4 | Android `mem_peak_mb` 平台通道 Batch1 实现，iOS 报空 |
| #5 | `track_drop_stat` Batch1 落日志 |
| #6 | gzip 第一天实测，结论回写详设 §11.5（默认不注入） |

（#3 `post_media` 已裁定；#7 埋点去重键已关闭。）

---

## 10. 附录：通用基线（**非项目定案**，仅供设计文档空白处兜底）

设计文档无明文口径的主题，按通用惯例执行；设计文档补口径后以其为准并删本行：

| 主题 | 基线做法 | 出处状态 |
| --- | --- | --- |
| SQL 注入防护 | `#{}` 预编译；禁 `${}` 接外部输入；动态列名/排序走服务端白名单；LIKE 转义 | 无明文专条，§6 已引用 |
| 日志级别 | ERROR=影响请求的未知异常；WARN=已降级/可恢复（限频命中、静默降级）；INFO=关键业务事件；DEBUG=诊断，生产默认关 | 可观测只定字段格式，未定级别规则 |
| Java 风格 | 未引 Checkstyle 前遵循 Google Java Format 惯例 + 函数级注释 | 技术栈未定格式工具 |
| Dart 风格 | `flutter_lints` 默认规则 + `dart format` | 详设 §10.2 已定 |

> 维护纪律：本节是「诚实的空白」，不得把有争议的项目决策伪装成通用惯例塞进来。

---

## 11. 变更记录

| 日期 | 版本 | 内容 |
| --- | --- | --- |
| 2026-09-09 | v1.0 | 首版：汇编全部设计资产的编码期纪律 |
| 2026-09-09 | v1.1 | 全文精炼（删论证性文字，每条规则一句话 + 判定动作）；新增 §1「组件抽提与代码复用」：唯一实现处清单（后端 8 组件 / 前端 9 组件）+ 5 项机器可判的反冗余验收口径 |
