# [149] 实名认证接入（cert 域）+ 未实名详情额度计数

**Created:** 2026-10-11
**Status:** draft（待用户评审确认后进入编码）
**Scope 裁定:** 实名为主、资质留占位；供应商 dry-run mock 先行（用户 2026-10-11 确认）

---

## Product Contract

### Summary

把 cert 域从「契约占位 + 空壳 service」转真：交付 `POST /cert/realname`（二要素核验 → `realname_status` 落库）、`GET /cert/status`（实名状态查询）、`POST /cert/qualification`（资质提交，落 `cert` 表 `pending`，人工审核留 B2-5），并回填 `GET /posts/{id}` 的未实名详情额度计数（每日 5 条，第 6 条 `40301`），使 `detail_quota_enabled=on` 时额度正确生效而非 fail-fast。

### Problem Frame

- 契约 `openapi.yaml` 三端点（`/cert/*`）全为占位（无 schema），`PRD §12.3` 认证接口路径写 `/certs/*`（复数）与 openapi `/cert/*`（单数）不一致。
- 后端 `CertService.getRealnameStatus` 恒返回 `none` 且无人调用；无 Controller/Mapper/Provider，`/cert/*` 零实现。
- 库表已就绪：`user` 实名五列（`realname_status`/`real_name_enc`/`id_card_hash`/`id_card_last4`/`key_version` + `uk_id_card_hash`）+ `cert` 表（`cert_type`/`status`/`fail_count`/`lock_until` 等）。
- `PostQueryService.checkDetailQuota` 现为「开关 on 即抛异常」的 fail-fast，额度计数口径（键形/窗口/存储/复位）在详设 §3.4 键表无对应轨（缺口 DEC-07）。
- 前端仅 `cert_modal_screen.dart` 拦截浮层 + `/trust` 占位页，无 cert repository/模型/提交。

### Requirements

#### R1: `POST /cert/realname` 提交实名（二要素核验）

- **入参**：`real_name`（姓名明文，契约校验非空/长度）+ `id_card`（18 位身份证，契约校验）+ `agreement_accepted`（必 true，否则 `40002`）。
- **幂等**：POST 写接口，横切链按契约注入 `Idempotency-Key`，失败删占位键可重执行（DoD B2）。
- **核验流**（dry-run mock 实现，见 D1）：
  1. 已实名（`user.realname_status=passed`）→ 幂等返回当前状态，不重复计费；
  2. 校验 `id_card` 格式 → 非法 `40001`；
  3. 调 `RealnameProvider.verify(realName, idCard)` 二要素核验；
  4. 核验失败 → 记 `cert.fail_count`，达阈值锁定（见 D3），返回具体失败（`40301` 之外的业务码待定，见「待确认」）；
  5. 核验通过 → 同事务写：`user.real_name_enc`（AAD=`user_id`）、`id_card_hash`（`BlindIndex.hmac(id_card, peppers)`）、`id_card_last4`、`key_version`、`realname_status='passed'`；`cert` 表插一行（`cert_type='personal_realname'`、`status='approved'`、`approved_at`）；同步写 `audit_log`。
- **敏感列红线**：`real_name`/`id_card` 明文与密文**禁止**出现在任何 API 响应中；日志禁打完整身份证号（D8）。
- **手机号一致性**（DEC-30 ③）：**复用已登录手机号**这一事实——已通过短信验证码登录即证明手机号归本人，**不向供应商传手机号、不解密 `user_identity`、不买运营商三要素**。故**不新增 `CryptoFacade.decrypt` 调用点**（守「解密调用点计数基线 ==1」不漂移）。若后续产品要求「姓名+身份证+手机号」三要素核验，再评审新增解密调用点（架构变更）。

#### R2: `GET /cert/status` 查询认证状态

- **出参**：`realname{status}`（`none|pending|passed|rejected`）+ `qualifications[]{type,status,expire_at}`（本轮资质恒空数组，来源 cert 表 `status='approved'` 的行，Batch2 资质上线后填充）。
- 本人视角唯一入口；未登录 `40101`。

#### R3: `POST /cert/qualification` 提交资质（占位）

