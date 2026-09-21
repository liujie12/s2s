# [123] auth 域后端实现 + cert 空壳 + 加解密基础件

**Created:** 2026-09-19
**Status:** draft
**artifact_contract:** ce-unified-plan/v1
**artifact_readiness:** implementation-ready
**product_contract_source:** ce-plan-bootstrap

---

## Product Contract

### Summary

实现 auth 域 6 个接口（短信发码、短信登录、Token 续期、登出、查/改本人资料）+ cert 空壳（供 post 域查实名状态）+ 加解密基础件（HMAC 盲索引 + AEAD 原语），使后端具备真实登录能力，支撑前后端联调。

### Problem Frame

[121] 后端工程初始化 + [122] 横切链四件已完成，但业务 Controller 为 0——`/auth/*`、`/users/me` 全是 404。前端 [123] 网络骨架 + [124]/[125] 发布链已用 MockApiServer 跑通（527/527），但无法与真服务联调。

本条目是**关键路径上的第一块业务拼图**：登录是五大 P0 闭环（账号→发布→首页地图→详情→联系）的起点，不解决登录，后续所有需要登录态的接口（发布、收藏、联系）都无法真链路验证。

### Requirements

#### R1: 短信验证码发送

- **接口**: `POST /auth/sms/send`
- **入参**: `phone`（11 位手机号）+ `scene`（Batch1 仅 `login`）
- **出参**: `expire_in`（验证码有效期，秒）
- **限频**: 渠道级限频——同手机号 1 分钟 1 条 / 1 小时 5 条 / 1 天 10 条；同 IP 1 小时 20 条；超限回 `42905` + `Retry-After`
- **验证码存储**: Redis（`sms:{phone}`），不落库
- **Batch1 口径**: 短信渠道用 dev 桩（固定验证码 `888888`），不接真服务商

#### R2: 短信验证码登录（含首次注册）

- **接口**: `POST /auth/sms/login`
- **入参**: `phone` + `code`（6 位数字）+ `agreed`（是否勾选协议）+ 可选 `platform`/`push_token`
- **出参**: `LoginResult`（token + is_new_user + user_id）
- **关键逻辑**:
  - `agreed=false` 或缺失 → `40002`
  - 连续 5 次验证码错误 → 锁定 15 分钟，回 `40105` + `Retry-After`
  - 手机号不存在 → 自动注册（写 `user` + `user_identity`），`is_new_user=true`
  - 登录成功写 `device` 表（以 `X-Device-Id` 为指纹）
  - 签发 JWT（单 Token 模型，有效期 30 天）
- **手机号处理三步**（顺序不可换）:
  1. `phoneHash = BlindIndex.hmac(phone)` → 查 `user_identity` 唯一索引
  2. 命中 → 取 `user_id`；未命中 → 建 `user` + `user_identity`（`identity_value_enc` 的 AAD 为 `user_id + identity_type`，故必须先拿到 `user_id` 再加密）
  3. `user.phone_mask` 写脱敏串（仅本人视角展示用）

#### R3: Token 续期

- **接口**: `POST /auth/token/refresh`
- **入参**: 无请求体；当前（已失效）Token 于 `Authorization` 头
- **出参**: `LoginResult`（新 token）
- **关键逻辑**: 校验旧 Token 签名（允许已过期）+ 用户状态；重签发
- **客户端约定**: 由客户端在收到任意 `40101` 后单飞调用（并发场景实际调用次数必须等于 1）

#### R4: 登出

- **接口**: `POST /auth/logout`
- **入参**: 无请求体；当前 Token 于 `Authorization` 头
- **关键逻辑**:
  - Token 加入 Redis 黑名单至原过期时刻（键 `jwt:bl:{jti}`）
  - 清 `device.push_token`
- **黑名单读写分工**: [122] 只落地读路径（`AuthInterceptor` 查黑名单），本条目落地写路径（logout 时写黑名单）

#### R5: 查本人资料

