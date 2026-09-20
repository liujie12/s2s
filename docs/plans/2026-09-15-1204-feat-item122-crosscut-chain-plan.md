---
title: "条目 [122] 后端横切链四件 - Plan"
type: feat
date: 2026-09-15
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
deepened: 2026-09-15
---

# 条目 [122] 后端横切链四件 - Plan

## Goal Capsule

- **Objective**：后端所有 HTTP 请求经过一条定死顺序的横切链（request_id 注入 → 鉴权 → 限频 → 幂等），幂等四类必测输入、429 段与 40105 整数秒 Retry-After、42907 鉴权后判定三条 S1 出口验收全部由会失败的自动化断言覆盖。
- **Means**：在 [121] common 三组件之上落地 RequestIdFilter + AuthInterceptor（黑名单制校验骨架）+ RateLimitInterceptor/RateLimiter + IdempotencyInterceptor，配常量类、注解、logback JSON 日志闭环与随修的 P2 #8/#4（详设 §3.1–§3.4；KTD1–KTD13）。
- **Authority hierarchy**：详设 §2/§3 > openapi.yaml（契约）> 编码规范（.trae/rules/s2s找呀找.md）> 本计划 KTD（只在依据源空白处裁定，须回写登记）。
- **Stop conditions**：四件全部注册且链序断言通过；S1 出口三条验收断言全绿；P2 #8/#4 修复落地；文档漂移 9 处回写完成。任一依据源冲突以依据源为准，先回写本计划再实施。
- **Execution profile**：泳道 A 工作树 `item/122-crosscut-chain`，`ce-work` 逐单元执行，`mvn test` 为每单元门禁。
- **Tail ownership**：文档回写（U8）与 gap-register 登记随本条目收口，不外溢。

---

## Product Contract

### Summary

为 Batch1 后端补齐横切链基础设施：四件拦截组件按定死顺序串链、限频与幂等两套 Redis 语义、鉴权上下文骨架与两 ID 分工、logback JSON 日志最小闭环；随修 [121] 评审 P2 #8（advice 作用域）与 #4（BizException 构造期守卫）。不含 auth 域六个接口与 token 签发/续期/登出（[123] 后端）、不含业务域限频注解接入（各业务条目）、不含压测。

### Problem Frame

[121] 已交付响应信封、异常映射与 25 错误码，但请求仍直达 controller：无 request_id 贯穿、无鉴权、无限频、无幂等。S1 出口闸门（9/11，[121] 晚一天收口后 [122] 已欠账）要求「横切链自测过」；后续全部条目（auth/category/post/map/contact/track）都以本链条为地基。评审另留两项 common 缺陷（#8 advice 未限作用域会把 /error 错误体套成 code=0 假成功信封；#4 缺秒数的 BizException 可被构造）在本条目触发场景内最便宜修复。

### Requirements

**横切链与两 ID（Backlog [122] 出口）**

- R1. 四件按 `RequestIdFilter → AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor → Controller` 顺序注册与执行；限流必先于幂等；42907 判定在鉴权上下文之后（详设 §3.1）。
- R2. request_id 由 Filter 在链首生成，写入请求属性（复用 `ResponseBodyWrapper.REQUEST_ID_ATTRIBUTE`）与 MDC，经响应体回显；interaction_id 只从 `X-Interaction-Id` 头读入 MDC（截断 64、剥控制字符、缺失留空），严禁用于鉴权/限流/幂等判定；缓存命中时 request_id 可不存在，不得判异常（详设 §3.2）。
- R3. MDC 清理与访问日志（rt_ms/code/path）统一在 RequestIdFilter 的 finally 完成；日志以 JSON 单行落盘，含可观测方案 8 字段（ts/level/request_id/interaction_id/user_id/path/code/rt_ms），配滚动与保留上限，不出现完整手机号/身份证/Authorization 头。

**鉴权骨架**

- R4. AuthInterceptor 按黑名单制实现校验骨架：解析 Bearer JWT → 查 Redis Token 黑名单 → 有效则 userId 写入鉴权上下文；匿名接口带无效/过期 Token 返 40101，无 Authorization 头放行为游客；Redis 查询故障返 50001（不伪装登录失效、不绕过黑名单）。token 签发/续期/登出属 [123]。

**限频**

- R5. RateLimiter/RateLimitKeys 承载详设 §3.4 键表 11 行：账号维键收 userId、渠道维键收 phone 与 ip、设备辅助维收 deviceId（contact/guestdetail 的 dev 轨），类型分维防串用；`:1d` 轨为自然日窗口；多轨同时超限 Retry-After 取最长剩余秒数；限频计数允许 Redis 丢失；429 段响应不区分命中维度。
- R6. 429 段与 40105 全部经 `BizException.ofRetryAfter` 抛出，Retry-After 头仍只在 GlobalExceptionHandler 唯一写入，值为整数秒。

**幂等**

- R7. IdempotencyInterceptor 对标注 `@Idempotent` 的写接口生效（precheck 不标注即豁免）：登录态接口键 `idem:{userId}:{key}`，匿名写接口（`security: []` 的 sms 两支）键 `idem:dev:{X-Device-Id}:{key}`、缺设备头降级 `idem:anon:{key}`（KTD13）；TTL 引 `NfrApi.idempotencyWindowHours`（24h）；Key 按 v4 UUID 正则校验，缺失/大写/v1 返 40001 不放行；SETNX 占位，并发/重放轮询取首次成功响应原样返回（不校验请求体差异，含首次 request_id）；仅成功入缓存，业务失败删占位键使同 Key 重放重新执行。
- R8. 幂等四类必测输入各有会失败的自动化断言：缺失→40001、大写或 v1→40001、同 Key 异体返首次、失败后同 Key 重执行（详设 §3.3/§9）。

**配置与依赖**

- R9. `server.forward-headers-strategy: framework` 使 IP 维限频取真实客户端 IP；`JWT_SECRET` 以 `${VAR:?}` 占位入 application.yml 并进 SecretsProperties 硬守卫，`.env.example` 与 deploy compose 模板同步登记；新增依赖（jjwt、logstash-logback-encoder）显式钉版并在 pom 依赖旁写决策理由。