- **入参**：`media_ids[]`（OCR 证照图）+ `cert_type`（`personal_qualification|enterprise|vehicle`）。
- **本轮边界**：只落 `cert` 表 `status='pending'`（OCR 走 `RealnameProvider` 同厂商的 dry-run mock），**人工审核留 B2-5 运营后台**。前端 `/trust` 页资质入口给「已提交审核中」态，不做审核通过流转。
- 未实名先实名：提交资质前须 `realname_status=passed`，否则 `40302`（高敏类目前置）。

#### R4: 未实名详情额度计数（回填 `GET /posts/{id}`）

- **语义**（PRD §12.3，DEC-30 改 5 条）：已登录未实名用户每日放行 **5** 条详情，第 **6** 条返回 `40301`，客户端弹半屏引导实名（文案「今天的 5 条看完了」，§3.7）。
- **计数口径**（补齐 DEC-07 缺口，见 D2）：独立「额度闸」，不复用 `RateLimiter.incrementAndCheck`。
- `PostQueryService.checkDetailQuota` 由 fail-fast 改为真实现；`detail_quota_enabled=on` 时生效。

#### R5: 错误码注释与限额常量

- `ErrorCode.DETAIL_QUOTA_USED` 注释「每日 3 条」→「每日 5 条」（DEC-30 已改 PRD/契约，此处是漏项）。
- 新增限额常量，**禁业务代码写死 5**（守「阈值只引用常量名」红线）。

---

## 关键技术决策

### D1: `RealnameProvider` 抽象 + dry-run mock 实现

```text
RealnameProvider（接口，cert 域）
  ├── boolean verify(String realName, String idCard)   // 二要素核验，返回是否通过
  └── 资质 OCR 能力（R3 复用，本轮 mock）
实现：
  └── AliyunRealnameProvider（dry-run mock）
        - 配置开关 `cert.provider.dry-run=true`（默认）
        - dry-run：固定测试身份白名单（如 name="测试" + 指定 id_card 通过，其余拒绝）
        - 换真服务：只改 provider 实现一处，业务代码不动（DEC-30 ⑨）
```

- 供应商 = 阿里云实人认证·信息核验·纯服务端 API（DEC-30 ⑤），**无客户端 SDK** ⇒ 上架手册第三方 SDK 清单无需新增，仅隐私政策「用途声明」补实名条目（前置②）。
- 真 AccessKey 联调后，`dry-run` 置 `false` + 注入真实配置，`RealnameProvider` 实现替换（替换点集中一处）。

### D2: 额度计数 = 独立「额度闸」，不复用限频轨

**为什么不复用 `RateLimiter.incrementAndCheck`**：
1. `40301` 是 `needRetryAfter=false` 码（HTTP 403），而 `RateLimiter` 超限统一走 `ofRetryAfter`（强制 needRetryAfter 码），语义不兼容；
2. 额度耗尽语义是「引导实名」而非「限频等待」，不需要 `Retry-After`；
3. PRD §3.7 文案固定「今天的 5 条看完了」，客户端不读动态 `quota_used`（`api_error_code.dart:40301` 为 `deterministicFail`），无需返回计数。

**额度闸实现**（新类 `post.DetailQuotaGate`，约 20 行，语义「额度扣减」≠「限频」）：
```text
键形：rl:detailquota:uid:{userId}:1d:{yyyyMMdd}   // 拼装走 RateLimitKeys（守键拼装唯一处）
流程：
  1. GET 当前计数 current
  2. current >= NfrCert.DETAIL_QUOTA_LIMIT_PER_DAY(5) → 抛 BizException.of(40301)
  3. 否则 INCR；首次（current==0）设 TTL 到次日零点（+2h 缓冲，KTD6 同口径）
```
- 自然日窗口 + 键尾日期片 + 26h TTL，口径与 §3.4 既有 `:1d` 轨一致（复用 `RateLimitKeys.secondsUntilEndOfDay`）。
- Redis 写失败放行（与限频「防滥用非账务、允许丢」同纪律，§3.4 纪律 3）。
- **回写详设 §5.3.4**：把「计数键形态/窗口/存储介质/复位语义未定义」的缺口补齐为本节口径；§3.4 键表**不加第 12 行**（额度闸非限频轨，避免破坏「限频=needRetryAfter 码」语义）。

### D3: 二要素失败锁定（防刷）