- **接口**: `GET /users/me`
- **出参**: `MyProfile` DTO（严格走对外视图白名单）
- **白名单**:
  - 允许：`id` / `nickname` / `avatar_url` / `realname_status` / `qualification_badges[]`
  - 本人视角额外允许：`phone_mask` / `default_radius`
  - **禁止**出现在任何 API 响应中：`real_name_enc` / `id_card_hash`
- **落地手段**: `MyProfile` DTO 是唯一的 user 出参类型，`UserEntity` 不得直接返回

#### R6: 改本人资料

- **接口**: `PATCH /users/me`
- **入参**: `nickname` / `avatar_url`（`media_id`）/ `default_radius`
- **关键逻辑**:
  - 昵称过敏感词 → `40901`
  - 头像 `media_id` 须 `audit_status=pass` 否则 `40902`

#### R7: 加解密基础件

- **BlindIndex**: HMAC-SHA256 + pepper，生成确定性盲索引（用于 `user_identity.identity_hash`）
- **CryptoFacade**: AES-GCM-256 加解密原语（用于 `user_identity.identity_value_enc`）
  - 加密：随机 IV + AAD 绑定
  - 解密：**同步写 `audit_log`**（合规审计留痕）
- **密钥列表解析**: 从 `HMAC_PEPPERS_JSON` / `AEAD_MASTER_KEYS_JSON` 解析 key_version 列表结构
- **Batch1 解密调用点**: 仅 `contact.ContactService#viewContact`（`GET /posts/{id}/contact`），本条目不实现 contact 域，但须预留 `CryptoFacade` 接口

#### R8: cert 空壳

- **CertService#getRealnameStatus(userId)**: 供 `post` 域判 `40302`/`40304`
- **Batch1 口径**: 恒返回 `NONE`
- **包结构**: `cert/` 目录保留，`ErrorCode` 中的 `40302`/`42901`/`50301`/`50302` 枚举值保留（契约与客户端枚举必须保留，否则 Batch2 上线时客户端不认识这些码）

### Scope Boundaries

#### In Scope

- auth 域 6 个接口（R1-R6）
- 加解密基础件（R7）
- cert 空壳（R8）
- Redis 会话与登出黑名单的**写入**侧（[122] 只留了读路径）
- 登录失败计数与渠道级限频的接线
- 前端 auth 接线（登录页消费真网络、Token 持久化、后门验证码 kDebugMode 包裹）

#### Out of Scope

- [124] 起的所有后续域（category/post/map/contact/notify/track）
- 媒体/OSS 直传
- cert 真 SDK（Batch2）
- template 种子
- 非 auth 域的前端接线
- 图形验证码（PRD §3.4.1 有，但 OpenAPI 契约无，待 DEC-05 裁定）

### Key Decisions

#### KD1: 短信渠道用 dev 桩（session-settled: user-directed）

- **决策**: Batch1 短信发码接口返回固定验证码 `888888`，不接真服务商
- **chosen over**: 接真短信服务商（阿里云/腾讯云短信）
- **reason**: 9/30 交付内测包，时间不够；种子用户容忍度高；真服务商接入需资质审核（1-2 周）

#### KD2: 加解密基础件随 [123] 落地（session-settled: user-directed）

- **决策**: HMAC/AEAD 原语与密钥列表解析随本条目落地，不等 [124]
- **chosen over**: 等 [124] crypto 组件落地
- **reason**: 登录必须写 `user_identity` 的两列（`identity_hash` + `identity_value_enc`），没有加解密基础件无法完成注册流程

#### KD3: 前端 auth 接线并入 [123]（session-settled: user-directed）

- **决策**: 登录页消费真网络、Token 持久化介质评审、既有后门验证码的调试期包裹随本条目交付
- **chosen over**: 前端 auth 接线留到后续条目
- **reason**: 本条目结束后需端到端真登录验证，否则无法确认前后端联调通