**随修缺陷**

- R10. P2 #8：两处 `@RestControllerAdvice` 限定 `basePackages = "com.s2s.server"`，/error 错误派发体不再被套成 code=0 信封，并有集成/单元断言；P2 #4：`BizException.of()` 拒收 8 个 needRetryAfter 码、`ofRetryAfter()` 对称拒收无需秒数的码（构造期不可表示）。

### Key Decisions

- **黑名单制会话模型**（session-settled: user-directed — chosen over 白名单 `session:{userId}`：详设 §5.1「登出 Token 入 Redis 黑名单至原过期时刻」是唯一成文口径，白名单会与 [123] logout 实现打架）。Governs R4。
- **AuthInterceptor 只交付校验骨架**（session-settled: user-directed — chosen over 会话模型整体前置：签发/续期/登出的产品决策属 [123]）。Governs R4。
- **P2 #8 随 [122] 修**（session-settled: user-directed — chosen over 维持 [124] 承接：横切链是 /error 路径主要生产者，现在修最便宜）。Governs R10。

### Success Criteria

- S1 出口三条验收各有断言承载且全绿（三条 = 幂等四类：U5；Retry-After 整数秒：U4/U7；42907 鉴权后判定：U7；链序为 R1 断言另计）。
- `mvn test` 全绿，既有 17 项测试零回归。
- 静态守门口径达成：业务代码写 Retry-After header 零命中（仍唯 GlobalExceptionHandler）；`lib/` 与前端测试不受影响（本条目无前端改动）。

### Scope Boundaries

**Deferred to Follow-Up Work**

- P2 #7/#3（supports() 正向断言、handler 无秒数测试伞）：若 U6/U7 实现自然覆盖则顺带修，否则维持登记由下一 common 承接条目处理。
- `/error` 统一信封映射（完整 ErrorController 设计，见 [124] 计划的 KTD-10 原文）：维持 [124] 承接，本条目只保证「不出现 code=0 假成功」。
- @WebMvcTest 全上下文 404/ERROR dispatch 断言（本条目用单元+standalone 断言替代，见 KTD12）。
- `POST /track/events` 单请求 ≤50 事件校验（42906 的另一轨，属 [129] track service）。
- 业务域各自限频注解接入（[123]–[128] 各条目在 controller 上标注）。
- 受保护端点登录要求声明机制（@RequireAuth 类注解或受保护路径清单，作为 openapi security 声明的服务端唯一承载点）：属 [123] auth 域首个消费场景，[122] 骨架先行登记防散写。

**Outside this product's identity**