PRD §4.8「二要素 3 次失败锁 24h，需人工申诉」。落点复用 `cert.fail_count` + `cert.lock_until` 列（已建）：
- `fail_count` 达 `NfrCert.REALNAME_FAIL_LOCK_THRESHOLD(3)` → 写 `lock_until=now+24h`，锁定期间提交直接拒绝（复用 `40001`，与核验失败同码，避免锁定期间重复计费）。
- 常量：`REALNAME_FAIL_LOCK_THRESHOLD=3`、`REALNAME_FAIL_LOCK_SECONDS=86400`。

### D4: `40301` 响应 data 口径（已定案，2026-10-11）

`40301` 响应 `data=null`，客户端用固定文案「今天的 5 条看完了」（§3.7）；不扩展 `BizException`/`ApiResponse` 承载 `quota_used`。回写 PRD §12.3 删除 `data.quota_used` 残留。

### D5: 新增解密调用点 = 无（架构保守）

见 R1「手机号一致性」：不解密 `user_identity`，`CryptoFacade.decrypt` 调用点计数保持 `==1`（Batch1 唯一调用点 `ContactService#viewContact`），DoD D2 基线不漂移。

### D6: 前端接线

- 新增 `lib/features/cert/cert_repository.dart`（`submitRealname`/`getCertStatus`/`submitQualification`）+ DTO（`CertStatus`/`RealnameSubmit`）。
- 新增实名认证表单页（实装 `/trust` 路由的 `PlaceholderScreen`）：姓名 + 身份证 + 协议勾选，提交 → 成功态/失败态（对接 `50302` 认证服务不可用 autoRetry、`40301` 相关引导）。
- `AuthSession.realNameVerified` 接真实 `/cert/status`：登录成功/进个人中心时拉取，替换默认 `false`。
- 详情页收到 `40301` → 弹半屏引导实名（对齐 §3.7 文案），「去实名」跳认证页。
- `cert_modal_screen.dart`「去认证」按钮由 `pop(true)` 改为跳真实认证页（保留「暂不发布」`pop()`）。

---

## 常量落点

新增 `common/constants/NfrCert.java`（cert 域 NFR 常量，镜像 Dart 真源 `lib/nfr_constants.dart` 对应成员）：

| 常量 | 值 | 出处 |
| --- | --- | --- |
| `DETAIL_QUOTA_LIMIT_PER_DAY` | 5 | PRD §12.3 / DEC-30（未实名每日详情条数） |
| `REALNAME_FAIL_LOCK_THRESHOLD` | 3 | PRD §4.8（二要素失败锁定阈值） |
| `REALNAME_FAIL_LOCK_SECONDS` | 86400 | PRD §4.8（锁 24h） |

> 纪律：与 `NfrPost`/`NfrApi` 同范式（常量类禁实例化、逐值引用 Dart 真源注释）；新增 Dart 侧 `nfr_constants.dart` 镜像成员时同步改。

---

## 改动清单

### 后端（`src/main/java/com/s2s/server/`）

| 文件 | 动作 |
| --- | --- |
| `cert/CertService.java` | 由空壳转真：注入 `RealnameProvider`/`CertMapper`/`CryptoFacade`/`BlindIndex`/`AuditLogWriter`，实现 `submitRealname`/`getCertStatus`/`submitQualification` |
| `cert/RealnameProvider.java` | 新增接口 |
| `cert/AliyunRealnameProvider.java` | 新增 dry-run mock 实现（白名单 + 开关） |
| `cert/CertController.java` | 新增（3 端点，`@RestController`） |
| `cert/mapper/CertMapper.java` + `cert/entity/CertEntity.java` | 新增（`cert` 表映射） |
| `cert/dto/*` | 新增请求/响应 DTO |
| `post/DetailQuotaGate.java` | 新增额度闸（D2） |
| `post/PostQueryService.java` | `checkDetailQuota` 改调 `DetailQuotaGate`，删 fail-fast |
| `common/constants/NfrCert.java` | 新增常量类 |
| `common/ratelimit/RateLimitKeys.java` | 新增 `detailQuotaUidDay(Long, LocalDate)` 键拼装 |
| `common/error/ErrorCode.java` | `DETAIL_QUOTA_USED` 注释 3→5 |

### 契约（`docs/api/openapi.yaml`）