#### KD4: 登录方式三阶段演进（session-settled: user-directed — DEC-06）

- **决策**: Batch1 短信验证码 → Batch2 追加微信 + 一键登录 → Batch3 一键登录升主
- **chosen over**: Batch1 直接上一键登录
- **reason**: 9/30 交付时间不够；`user_identity` 表已预留多身份挂载，追加登录方式不改表结构

### Success Criteria

- [ ] auth 域 6 个接口全部可调用（Postman/curl 实测）
- [ ] 短信发码接口返回固定验证码 `888888`
- [ ] 登录成功签发 JWT（30 天有效期）
- [ ] Token 续期接口可正常工作（旧 Token 过期仍可换新）
- [ ] 登出后 Token 加入黑名单，续期接口返回 `40101`
- [ ] `GET /users/me` 响应不含 `real_name_enc` / `id_card_hash`
- [ ] `PATCH /users/me` 昵称敏感词拦截生效
- [ ] `BlindIndex.hmac(phone)` 输出与 Dart 侧 `BlindIndex.hmac` 一致（三端逐位一致）
- [ ] `CryptoFacade.encrypt/decrypt` 加解密往返一致，且解密同步写 `audit_log`
- [ ] `CertService#getRealnameStatus` 恒返回 `NONE`
- [ ] 前端登录页可完成真实登录流程（输入手机号 → 获取验证码 → 输入验证码 → 登录成功 → 跳转首页）
- [ ] Token 持久化到本地（SharedPreferences/Keychain），重启 APP 仍保持登录态
- [ ] `mvn test` 全绿（基线只增不减）
- [ ] `flutter test` 全绿（基线只增不减）

---

## Planning Contract

### Key Technical Decisions

#### KTD1: 验证码存储结构

- **Redis 键**: `sms:{phone}`
- **值**: `{code: "888888", expire_at: <timestamp>, fail_count: 0}`
- **TTL**: 5 分钟（`expire_in` = 300 秒）
- **失败计数**: 同一验证码连续错误 5 次 → 锁定 15 分钟（键 `sms:lock:{phone}`）

#### KTD2: JWT 签发参数

- **算法**: HS256
- **密钥**: `JWT_SECRET`（环境变量，≥32 字节）
- **声明集**:
  - `sub`: `user_id`（Long 型）
  - `jti`: UUID v4（Token 唯一标识）
  - `iat`: 签发时刻
  - `exp`: 过期时刻（`iat + 30 天`）
- **不解析 `exp`**: jjwt 默认校验，本类不做扩展预留

#### KTD3: 设备指纹处理

- **`X-Device-Id` 明确不可信**，禁止采集 IMEI / MAC / IDFA / OAID
- **`device` 表写入**: 以 `X-Device-Id` 为指纹，更新 `push_token` / `platform` / `last_login_at`
- **设备指纹缺失**: 不拦截登录，但 `device` 表写匿名行（`device_id = null`）

#### KTD4: 对外视图白名单落地手段

- **DTO 隔离**: `AuthorBrief` / `MyProfile` 两个 DTO 是唯一的 user 出参类型
- **Entity 禁返**: `UserEntity` 不得直接返回（写一条集成测试扫描全部响应 JSON，断言不含 `real_name`、`id_card` 字样）
- **本人视角分流**: `MyProfile` 含 `phone_mask` / `default_radius`；`AuthorBrief` 不含

#### KTD5: 加解密基础件接口设计

> **实现回写（2026-09-19，U1 落地时）**：本决策初稿把 `key_version` 编进密文前缀，与详设 §4.1
> 的三列范式（`xxx_hash` + `xxx_enc` + `key_version` **独立列**）冲突，且 `user_identity` 表确有
> `key_version TINYINT NOT NULL` 列。已按详设对齐：**版本号不编进密文**，由调用方从独立列读入后显式传入。
> 同步改动：`BlindIndex.hmac` 返回 `byte[]`（直接映射 `BINARY(32)`，免去 SQL 侧 `UNHEX()` 转换点）；
> 新增 `CryptoFacade.EncryptResult` 让「密文 + 版本号」同源返回，避免调用方猜版本号。