- 分布式锁/多实例横切链（单实例定案，详设 §1）。
- 前端任何改动（横切链为纯后端条目）。

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Token 黑名单键形 `jwt:bl:{jti}`，TTL = Token 剩余有效期**。登出侧写入逻辑属 [123]，本条目只提供查询点；jti 不存在时按整 Token 哈希兜底（实现期定，登记为 deferred note）。依据：详设 §5.1 黑名单至原过期时刻（session-settled: user-directed — chosen over 白名单制，见 Key Decisions）。
- KTD2. **`server.forward-headers-strategy: framework`**。Caddy 已传 `X-Forwarded-For`；framework 策略无头时回退 remoteAddr，本地直连开发兼容（session-settled: user-approved — chosen over native 与不配：不配则 IP 维三轨全站共享 Caddy 容器 IP，上线即故障）。Governs R9。安全前提：正确性依赖 Caddy 覆盖式 `header_up X-Forwarded-For {remote_host}`（禁止改为追加/透传），部署门禁加该行存在性断言。
- KTD3. **匿名接口带无效/过期 Token 返 40101**。客户端 40101→单飞续期→重放闭环成立；无头才按游客放行（session-settled: user-approved — chosen over 降级游客：带过期 Token 的深链用户应触发续期而非被当游客消耗 30/d 额度）。Governs R4。
- KTD4. **幂等轮询参数：间隔 200ms、总超时 10s、超时返 50001、占位哨兵串 `"PENDING"`**。超时后客户端同 Key 自动重试命中缓存，语义闭环；参数进常量类并按 DEC-01 先例登记 gap-register（依据源无明文）（session-settled: user-approved — chosen over 立即返回占位/长轮询：防御默认，不裁定则幂等核心路径悬空）。Governs R7。附注一：轮询占用容器线程至多 10s，S1 压测口径（并发 20、Tomcat 默认 200 线程）不致打满，但单 Key 大量并发重放是放大面——守门约定「@Idempotent 接口须同时声明 @RateLimit 或在 gap-register 登记豁免理由」；[130] 压测复核项为「单 Key 并发下线程占用、Redis 读放大（每等待者 10s 内约 50 次 GET）与幂等接口 P95」。附注二：闭环成立条件 = 首次执行在总窗口（首发 10s 轮询 + 至多 2 次重试各 10s）内完成并 SET 完成态；超窗后客户端终局失败，用户重发按新键二次执行，属定案容许面。
- KTD5. **MDC 生命周期与访问日志归 RequestIdFilter finally；logstash-logback-encoder 随 [122] 落最小闭环**（logback-spring.xml 8 字段 JSON 单行 + maxHistory/totalSizeCap 保留上限）。finally 是唯一覆盖 preHandle 异常、advice 异常、响应已提交等全路径的清理点；不落 encoder 则 MDC 无结构化出口，可观测验收 Batch1 失败（session-settled: user-approved — chosen over 移交 [129]：MDC 写入与日志出口同一批人落地最短）。Governs R3。访问日志走独立命名 logger（不落 com.s2s 层级，避免被 deploy 的 `com.s2s: WARN` 外部配置压制），deploy 三份 application-{env}.yml 显式放行该 logger。
- KTD6. **限频窗口为自然日，多轨超限 Retry-After 取 max**。`:1d` 轨键尾内嵌日期片（形如 `rl:...:1d:20260918`，与 `fz:` 键先例同构），TTL 给 26h 防跨日残留；时区以 `ZoneId` 常量显式固化 Asia/Shanghai（不依赖 JVM 默认时区）；`1m`/`1h` 轨维持固定滚动窗。与 PRD「今日」文案一致；完成后回写详设 §3.4 一行。默认依据研究推荐（用户未逐项选定），实现前可被否决。Governs R5。
- KTD7. **Redis 读路径故障统一降级 50001**（含鉴权黑名单查询在内的读路径；幂等 SETNX 失败走轮询、限频计数写失败 WARN 放行，均不适用本条）。40101 会触发客户端清会话（Redis 抖动=全量登出），fail-open 绕过黑名单不可接受。默认依据研究推荐。Governs R4。
- KTD8. **P2 #4 随修**：`of()` 拒收 needRetryAfter 码、`ofRetryAfter()` 拒收其余码。RateLimiter 是 #4 的直接消费方，apply-queue 原就指向横切链条目。默认依据研究推荐。Governs R10。
- KTD9. **注册落点 `config/WebCrosscutConfig`**：`FilterRegistrationBean<RequestIdFilter>` 置最高优先级 + `WebMvcConfigurer.addInterceptors` 按 Auth → RateLimit → Idempotency 顺序注册（add 顺序即 preHandle 执行顺序）。config 是组装根，依赖方向 auth→common 保持「common 只被依赖」（详设 §1.3）。AuthInterceptor 落 auth 域包，鉴权上下文（AuthContext + 唯一读取器）落 common/web 供 common/ratelimit 读取，避免 common→auth 反向依赖。
- KTD10. **JWT 库 jjwt 0.12.6**（api/impl/jackson 三件套），pom 依赖旁写选型理由；`JWT_SECRET` 进 SecretsProperties 硬守卫（现有八组件之上新增 jwtSecret，即第七个硬必填字段，@NotBlank + requireResolved + **原始长度 ≥32 字节**——jjwt HS256 对短密钥运行期抛 WeakKeyException，启动期长度校验把该失败提前，与既有凭证守卫范式同构，密钥值不入任何仓库文件）。泄露处置口径随 gap-register 登记：立即换值并接受全量登出（30 天 Token 全失效）。依赖决策显式钉版（技术栈 §3）。
- KTD11. **限频阈值 Java 单端正源**：Dart 真源无 `NfrRateLimit` 类（客户端被禁止本地预测剩余次数，无消费方），故 `RateLimitThresholds` 常量类直接从详设 §3.4 表格抄录并逐值注章节号，且向编码规范 §3.1 回写一行例外说明。幂等 TTL 仍从 Dart `NfrApi.idempotencyWindowHours=24` 抄录进 Java `NfrApi` 镜像类（PRD §12.1）。
- KTD12. **测试路径：纯单测 + standalone MockMvc，不起 `@SpringBootTest` 全上下文**。Filter 纯单测（MockHttpServletRequest/FilterChainMock）；链序与信封用 `standaloneSetup(stubController) + addFilters(requestIdFilter) + addInterceptors(按 WebCrosscutConfig 同序) + setControllerAdvice(wrapper, handler)` + fake Redis；另加 WebCrosscutConfig 注册序单测（捕获 addInterceptors 调用顺序断言真实配置类），防手拼链序对生产配置类错误免疫。standalone MockMvc 不可达 BasicErrorController/ERROR dispatch——/error 断言改为单测 advice 作用域过滤行为 + 集成断言 NoResourceFoundException 路径（50001 信封），BasicErrorController 原生返回作为已知边界登记（Deferred）。与既有 17 项纯单测范式一致（研究 §9）。
- KTD13. **匿名幂等键维度：`idem:dev:{X-Device-Id}:{key}`，缺设备头降级 `idem:anon:{key}`**。`POST /auth/sms/send`、`POST /auth/sms/login` 是 `security: []` 写接口且契约必带 Idempotency-Key，无 userId 可用；滥用面被链序双重钳制（限流在幂等之前 + 仅成功响应驻留缓存，失败即 DEL）；幂等只防客户端重试、防滥用由 `rl:sms` 等渠道限频轨兜底（deviceId 不可信，openapi 定案）。`@Idempotent` 注解加 `anonymous` 属性区分两类写接口：sms 两支走匿名分支，其余 9 支无 AuthContext 返 40101（与 openapi security 声明逐一对齐）。幂等件不做契约头执法者，不新增 40001 分支。架构验证 D1 裁定；回写详设 §3.3 一行（U8）。
- KTD14. **`X-Device-Id` 入键前统一格式校验**：按 UUID 正则与长度上限校验，不符一律视为缺头（限频 dev 轨跳过、幂等降级 anon 维）——与 `X-Interaction-Id` 截断 64/剥控制字符的纪律对等，防键空间污染与内存放大（128MB maxmemory 下驱逐带 TTL 的幂等/限频键）。Governs R5、R7。

### High-Level Technical Design

请求生命周期（含四件职责与分支）：

```mermaid
flowchart TB
  A[HTTP 请求] --> F[RequestIdFilter 链首]
  F --> F1[request_id 生成 → 请求属性 + MDC]
  F --> F2[X-Interaction-Id 读入 MDC<br/>截断64/缺失留空]
  F2 --> AUTH{AuthInterceptor}
  AUTH -->|无 Authorization 头| GUEST[游客放行]
  AUTH -->|有效 Token 且不在黑名单| CTX[userId 入鉴权上下文 + MDC]
  AUTH -->|无效/过期/黑名单| E40101[40101]
  AUTH -->|Redis 故障| E50001a[50001]
  GUEST --> RL{RateLimitInterceptor}
  CTX --> RL
  RL -->|@RateLimit 声明的键轨 INCR<br/>账号维 userId / 渠道维 phone·ip / 设备维 deviceId| RL2{超限?}
  RL2 -->|是, 取 max 剩余秒| E429[429xx + Retry-After 整数秒<br/>不区分维度]
  RL2 -->|否| IDEM{IdempotencyInterceptor}
  RL -->|无注解 / GET| IDEM
  IDEM -->|Key 正则不符或缺失| E40001[40001]
  IDEM -->|SETNX 成功| C[Controller → 业务]
  IDEM -->|SETNX 失败| POLL[轮询 200ms/10s<br/>PENDING→等待 / 完成→原样返回首次 JSON]
  POLL -->|超时| E50001b[50001 客户端同 Key 重试闭环]
  C -->|成功| CACHE[完整信封 JSON 覆盖占位, TTL 24h]
  C -->|BizException| DEL[删占位键 → 同 Key 重放重新执行]
  F -.finally.-> LOG[访问日志 rt_ms/code/path + MDC 清理]
```