- `/cert/realname`、`/cert/qualification`、`/cert/status` 三端点补 requestBody/response schema；`x-batch` 去 `Batch2` 占位改为 `Batch2`（落地）。
- 新增/复用 components schema：`RealnameSubmitRequest`、`RealnameStatusEnum`（已存在）、`CertStatusResponse`、`QualificationSubmitRequest`。
- 触发 D7 契约守门 14 项。

### 前端（`lib/`）

| 文件 | 动作 |
| --- | --- |
| `features/cert/cert_repository.dart` | 新增（3 接口） |
| `features/cert/cert_models.dart` | 新增 DTO |
| `features/cert/realname_form_screen.dart` | 新增实名表单页 |
| `router/app_router.dart` | `/trust` 由 `PlaceholderScreen` 改指实名认证页 |
| `features/auth/auth_repository.dart` | `realNameVerified` 接真实 `/cert/status` |
| `features/publish/cert_modal_screen.dart` | 「去认证」跳真实认证页 |
| `features/publish/publish_screen.dart` | 详情页 `40301` 弹半屏引导实名 |

### 文档（依据源先回写）

见「口径回写清单」。

---

## DoD 验收映射

| DoD | 落实 |
| --- | --- |
| D1 三硬纪律 | 限额常量引用（不写死 5）；无新增错误码（复用 40301/40302/50302）；幂等靠 `Idempotency-Key` containsKey |
| D2 反冗余 | `CryptoFacade.decrypt` 计数保持 ==1（D5）；键拼装走 `RateLimitKeys` 唯一处 |
| D3 函数级注释 | 全部新函数带「为什么 + 章节号」 |
| D4 静态检查 | `mvn -q compile` + `flutter analyze` 0 issue |
| D5 测试 | 后端 `mvn test` 全绿、前端 `flutter test` 总数只增不减；`DetailQuotaGate`/`CertService` 各带新单测 |
| D7 契约守门 | 改 `openapi.yaml` → 契约守门 14 项必跑 |
| D8 安全红线 | 响应无 `real_name`/`id_card`；日志无完整身份证号 |
| D9 文档同步 | 进度记录四行证据 + 依据源回写（见下） |
| B1 响应套壳 | `ApiResponse` + `GlobalExceptionHandler` 唯一映射 |
| B2 幂等 | `POST /cert/realname` 幂等头注入/校验 + 失败删占位键 |
| B4 EXPLAIN | 新增 XML 查询附 EXPLAIN 结论注释 |
| B5 契约示范测试 | 切真服务断言不改行 |
| F1/F3/F4 | DTO 可空对齐、错误码行为映射落位、AsyncValue 三态 |

---

## 口径回写清单（依据源先回写，再编码）

1. `ErrorCode.DETAIL_QUOTA_USED` 注释 3→5（代码，R5）。
2. `PRD §12.3` 认证接口路径 `/certs/*` → `/cert/*`（对齐 openapi）；「每日放行 3 条，第 4 条」→「5 条，第 6 条」；`data.quota_used=3` → 删除（见 D4）。
3. `PRD §3.7` 文案「点第 4 条」「今天的 3 条看完了」→「5 条」。
4. `详设 §5.3.4` 回填额度计数口径（D2），删「缺口待裁定」表述。
5. `详设 §5.7`（cert 空壳）→ 更新为「Batch2 实名已落地，资质留占位」。
6. `上架手册隐私政策`「用途声明」补实名条目（前置②，纯服务端无 SDK 清单新增）。

---

## 风险与待确认

| # | 项 | 状态 |
| --- | --- | --- |
| 1 | `40301` 是否需 `data.quota_used`（D4） | **已定案**：data=null + 客户端固定文案（2026-10-11） |
| 2 | 二要素核验失败返回哪个业务码（不新增错误码） | **已定案**：核验失败与锁定态均复用 `40001`（2026-10-11，实现落地口径） |
| 3 | 阿里云 dry-run 白名单身份集合 | 编码期用固定测试身份（如 `姓名=测试用户` + 指定身份证尾号），联调前确认 |
| 4 | `GET /cert/status` 资质列表来源（cert 表 `status=approved`）本轮恒空 | 已在 R2/R3 明确，无风险 |

---

## 变更记录

| 日期 | 内容 |
| --- | --- |
| 2026-10-11 | 首版方案：实名为主 + 资质占位 + dry-run mock；额度独立闸（D2）；手机号一致性不解密（D5） |