- **BlindIndex**:
  ```java
  public static byte[] hmac(String phone, List<Pepper> peppers)   // 32 字节，落 BINARY(32)
  public static byte[] hmac(String phone, Pepper pepper)          // 单 pepper，跨版本验证用
  ```
  - 取 `version` **数值最大**的 pepper（不依赖列表顺序）
  - 输出 32 字节原始 HMAC-SHA256，直接对应 {@code BINARY(32)} 列

- **CryptoFacade**:
  ```java
  public record EncryptResult(int keyVersion, byte[] ciphertext) {}
  public EncryptResult encrypt(String plaintext, String aad)
  public String decrypt(byte[] ciphertext, String aad, int keyVersion)
  ```
  - 加密：用 `version` 最大的主密钥 + 随机 IV（12 字节）+ AAD 绑定 →
    密文布局 `iv(12) || ciphertext(明文 + 16 字节 GCM 标签)`，落 `VARBINARY`；版本号由 `EncryptResult` 同源带回
  - 解密：按传入的 `keyVersion` 取密钥 → 解密 → **同步写 `audit_log`**
    （`audit_log` 表已建，Mapper 随 U2 持久层落地；当前为日志占位，见代码内 TODO）

#### KTD6: 密钥列表解析

- **JSON 结构**（`version` 为数值，对应 `key_version TINYINT` 列）:
  ```json
  [
    {"version": 1, "key": "<hex 或 base64 编码的 32 字节密钥>"},
    {"version": 2, "key": "<hex 或 base64 编码的 32 字节密钥>"}
  ]
  ```
- **解析时机**: 应用启动期（`SecretsProperties` 守卫后），由 `CryptoConfig` 的 `@Bean` 方法执行一次
- **快速失败**: JSON 格式错误 / 列表为空 / `version` 缺失或非整数 / 密钥为空白 → 抛异常致启动失败
- **编码宽容**: 值先按 hex 判定（偶数长度且全为十六进制字符），否则按 base64 解析
  （收敛在 `KeyEncodings.decode`，避免两处实现漂移）

#### KTD7: 前端 Token 持久化

- **Android**: `SharedPreferences`（加密存储，使用 `EncryptedSharedPreferences`）
- **iOS**: `Keychain`
- **Flutter 封装**: `flutter_secure_storage` 插件（已在 `pubspec.yaml`）
- **存储内容**: `access_token`（JWT 字符串）+ `token_expire_at`（时间戳）

#### KTD8: 后门验证码调试期包裹

- **现状**: `auth_repository.dart:343` 有 `static const String _debugCode = '888888'`
- **处理**: 用 `kDebugMode` 包裹，release 编译期消除
- **联调期**: 保留后门，方便快速登录测试
- **出包前**: 必须删除后门（L3 门禁扫描）

### Implementation Units

#### U1: 加解密基础件

- **文件**:
  - `src/main/java/com/s2s/server/common/crypto/BlindIndex.java`
  - `src/main/java/com/s2s/server/common/crypto/CryptoFacade.java`
  - `src/main/java/com/s2s/server/common/crypto/Pepper.java`
  - `src/main/java/com/s2s/server/common/crypto/MasterKey.java`
  - `src/main/java/com/s2s/server/common/crypto/KeyEncodings.java`（U1 落地时新增：hex/base64 宽容解码收敛点）
  - `src/main/java/com/s2s/server/common/config/CryptoConfig.java`（U1 落地时新增：密钥列表 JSON → Bean）
- **测试**:
  - `src/test/java/com/s2s/server/common/crypto/BlindIndexTest.java`
  - `src/test/java/com/s2s/server/common/crypto/CryptoFacadeTest.java`