Redis 键全景（本条目消费/生产）：

| 键形 | 写入方 | 语义 |
| --- | --- | --- |
| `idem:{userId}:{key}` | IdempotencyInterceptor | PENDING 占位 → 首次成功信封 JSON，TTL 24h（登录态写接口） |
| `idem:dev:{deviceId}:{key}` / `idem:anon:{key}` | IdempotencyInterceptor | 同上（匿名写接口，KTD13） |
| `rl:*` 11 行（详设 §3.4，`:1d` 轨键尾带日期片） | RateLimiter | INCR 计数，自然日/固定窗，允许丢失 |
| `fz:contact:{userId}:{date}` | RateLimiter | 熔断冻结标记（[128] 消费） |
| `jwt:bl:{jti}` | [123] 登出写入 | 本条目只读（黑名单查询） |

### Assumptions

- jjwt 0.12.6 与 Spring Boot 3.5.16（Jackson 2.x）兼容；如实现期发现冲突，在 0.12.x 线内升补丁版并在 pom 注明。
- Lettuce 懒连接下 `StringRedisTemplate` 首次调用才建连，测试用 mock/fake 不触网（[121] 已验证该口径）。
- KTD6/KTD7/KTD8 三项按研究推荐默认裁定（用户菜单未逐项选定）；在 U4 动工前仍可一句话否决重排。

### Sequencing

U1（底座）→ U2/U3（可并行，各自依赖 U1）→ U4（依赖 U3 上下文）→ U5（依赖 U3 userId）→ U6（仅依赖 U1，可提前穿插）→ U7（依赖全部）→ U8（收口）。每单元以 `mvn test` 全绿为提交门禁。

---

## Implementation Units

### U1. 常量类、注解与依赖底座

- **Goal**：横切链全部字面量进常量类，注解与依赖就位，配置快速失败口径扩展。
- **Requirements**：R9（主）、R5/R7 阈值载体。
- **Dependencies**：无。
- **Files**：
  - `src/main/java/com/s2s/server/common/constants/NfrApi.java`（新建；幂等 TTL=24，值从 Dart 真源 `lib/nfr_constants.dart:177` 抄录，注 PRD §12.1）
  - `src/main/java/com/s2s/server/common/constants/RateLimitThresholds.java`（新建；11 行键表逐值注详设 §3.4；单端正源例外注释；含 ZoneId 常量 Asia/Shanghai）
  - `src/main/java/com/s2s/server/common/constants/IdempotencyPolicy.java`（新建；轮询间隔 200ms/总超时 10s/PENDING 哨兵，注 KTD4 与 gap-register 登记号）
  - `src/main/java/com/s2s/server/common/constants/package-info.java`（新建）
  - `src/main/java/com/s2s/server/common/idempotency/Idempotent.java`（新建注解；含 `anonymous` 属性区分匿名/登录态写接口，KTD13）
  - `src/main/java/com/s2s/server/common/ratelimit/RateLimit.java`（新建注解，`RateLimitTrack[]` 数组声明多键轨）
  - `src/main/java/com/s2s/server/common/ratelimit/RateLimitTrack.java`（新建枚举；11 轨标识，逐轨绑定 `RateLimitThresholds` 常量引用——`@RateLimit` 属性类型须编译期可解析，充当「注解声明 → 常量取值 → U4 键拼装」的桥，架构验证 D7）
  - `src/main/java/com/s2s/server/common/config/SecretsProperties.java`（修改；加 jwtSecret 硬守卫字段）
  - `src/main/resources/application.yml`（修改；`server.forward-headers-strategy: framework`、`s2s.secrets.jwt-secret: ${JWT_SECRET:?}`）
  - `pom.xml`（修改；jjwt api/impl/jackson 0.12.6、logstash-logback-encoder 8.0，依赖旁注选型理由）
  - `.env.example` 新增 `JWT_SECRET=`；`deploy/env/.env.{dev,staging,prod}.example` 核对既有 `JWT_SECRET` 例值满足 ≥32 字节并补齐缺项（三份模板已含该变量，勿盲改跳过核对）
  - `deploy/docker-compose.yml`（修改；app 服务 env 加 `JWT_SECRET=${JWT_SECRET}`）
  - `src/test/java/com/s2s/server/common/config/SecretsPropertiesTest.java`（修改）
  - `src/test/java/com/s2s/server/common/config/ApplicationYamlTest.java`（修改；新增 jwt-secret 占位与 forward-headers-strategy 断言，占位断言八处加到九处）
  - `src/test/java/com/s2s/server/common/constants/RateLimitThresholdsTest.java`（新建）
  - `src/test/java/com/s2s/server/common/ratelimit/RateLimitTrackTest.java`（新建；枚举逐轨与阈值常量绑定断言）
- **Approach**：
  1. 常量类私有构造 + `static final`，逐值注章节号（`RateLimitThresholds` 注明「服务端单端正源，Dart 端无消费方（客户端禁本地预测），依据编码规范 §3.1 例外登记」）。
  2. `RateLimitThresholds` 同时承载 11 行键形模板与阈值/窗口/超限码三组值，键拼装仍归 `RateLimitKeys`（U4），常量类只存值不拼键（唯一实现处分工，规范 §1.2）。
  3. SecretsProperties 复用既有 requireResolved 范式；ApplicationYamlTest 占位断言从八处加到九处。
