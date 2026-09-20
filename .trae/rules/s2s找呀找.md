# s2s 编码红线（常驻）

> 完整规范的**唯一正文**是 `docs/architecture/编码规范.md`，按下表按需 Read。本文只放红线、依据源索引与分派指引，不含规范细节。

## 三条全局硬纪律（违反以缺陷论处）

1. **不复制字面量** —— 阈值／TTL／上限／超时／批次大小只引用常量名（Dart `NfrXxx`、Java `common` 常量类），禁写死数字
2. **不新增错误码** —— 唯一口径源 PRD §12.5（24 码 + `0` = 25 枚举），代码侧禁占号
3. **不凭位置信重试** —— 重试／重放／重发靠显式「containsKey 才写」保全 `Idempotency-Key` 与 `X-Interaction-Id`，不依赖拦截器顺序

## 安全红线

- 日志禁出现完整手机号／身份证号／联系方式与 `Authorization` 头
- 解密唯一入口 `CryptoFacade`，且必须同步同事务写 `audit_log`
- 设计文档未覆盖的口径先问，**禁在业务代码中自创口径**

## 依据源索引（正文 §0.1 的高频子集）

| 简称 | 文档 | 简称 | 文档 |
| --- | --- | --- | --- |
| 详设-后端 | [后端详细设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/design/后端详细设计文档.md) | 详设-前端 | [前端详细设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/design/前端详细设计文档.md) |
| 架构 | [系统总体架构设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/系统总体架构设计文档.md) | 数据库 | [数据库设计文档.md](file:///d:/developer/code/aicoding/s2s/docs/database/数据库设计文档.md) |
| 技术栈 | [技术栈选型说明.md](file:///d:/developer/code/aicoding/s2s/docs/architecture/技术栈选型说明.md) | 契约 | [openapi.yaml](file:///d:/developer/code/aicoding/s2s/docs/api/openapi.yaml) |
| PRD | [PRD.md](file:///d:/developer/code/aicoding/s2s/docs/PRD.md) | 常量真源 | [nfr_constants.dart](file:///d:/developer/code/aicoding/s2s/lib/nfr_constants.dart) |

> 安全／部署／可观测／DevSecOps 四份低频文档的映射见正文 §0.1 完整表。

## 按需读取指引（Read `docs/architecture/编码规范.md`）

| 你的任务 | 读哪些章节 |
| --- | --- |
| 改后端 Java（`src/`） | §0.3、§1、§2、§3、§4、§6 |
| 改前端 Dart（`lib/`） | §0.3、§1、§2、§3、§5 |
| 写／跑测试 | §7 |
| 出包／发版 | §8 |
| 查待关闭缺口、通用基线 | §9、§10 |

## 每端一条最硬摘要

- **后端**：横切链顺序 `RequestIdFilter → AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor → Controller` 不可调换，限流必先于幂等
- **前端**：全局唯一重试点是 `RetryInterceptor`，`lib/features/` 禁 `for` 循环重试