- **验收**:
  - `BlindIndex.hmac("13800138000")` 输出与 Dart 侧一致
  - `CryptoFacade.encrypt/decrypt` 往返一致
  - 解密同步写 `audit_log`（断言行数 +1）

#### U2: 持久层最小设施（U1 落地时补入）

- **文件**:
  - `src/main/java/com/s2s/server/S2sServerApplication.java`（改：加 `@MapperScan`）
  - `src/main/java/com/s2s/server/auth/entity/UserEntity.java`
  - `src/main/java/com/s2s/server/auth/entity/UserIdentityEntity.java`
  - `src/main/java/com/s2s/server/auth/entity/DeviceEntity.java`
  - `src/main/java/com/s2s/server/auth/mapper/UserMapper.java`
  - `src/main/java/com/s2s/server/auth/mapper/UserIdentityMapper.java`
  - `src/main/java/com/s2s/server/auth/mapper/DeviceMapper.java`
  - `src/main/resources/application.yml`（改：MyBatis-Plus 配置段）
- **验收**:
  - 三张表 entity 字段与 `V1__init_schema.sql` **逐列**对齐，含类型映射
    （`BINARY(32)`→`byte[]`、`VARBINARY`→`byte[]`、`ENUM`→`String` 或枚举、`DATETIME`→`LocalDateTime`）
  - `identity_hash` 以 `byte[]` 写入后按等值查询能命中（验证 `BINARY(32)` 映射无隐式编码转换）
  - 应用能带数据源启动（`/actuator/health` UP），Flyway 校验通过
  - 不引入 Mapper XML（本单元只用 MyBatis-Plus 基础 CRUD）；性能语句留待后续域按详设 §7 加 EXPLAIN 注释

#### U3: auth 域骨架 + DTO

- **文件**:
  - `src/main/java/com/s2s/server/auth/AuthService.java`
  - `src/main/java/com/s2s/server/auth/SmsService.java`
  - `src/main/java/com/s2s/server/auth/UserService.java`
  - `src/main/java/com/s2s/server/auth/dto/LoginRequest.java`
  - `src/main/java/com/s2s/server/auth/dto/LoginResult.java`
  - `src/main/java/com/s2s/server/auth/dto/SendCodeRequest.java`
  - `src/main/java/com/s2s/server/auth/dto/SendCodeResult.java`
  - `src/main/java/com/s2s/server/auth/dto/MyProfile.java`
  - `src/main/java/com/s2s/server/auth/dto/UpdateProfileRequest.java`
- **测试**: 无（DTO 无逻辑）
- **验收**: DTO 字段与契约逐字对齐

#### U4: 短信发码接口

- **文件**:
  - `src/main/java/com/s2s/server/auth/AuthController.java`（`sendSmsCode` 方法）
  - `src/main/java/com/s2s/server/auth/SmsService.java`（`sendCode` 方法）
- **测试**:
  - `src/test/java/com/s2s/server/auth/SmsServiceTest.java`
- **验收**:
  - 返回 `expire_in=300`
  - Redis 写入 `sms:{phone}` 键
  - 限频生效（连续 6 次回 `42905`）

#### U5: 短信登录接口

- **文件**:
  - `src/main/java/com/s2s/server/auth/AuthController.java`（`smsLogin` 方法）
  - `src/main/java/com/s2s/server/auth/AuthService.java`（`loginBySms` 方法）
- **测试**:
  - `src/test/java/com/s2s/server/auth/AuthServiceTest.java`
- **验收**:
  - 正确验证码 → 返回 JWT + `is_new_user=false`
  - 错误验证码 5 次 → `40105` + `Retry-After`
  - 新手机号 → 自动注册 + `is_new_user=true`
  - `agreed=false` → `40002`

#### U6: Token 续期接口

- **文件**:
  - `src/main/java/com/s2s/server/auth/AuthController.java`（`refreshToken` 方法）
  - `src/main/java/com/s2s/server/auth/AuthService.java`（`refresh` 方法）