- **Patterns to follow**：`SecretsProperties` 硬守卫与 normalizeOptional 范式；`ErrorCode` 的私有构造常量类范式。
- **Test scenarios**：
  - SecretsPropertiesTest：缺 `JWT_SECRET` 启动快速失败（binding 抛异常断言）；`JWT_SECRET` 短于 32 字节同样快速失败（KTD10 长度守卫）。
  - RateLimitThresholdsTest：11 行键表逐值与详设 §3.4 对账（阈值、窗口、超限码三元组断言，防止抄录漂移——`cross-document-reference-verification` 学习沉淀）。
  - ApplicationYamlTest：`jwt-secret` 占位符与 `forward-headers-strategy: framework` 存在性断言。
- **Verification**：`mvn test` 全绿；`mvn dependency:tree` 显示 jjwt 三件套与 encoder 钉版无版本范围。

### U2. RequestIdFilter + logback JSON 日志闭环

- **Goal**：request_id/interaction_id 入 MDC，访问日志 8 字段 JSON 单行落盘，MDC 全路径清理。
- **Requirements**：R2、R3。
- **Dependencies**：U1（encoder 依赖、常量）。
- **Files**：
  - `src/main/java/com/s2s/server/common/web/RequestIdFilter.java`（新建）
  - `src/main/java/com/s2s/server/config/WebCrosscutConfig.java`（新建；本单元只注册 Filter，`FilterRegistrationBean` 最高优先级 + `DispatcherType.REQUEST`）
  - `src/main/resources/logback-spring.xml`（新建；LogstashEncoder + 8 字段 + maxHistory/totalSizeCap；真源声明——deploy/config/logback-spring.xml 若已存在则删除或改写为指向本文件的说明，防双份漂移）
  - `deploy/config/app/application-{dev,staging,prod}.yml`（修改；显式放行访问日志独立命名 logger，防 `com.s2s: WARN` 压制）
  - `src/main/java/com/s2s/server/common/web/ResponseBodyWrapper.java`（修改；Javadoc 漂移 [124]→[122]，`resolveOrCreateRequestId` 注释改为「Filter 链首生成，此处仅防御性兜底」）
  - `src/test/java/com/s2s/server/common/web/RequestIdFilterTest.java`（新建）
- **Approach**：
  1. Filter 职责四件：生成 UUID 写 `REQUEST_ID_ATTRIBUTE` + MDC `request_id`；读 `X-Interaction-Id` 截断 64、剥控制字符后入 MDC（缺失留空）；finally 记访问日志（rt_ms 用 `System.nanoTime` 差、code 从 response 取、path 从 request 取）并清 MDC；访问日志走独立命名 logger（不落 com.s2s 层级）；actuator 路径同 Filter 照常执行（日志需要覆盖运维请求可后续再议，本条目不排除）。
  2. ERROR dispatch 路径日志无 MDC 字段（Filter 默认只 REQUEST 类型）——已知边界，写入类 Javadoc。
- **Patterns to follow**：`RequestContextFixtures` 的请求上下文安装/清空；[121] 纯单测范式。
- **Test scenarios**：
  - 带头请求：doFilter 后 MDC 有 request_id 与截断后的 interaction_id；响应属性含 request_id。
  - 缺头请求：interaction_id 为空串，不抛异常。
  - 超长头（>64）与含 CRLF 头：截断/剥除后入 MDC。
  - finally 清理：chain 抛异常后 MDC 已清（线程复用防串号）。
  - 访问日志：code/path/rt_ms 落入独立 logger（用 ListAppender 断言字段，rt_ms > 0）。
  - Filter order：`FilterRegistrationBean.getOrder()` 为最高优先级档。
- **Verification**：`mvn test` 全绿；本地起应用打一条请求，`logs/` 出现含 8 字段的 JSON 单行（联调留证，不进单测）。

### U3. AuthInterceptor 黑名单制校验骨架 + 鉴权上下文

- **Goal**：解析 Bearer JWT、查黑名单、userId 入上下文；无效 Token 40101、无头游客、Redis 故障 50001。
- **Requirements**：R4（主）、R1（链位）。
- **Dependencies**：U1（jjwt、JWT_SECRET、常量）。
- **Files**：
  - `src/main/java/com/s2s/server/common/web/AuthContext.java`（新建；request attribute 承载 + 静态唯一读取器 `currentUserId(HttpServletRequest)`/写入器，无线程池串号风险）
  - `src/main/java/com/s2s/server/auth/AuthInterceptor.java`（新建；auth 域，详设 §1.3 域内分层）
  - `src/main/java/com/s2s/server/auth/JwtVerifier.java`（新建；jjwt 解析 + 黑名单查询，Redis 故障向上抛由拦截器转 50001）
  - `src/main/java/com/s2s/server/auth/package-info.java`（修改；从占位改为实名）
  - `src/main/java/com/s2s/server/config/WebCrosscutConfig.java`（修改；注册 AuthInterceptor 于 Filter 之后）
  - `src/test/java/com/s2s/server/auth/AuthInterceptorTest.java`（新建）
  - `src/test/java/com/s2s/server/auth/JwtVerifierTest.java`（新建）
- **Approach**：
  1. JWT 声明集最小化：`sub`（userId）与 `jti`；解析失败/过期/黑名单命中统一 40101（`BizException.of(ErrorCode.UNAUTHORIZED)`）。
  2. 黑名单键 `jwt:bl:{jti}` 只读；Redis 异常 catch 后抛 50001（KTD7），不吞不降级放行。
  3. 上下文写入 `AuthContext`，RateLimitInterceptor 与后续业务域统一从 `AuthContext` 读——「上下文存在性」即 42907 的判定输入；userId 直写 MDC 由本拦截器完成（单一写点，KTD5 的 finally 清理与之衔接）。
  4. JWT_SECRET 经 SecretsProperties 注入 JwtVerifier；测试用固定密钥签发/验签（HMAC-SHA256）。