- **测试**:
  - `src/test/java/com/s2s/server/auth/AuthServiceTest.java`（续期用例）
- **验收**:
  - 有效 Token → 返回新 JWT
  - 过期 Token（签名合法）→ 返回新 JWT
  - 无效 Token（签名非法）→ `40101`
  - 黑名单 Token → `40101`

#### U7: 登出接口

- **文件**:
  - `src/main/java/com/s2s/server/auth/AuthController.java`（`logout` 方法）
  - `src/main/java/com/s2s/server/auth/AuthService.java`（`logout` 方法）
- **测试**:
  - `src/test/java/com/s2s/server/auth/AuthServiceTest.java`（登出用例）
- **验收**:
  - Token 加入 Redis 黑名单（`jwt:bl:{jti}`）
  - `device.push_token` 清空
  - 续期接口返回 `40101`

#### U8: 本人资料接口

- **文件**:
  - `src/main/java/com/s2s/server/auth/UserController.java`
  - `src/main/java/com/s2s/server/auth/UserService.java`
- **测试**:
  - `src/test/java/com/s2s/server/auth/UserServiceTest.java`
- **验收**:
  - `GET /users/me` 响应不含 `real_name_enc` / `id_card_hash`
  - `PATCH /users/me` 昵称敏感词拦截生效
  - `PATCH /users/me` 头像 `media_id` 未审核通过 → `40902`

#### U9: cert 空壳

- **文件**:
  - `src/main/java/com/s2s/server/cert/CertService.java`
- **测试**:
  - `src/test/java/com/s2s/server/cert/CertServiceTest.java`
- **验收**:
  - `getRealnameStatus(userId)` 恒返回 `NONE`

#### U10: 前端 auth 接线

- **文件**:
  - `lib/features/auth/auth_repository.dart`（改：删除内存 mock，改调真网络）
  - `lib/features/auth/login_screen.dart`（改：消费真网络）
  - `lib/core/storage/token_storage.dart`（新：Token 持久化）
- **测试**:
  - `test/features/auth/auth_repository_test.dart`
- **验收**:
  - 登录页可完成真实登录流程
  - Token 持久化到本地，重启 APP 仍保持登录态
  - 后门验证码 `kDebugMode` 包裹

#### U11: 集成测试 + 契约示范测试

- **文件**:
  - `src/test/java/com/s2s/server/auth/AuthIntegrationTest.java`
  - `test/contract/auth_contract_test.dart`（前端契约示范测试）
- **验收**:
  - 后端集成测试扫描全部响应 JSON，不含 `real_name` / `id_card` 字样
  - 前端契约示范测试 baseUrl 切真服务，断言一行不改

### Dependencies

| 依赖 | 状态 | 说明 |
| --- | --- | --- |
| [121] 后端工程初始化 | ✅ 完成 | Maven 骨架 + Flyway + ErrorCode |
| [122] 横切链四件 | ✅ 完成 | RequestIdFilter → AuthInterceptor → RateLimitInterceptor → IdempotencyInterceptor |
| [123] 前端网络骨架 | ✅ 完成（已合 main） | 五拦截器 + ApiErrorCode |
| 联调环境 | ✅ 完成 | MySQL 8.0.46（WSL2 Docker）+ Redis 3.0.504（Windows 服务）+ 分类树种子 74 行 |
| **持久层设施（MyBatis-Plus entity / mapper / 配置）** | ⚠️ **原缺，已拆为独立单元 U2** | `pom.xml` 已引入 `mybatis-plus-spring-boot3-starter` 3.5.17 与 MySQL 驱动，但 `src/main/java` 下**没有任何 entity、mapper 接口或 Mapper XML，也无 `@MapperScan`**。原计划把该段并进「骨架 + DTO」，低估了工作量；U1 落地时发现后**拆为独立单元 U2**（先于 U3 执行），原 U2–U10 顺延为 U3–U11 |

### Risks

| 风险 | 影响 | 缓解措施 |
| --- | --- | --- |
| 短信服务商资质审核周期不可控 | Batch2 微信登录可能延期 | 建议 Batch1 期间并行申请（DEC-06） |
| 加解密基础件实现复杂 | 可能阻塞登录流程 | 先实现 HMAC 盲索引（登录必须），AEAD 原语可简化（Batch1 只写不读） |
| 前端 Token 持久化介质评审 | 可能发现安全风险 | 用 `flutter_secure_storage`（成熟插件），评审聚焦配置而非实现 |
| 图形验证码口径未定 | PRD 有、契约无，可能返工 | 登记为 DEC-05，Batch1 先不做图形验证码 |

### Assumptions

- 短信渠道用 dev 桩（固定验证码 `888888`），不接真服务商
- 图形验证码 Batch1 不做（DEC-05 待裁定）
- 微信登录/一键登录 Batch2 再做（DEC-06）
- 前端 auth 接线并入本条目（登录页消费真网络、Token 持久化、后门验证码 kDebugMode 包裹）

---

## Implementation Units

### U1: 加解密基础件

**Files:**
- `src/main/java/com/s2s/server/common/crypto/BlindIndex.java`
- `src/main/java/com/s2s/server/common/crypto/CryptoFacade.java`
- `src/main/java/com/s2s/server/common/crypto/Pepper.java`
- `src/main/java/com/s2s/server/common/crypto/MasterKey.java`

**Tests:**
- `src/test/java/com/s2s/server/common/crypto/BlindIndexTest.java`
- `src/test/java/com/s2s/server/common/crypto/CryptoFacadeTest.java`

**Acceptance:**
- `BlindIndex.hmac("13800138000")` 输出与 Dart 侧一致
- `CryptoFacade.encrypt/decrypt` 往返一致
- 解密同步写 `audit_log`（断言行数 +1）

### U2: 持久层最小设施（U1 落地时补入）

**Files:**
- `src/main/java/com/s2s/server/S2sServerApplication.java`（改：加 `@MapperScan`）
- `src/main/java/com/s2s/server/auth/entity/UserEntity.java`
- `src/main/java/com/s2s/server/auth/entity/UserIdentityEntity.java`
- `src/main/java/com/s2s/server/auth/entity/DeviceEntity.java`
- `src/main/java/com/s2s/server/auth/mapper/UserMapper.java`
- `src/main/java/com/s2s/server/auth/mapper/UserIdentityMapper.java`
- `src/main/java/com/s2s/server/auth/mapper/DeviceMapper.java`
- `src/main/resources/application.yml`（改：MyBatis-Plus 配置段）

**Acceptance:**
- 三张表 entity 字段与 `V1__init_schema.sql` 逐列对齐，含类型映射（`BINARY(32)`→`byte[]`、`VARBINARY`→`byte[]`、`ENUM`→`String` 或枚举、`DATETIME`→`LocalDateTime`）
- `identity_hash` 以 `byte[]` 写入后按等值查询能命中（验证 `BINARY(32)` 映射无隐式编码转换）
- 应用能带数据源启动（`/actuator/health` UP），Flyway 校验通过

### U3: auth 域骨架 + DTO

**Files:**
- `src/main/java/com/s2s/server/auth/AuthService.java`
- `src/main/java/com/s2s/server/auth/SmsService.java`
- `src/main/java/com/s2s/server/auth/UserService.java`
- `src/main/java/com/s2s/server/auth/dto/LoginRequest.java`
- `src/main/java/com/s2s/server/auth/dto/LoginResult.java`
- `src/main/java/com/s2s/server/auth/dto/SendCodeRequest.java`
- `src/main/java/com/s2s/server/auth/dto/SendCodeResult.java`
- `src/main/java/com/s2s/server/auth/dto/MyProfile.java`
- `src/main/java/com/s2s/server/auth/dto/UpdateProfileRequest.java`

**Acceptance:**
- DTO 字段与契约逐字对齐