- **Patterns to follow**：`BizException.of` 工厂；构造器注入。
- **Test scenarios**：
  - 有效 Token 未入黑名单：放行，AuthContext 含 userId，MDC user_id 写入。
  - 无 Authorization 头：放行，上下文为空（游客）。
  - 无效签名/格式错/过期 Token：40101（三类各一断言）。
  - Token 在黑名单：40101。
  - Redis 查询抛异常：50001 而非 40101（防全量登出，KTD7）。
  - 带无效 Token 的匿名接口：40101 而非降级游客（KTD3）。
- **Verification**：`mvn test` 全绿；`mvn -q compile` 无 jjwt 未用告警。

### U4. RateLimiter + RateLimitKeys + RateLimitInterceptor

- **Goal**：11 行键表可声明、可计数、可超限；429xx 全走 ofRetryAfter；42907 鉴权后判定。
- **Requirements**：R5、R6（主）、R1。
- **Dependencies**：U3（AuthContext）、U1（常量/注解）。
- **Files**：
  - `src/main/java/com/s2s/server/common/ratelimit/RateLimitKeys.java`（新建；账号维方法收 userId、渠道维收 phone 与 ip、设备辅助维收 deviceId，类型分维防串用）
  - `src/main/java/com/s2s/server/common/ratelimit/RateLimiter.java`（新建；INCR+EXPIRE 原子 Lua，返回剩余秒与是否超限）
  - `src/main/java/com/s2s/server/common/ratelimit/RateLimitInterceptor.java`（新建）
  - `src/main/java/com/s2s/server/common/ratelimit/package-info.java`（修改；落地说明改写，[124]→[122]）
  - `src/main/java/com/s2s/server/config/WebCrosscutConfig.java`（修改；注册于 Auth 之后、Idempotency 之前）
  - `src/test/java/com/s2s/server/common/ratelimit/RateLimiterTest.java`（新建）
  - `src/test/java/com/s2s/server/common/ratelimit/RateLimitKeysTest.java`（新建）
  - `src/test/java/com/s2s/server/common/ratelimit/RateLimitInterceptorTest.java`（新建）
- **Approach**：
  1. 键拼装唯一实现处 `RateLimitKeys`（规范 §1.2）；`@RateLimit` 声明 `RateLimitTrack` 枚举数组，拦截器读 `AuthContext` 决定账号维键是否可用（无上下文且声明账号维 → 该轨跳过计数，guestdetail 双轨只经专用轨声明生效）；设备维 ID 从 `X-Device-Id` 头读取（契约三头之一，required，按 UUID 正则与长度上限校验，不符视为缺头——KTD14），**缺头/格式不符时该轨跳过、仅计其余轨**——限频件不做契约执法点，不新增 40001 分支，与「计数允许丢失」防御精神一致（架构验证 D8-1）。
  2. 42907 轨（`rl:guestdetail:dev/ip`）只在 `AuthContext` 为空时计数；上下文存在直接放行该轨——判定点天然在鉴权之后（链序保证）。
  3. INCR+EXPIRE 用一段 Lua 脚本原子执行（首 INCR 时设 TTL，防键永不过期）；`:1d` 轨键尾内嵌 `ZoneId` 常量（Asia/Shanghai）当日日期片 `yyyyMMdd`、TTL 26h 防跨日残留；`1m`/`1h` 轨固定滚动窗；`fz:` 冻结标记同批写入（KTD6）。
  4. 多轨超限取 max 剩余秒；超限抛 `BizException.ofRetryAfter(超限码, 秒)`——本单元即 P2 #4 修复的消费方验收。
  5. 限频计数允许丢失：Lua 执行异常记 WARN 并放行（防滥用非账务，详设 §3.4 纪律 3）——注意与 KTD7（鉴权黑名单读 50001）区分：计数写失败放行、黑名单读失败 50001。
- **Patterns to follow**：常量引用不复制字面量（规范 §0.2）；`ErrorCode.needRetryAfter` 断言范式。
- **Test scenarios**：
  - 键拼装：账号维方法签名收 userId、渠道维收 phone 与 ip、设备辅助维收 deviceId（编译期即分维）；11 行键形逐条对账 `RateLimitThresholds`。
  - 计数：窗口内 N 次后第 N+1 次超限，返回超限码与正确剩余秒（fake Redis 模拟）。
  - 多轨 max：两轨同时超限取剩余秒较大者。
  - 自然日：fake 时钟跨零点后计数归零。
  - 42907：上下文存在 → guestdetail 轨不计数；上下文为空 → 双轨计数且超限返 42907；缺 `X-Device-Id` 头或格式不符 → dev 轨跳过、IP 轨照常计数（KTD14）。
  - Retry-After：429xx 响应头为整数秒字符串（经 GlobalExceptionHandler 集成断言在 U7 重复）。
  - Redis 写失败：WARN 放行，不 50001。
- **Verification**：`mvn test` 全绿；静态扫描 `common/ratelimit` 无 Retry-After 头直写、无字面量阈值。

### U5. IdempotencyInterceptor（四类必测输入）

- **Goal**：SETNX 占位、轮询重放、失败删占位、成功缓存完整信封。
- **Requirements**：R7、R8（主）。
- **Dependencies**：U3（userId）、U1（常量/注解）。
- **Files**：
  - `src/main/java/com/s2s/server/common/idempotency/IdempotencyInterceptor.java`（新建）
  - `src/main/java/com/s2s/server/common/idempotency/IdempotencyCaptureFilter.java`（新建；响应体捕获 Filter，注册 REQUEST dispatch、位于 RequestIdFilter 之后）
  - `src/main/java/com/s2s/server/common/idempotency/package-info.java`（修改；[124]→[122]）
  - `src/main/java/com/s2s/server/config/WebCrosscutConfig.java`（修改；拦截器注册于链尾 + 本单元新增捕获 Filter 的 FilterRegistrationBean）
  - `src/test/java/com/s2s/server/common/idempotency/IdempotencyInterceptorTest.java`（新建）
  - `src/test/java/com/s2s/server/common/idempotency/IdempotencyCaptureFilterTest.java`（新建；copyBodyToResponse 绊线与 SET/DEL 出口断言）