### U4: 短信发码接口

**Files:**
- `src/main/java/com/s2s/server/auth/AuthController.java`（`sendSmsCode` 方法）
- `src/main/java/com/s2s/server/auth/SmsService.java`（`sendCode` 方法）

**Tests:**
- `src/test/java/com/s2s/server/auth/SmsServiceTest.java`

**Acceptance:**
- 返回 `expire_in=300`
- Redis 写入 `sms:{phone}` 键
- 限频生效（连续 6 次回 `42905`）

### U5: 短信登录接口

**Files:**
- `src/main/java/com/s2s/server/auth/AuthController.java`（`smsLogin` 方法）
- `src/main/java/com/s2s/server/auth/AuthService.java`（`loginBySms` 方法）

**Tests:**
- `src/test/java/com/s2s/server/auth/AuthServiceTest.java`

**Acceptance:**
- 正确验证码 → 返回 JWT + `is_new_user=false`
- 错误验证码 5 次 → `40105` + `Retry-After`
- 新手机号 → 自动注册 + `is_new_user=true`
- `agreed=false` → `40002`

### U6: Token 续期接口

**Files:**
- `src/main/java/com/s2s/server/auth/AuthController.java`（`refreshToken` 方法）
- `src/main/java/com/s2s/server/auth/AuthService.java`（`refresh` 方法）

**Tests:**
- `src/test/java/com/s2s/server/auth/AuthServiceTest.java`（续期用例）

**Acceptance:**
- 有效 Token → 返回新 JWT
- 过期 Token（签名合法）→ 返回新 JWT
- 无效 Token（签名非法）→ `40101`
- 黑名单 Token → `40101`

### U7: 登出接口

**Files:**
- `src/main/java/com/s2s/server/auth/AuthController.java`（`logout` 方法）
- `src/main/java/com/s2s/server/auth/AuthService.java`（`logout` 方法）

**Tests:**
- `src/test/java/com/s2s/server/auth/AuthServiceTest.java`（登出用例）

**Acceptance:**
- Token 加入 Redis 黑名单（`jwt:bl:{jti}`）
- `device.push_token` 清空
- 续期接口返回 `40101`

### U8: 本人资料接口

**Files:**
- `src/main/java/com/s2s/server/auth/UserController.java`
- `src/main/java/com/s2s/server/auth/UserService.java`

**Tests:**
- `src/test/java/com/s2s/server/auth/UserServiceTest.java`

**Acceptance:**
- `GET /users/me` 响应不含 `real_name_enc` / `id_card_hash`
- `PATCH /users/me` 昵称敏感词拦截生效
- `PATCH /users/me` 头像 `media_id` 未审核通过 → `40902`

### U9: cert 空壳

**Files:**
- `src/main/java/com/s2s/server/cert/CertService.java`

**Tests:**
- `src/test/java/com/s2s/server/cert/CertServiceTest.java`

**Acceptance:**
- `getRealnameStatus(userId)` 恒返回 `NONE`

### U10: 前端 auth 接线

**Files:**
- `lib/features/auth/auth_repository.dart`（改：删除内存 mock，改调真网络）
- `lib/features/auth/login_screen.dart`（改：消费真网络）
- `lib/core/storage/token_storage.dart`（新：Token 持久化）

**Tests:**
- `test/features/auth/auth_repository_test.dart`

**Acceptance:**
- 登录页可完成真实登录流程
- Token 持久化到本地，重启 APP 仍保持登录态
- 后门验证码 `kDebugMode` 包裹

### U11: 集成测试 + 契约示范测试

**Files:**
- `src/test/java/com/s2s/server/auth/AuthIntegrationTest.java`
- `test/contract/auth_contract_test.dart`（前端契约示范测试）

**Acceptance:**
- 后端集成测试扫描全部响应 JSON，不含 `real_name` / `id_card` 字样
- 前端契约示范测试 baseUrl 切真服务，断言一行不改