- **Approach**（响应体捕获机制按架构评审 P0 修正：`ContentCachingResponseWrapper` 是 Servlet Filter 层捕获组件，preHandle 内包装无法传播给 handler——DispatcherServlet 向整条链传同一 response 引用，拦截器内包装的副本 handler 不可见，缓存恒空）：
  1. 响应捕获移至 Filter 层：`RequestIdFilter` 之后新增 `IdempotencyCaptureFilter`（注册 REQUEST dispatch、位于 RequestIdFilter 之后）以 `ContentCachingResponseWrapper` 包装 response；幂等判定仍在 `IdempotencyInterceptor`（纯判定件）：Key 正则校验（不符/缺失 40001）→ 键维度按 `@Idempotent.anonymous` 分流（KTD13；登录态无上下文 40101）→ SETNX `idem:{维度}:{key}` = PENDING（TTL 24h）→ 失败轮询（200ms/10s）：值仍 PENDING 继续等、值为完成 JSON 原样写出（含首次 request_id）、超时抛 50001；判定结果与「本请求是否幂等执行者」写入 request attribute 供 Filter 消费。
  2. `IdempotencyCaptureFilter` 出口（chain 返回后）：读缓存字节判 HTTP 2xx——成功且本请求是执行者 → SET（覆盖）完整信封 JSON；非 2xx 或业务异常 → DEL 占位键（DEL 失败记 ERROR，依赖 TTL 自愈，登记已知代价）；**末尾必调 `copyBodyToResponse()`**（wrapper 把 handler/advice 写出的内容截进内部缓存不落客户端，漏此调用则空响应；它同时自动更新 Content-Length）。重放原样写出也统一走 wrapper + `copyBodyToResponse()` 路径。
  3. 重放原样返回不进 Controller、不消耗限频以外的资源；故意不校验请求体差异。
- **Patterns to follow**：`IdempotencyPolicy` 常量引用；详设 §3.3 流程逐步镜像。
- **Test scenarios**（四类必测输入逐条对应 R8）：
  - 缺失 Idempotency-Key → 40001 不放行。
  - 大写 UUID / v1 UUID → 40001。
  - 同 Key 请求体不同 → 返回首次响应原文（断言逐字节相等，含首次 request_id，MDC 仍是本次值）。
  - 首次业务失败后同 Key 重放 → 重新执行（fake Redis 断言 DEL 被调、SETNX 二次成功）。
  - 并发双请求同 Key：一执行一等待，等待者拿到首次结果。
  - 轮询超时（fake 慢业务）→ 50001。
  - GET / 无注解接口：拦截器零动作、Filter 不缓存。
  - 成功响应覆盖 PENDING 且 TTL=24h（fake Redis 断言参数）。
  - 成功响应 body 非空且 Content-Length 正确（`copyBodyToResponse()` 漏调即空响应——绊线断言）。
  - 匿名写接口（`@Idempotent(anonymous=true)`）+ 合法 Key + `X-Device-Id` → `idem:dev:{deviceId}:{key}` SETNX 成功执行；缺设备头或格式不符 → `idem:anon:{key}` 分支（KTD13/KTD14）。
  - 匿名同 Key 重放 → 原样返回首次响应。
  - 登录态写接口无 AuthContext → 40101（KTD13 分支的另一侧）。
- **Verification**：`mvn test` 全绿；四类输入测试名可被 S1 出口验收直接点名。

### U6. P2 #8/#4 随修（advice 作用域 + BizException 构造期守卫）

- **Goal**：/error 错误派发不再被套 code=0；needRetryAfter 缺秒在构造期不可表示。
- **Requirements**：R10。
- **Dependencies**：U1（可独立提前）。
- **Files**：
  - `src/main/java/com/s2s/server/common/web/ResponseBodyWrapper.java`（修改；`@RestControllerAdvice(basePackages = "com.s2s.server")`）
  - `src/main/java/com/s2s/server/common/web/GlobalExceptionHandler.java`（修改；同上）
  - `src/main/java/com/s2s/server/common/error/BizException.java`（修改；`of()` 拒收 needRetryAfter 码抛 IllegalArgumentException、`ofRetryAfter()` 对称拒收）
  - `src/test/java/com/s2s/server/common/error/BizExceptionTest.java`（新建/扩充）
  - `src/test/java/com/s2s/server/common/web/AdviceScopeTest.java`（新建）
- **Approach**：守卫与「让错误不可表示」范式对齐 SecretsProperties（评审 suggested_fix 原文）；advice 作用域断言用 Spring 的 `ControllerAdviceBean` 过滤行为单测 + standalone MockMvc 的 NoResourceFoundException → 50001 信封断言；BasicErrorController 原生返回（无 code=0）作为已知边界登记（KTD12）。
- **Test scenarios**：
  - `of(42901..42907/40105 任一)` → IllegalArgumentException（参数化 8 码）。
  - `ofRetryAfter(非 Retry-After 码)` → IllegalArgumentException。
  - advice 作用域：`org.springframework.boot.web.servlet.error.BasicErrorController` 不被两 advice 匹配（`ControllerAdviceBean.isApplicableToBeanType` 断言）；`com.s2s.server.*` controller 匹配。
  - standalone MockMvc 打不存在路由 → **双出口预备**（架构验证 D5）：404 场景 handlerType=null，basePackages 选择子下 advice 可能不适用——实测若 404 被 advice 接住则断言 50001 信封（含 request_id）；若不接住则断言「响应非 code=0 假成功信封」（同样满足 #8 验收）；两出口任一成立即过，不预设哪个。
  - 既有 17 项测试零回归（advice 加参不影响业务断言）。
- **Verification**：`mvn test` 全绿；P2 #8/#4 在说明文档登记为已修（U8 收口）。

### U7. 横切链集成断言（链序与 S1 出口）

- **Goal**：链序、42907 鉴权后判定、Retry-After 整数秒、信封形态以 standalone MockMvc 一体断言。
- **Requirements**：R1（主）、R6、R8 交叉、S1 出口三条。
- **Dependencies**：U2、U3、U4、U5、U6。
- **Files**：
  - `src/test/java/com/s2s/server/crosscut/CrosscutChainIntegrationTest.java`（新建；包名 crosscut 为测试专用，不进 main）
  - `src/test/java/com/s2s/server/crosscut/StubControllers.java`（新建；@Idempotent/@RateLimit 标注的 stub）
  - `src/test/java/com/s2s/server/config/WebCrosscutConfigOrderTest.java`（新建；注册序单测，防手拼链序对生产配置类错误免疫）
- **Approach**：`standaloneSetup(stub) + addFilters(requestIdFilter, captureFilter) + addInterceptors(按 WebCrosscutConfig 同序) + setControllerAdvice(wrapper, handler)` + fake Redis；断言全部走行为而非实现细节；另以 WebCrosscutConfigOrderTest 直接实例化配置类捕获 `addInterceptors` 调用顺序断言真实注册序。此测试是 S1 出口「横切链自测过」的载体。
- **Test scenarios**：
  - 同一请求同时满足「限流超限 + 缺幂等键」→ 先返 429（链序：限流先于幂等）。
  - 带有效 Token 的详情请求 → guestdetail 轨零计数（42907 鉴权后判定）。
  - 未登录详情请求超 30/d → 429 + Retry-After 整数秒 + 信封含 request_id、message 不含维度信息。
  - 幂等重放请求 → 逐字节首次响应（与 U5 单测互证）。
  - 全链 request_id：响应体 request_id == Filter 生成值（MDC/属性/信封三处一致）。
  - 40101/50001 路径信封形态正确（含 Retry-After 仅在 needRetryAfter 码）。
  - WebCrosscutConfigOrderTest：addInterceptors 注册序 == Auth → RateLimit → Idempotency。
- **Verification**：`mvn test` 全绿；本测试文件即 S1 出口验收证据。

### U8. 文档漂移回写 + 进度收口

- **Goal**：[124]→[122] 九处订正、依据源回写、gap-register 登记、说明文档进度更新。
- **Requirements**：R9 收尾、KTD6/KTD11 回写义务。
- **Dependencies**：U1–U7 全部。
- **Files**：
  - `src/main/java/com/s2s/server/common/web/ResponseBodyWrapper.java`、`GlobalExceptionHandler.java`、两测试与 `RequestContextFixtures`、`common/ratelimit/package-info.java`、`common/idempotency/package-info.java`（修改；漂移点 1–9 全量订正，U2/U4/U5 已顺带改的复核）
  - `docs/design/后端详细设计文档.md`（修改；§3.4 窗口语义「自然日 + 键尾日期片」一行、§3.3 匿名幂等键维度一行（KTD13，含「幂等只防重试、防滥用由渠道限频轨兜底」边界句）、§1.2 补五个组件落点条目（AuthInterceptor→auth 域、RateLimitInterceptor/RateLimit 注解/RateLimitTrack→common/ratelimit、AuthContext 与根 config 包）并订正 [124]→[122] 编号、轮询参数 KTD4 回写）
  - `docs/architecture/编码规范.md`（修改；§3.1 加限频阈值单端正源例外一行）
  - `说明文档.md`（修改；[122] 进度记录 + P2 #8/#4 已修标记 + 「Redis 会话存储 = 黑名单查询点 + `jwt:bl:{jti}` 键形，写入随 [123] logout」拆解口径一句（防 S1 出口验收争议，架构验证 D8-3）+ gap-register 轮询参数/黑名单 jti 兜底两项登记）
- **Approach**：漂移清单以研究 §8 九处为准逐一核销；说明文档按个人规则标记完成并补结果说明（测试计数、验收三条、遗留项）。
- **Test scenarios**：Test expectation: none —— 纯文档单元；以 grep 复核九处零残留 `[124] RequestIdFilter`/`[124] RateLimiter`/`[124] IdempotencyInterceptor` 字样。
- **Verification**：`git grep -n "\[124\]" src/` 仅剩 common/crypto 组件合法引用，九处漂移点（RequestIdFilter/RateLimiter/IdempotencyInterceptor 等）零残留；说明文档 [122] 段完整。

---

## Verification Contract

- **单元门禁**：每单元 `mvn test` 全绿后提交（Conventional Commits，分支 `item/122-crosscut-chain`）。
- **条目出口**（S1 出口三条 + DoD）：
  - `mvn test` 全量全绿（基线 17 项只增不减 + 新增约 40–50 项）。
  - S1 三条验收（幂等四类、Retry-After 整数秒、42907 鉴权后判定）+ 链序（R1）断言点名通过；幂等四类在 `IdempotencyInterceptorTest`、其余三条在 `CrosscutChainIntegrationTest`。
  - 静态守门：`git grep "Retry-After" src/main/java -- ':!**/GlobalExceptionHandler.java'` 零命中；`common/` 与 `auth/` 无阈值字面量（全部引用常量类）。
- **不适用**：`flutter analyze`/`flutter test`（无前端改动，不触发）；`release:validate`（非出包条目）；test/gates 契约守门只读 openapi 不受影响。
- **联调留证（非单测）**：本地 compose 起 Redis 后跑 smoke：一条常规请求看 8 字段 JSON 日志 + 幂等四类输入 + 同 Key 并发双请求（一执行一等待）+ 一次限频超限；结果文件留证于工作树外部。

## Definition of Done

- **Global**：R1–R10 全部有实现与断言承载；S1 出口三条验收绿；四项随修/回写（#8、#4、九处漂移、详设/规范回写）完成；gap-register 新增登记（轮询参数、jti 兜底、@Idempotent 须伴 @RateLimit 守门）；说明文档 [122] 段落完整并标记完成；工作区无废弃实验代码（cleanup criterion）。
- **Per-unit**：各单元 Verification 字段全过 + `mvn test` 全绿；U8 的 grep 复核零残留。
- **Handoff**：ce-code-review 评审收据归档后按 Phase 4 ship 流程并回 main（--no-ff）。
