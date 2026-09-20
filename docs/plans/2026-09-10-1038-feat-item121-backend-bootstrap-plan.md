---
title: "[121] 后端工程初始化 + common 三组件实施计划"
type: feat
date: 2026-09-10
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# [121] 后端工程初始化 + common 三组件实施计划

## Goal Capsule

在工作树 `s2s-wt-backend`（分支 `item/121-backend-init`）落地找鸭找后端工程底座：Maven（Java 21 / Spring Boot 3 / 显式版本）+ `com.s2s.server` 九域包骨架 + common 三组件（`ApiResponse`/`ResponseBodyWrapper`/`GlobalExceptionHandler`）+ `ErrorCode` 25 枚举 + Flyway 接入两份 V1 DDL 与 `restart_window` 补 DDL（缺口 #1 前半）+ 配置全 `${VAR:?}` 占位且缺变量启动快速失败 + 聚合性能客户端 POC 书面结论（缺口 #2 输入）。本条目是 Sprint S1 出口闸门之一，后续全部后端条目依赖此底座。

## Product Contract

### Summary

条目 [121] 是后端编码线的起点。工程根 = 仓库根（`deploy/Dockerfile:29-34` 写死 `COPY pom.xml .` + `COPY src ./src`，**不是** `server/` 子目录）。common 三组件必须先于第一个业务接口落地（编码规范 §4.1：先写业务后补必返工）。依据源文档在主仓为未入库状态，经用户裁定采用「跨仓读主仓」：实施时从主仓绝对路径读取，DDL 以**复制**方式进入本工程并提交。

### Problem Frame

- 后端工程尚未初始化，Sprint S1（9/9–9/11）的 [124]–[131] 全部后端条目都建立在 [121] 的底座之上，底座偏差会放大为全线返工。
- 研究发现 10 项矛盾/缺口必须在实施前或实施中处置（见 Key Decisions 与 Open Questions），其中 3 项是阻塞性前置决策（KTD-4/KTD-5/KTD-6）。
- 聚合性能 POC 是缺口 #2 的唯一校准输入，其结论直接决定 `clusterModeSwitchMetersPerPixel` 常量终值（[126] 依赖）。

### Requirements

| R-ID | 需求 | 来源 |
| --- | --- | --- |
| R-1 | Maven 工程初始化：Java 21、Spring Boot 3、依赖显式版本（禁 `LATEST`/`RELEASE`/版本范围），版本由 `spring-boot-starter-parent` 托管 | 说明文档 §2.8.4 [121]；技术栈 §3 |
| R-2 | `com.s2s.server` 包骨架：common 七子包（`web/error/idempotency/ratelimit/crypto/geo/audit`）+ 九域（`auth/category/post/map/contact/notify/cert/ai/track`，map/track 无 entity，cert/ai Batch1 空包）+ `task/` | 详设 §1.2 |
| R-3 | common 三组件：`ApiResponse<T>(code,message,data,requestId)` record、`ResponseBodyWrapper`（唯一响应套壳与 `request_id` 注入处）、`GlobalExceptionHandler`（唯一异常→错误码映射处，唯一写 `Retry-After` 头位置） | 详设 §2.1/§2.2；编码规范 §1.2 |
| R-4 | `ErrorCode(code, httpStatus, message, needRetryAfter)` 25 枚举：`0`；`40001/40002`；`40101/40105`；`40301–40305`；`40901–40903`；`41001`；`42901–42907`；`50001`；`50301–50303`；8 个 `needRetryAfter=true` = `40105` + `42901–42907`；`code/100==httpStatus`（`OK(0,200)` 豁免） | 详设 §2.3；PRD §12.5；编码规范 §3.2 |
| R-5 | Flyway 接入两份 V1 DDL（业务库 `s2s` 15 表 + 埋点库 `s2s_track`，track 副本**剔除** `CREATE DATABASE/USE/GRANT` 三句 initdb 专用语句），双迁移目录 `classpath:db/migration` + `db/migration_track` 双 datasource；`restart_window` 走新 V2（业务库，start_at/end_at 两列） | 数据库设计文档；详设 §21 #1 |
| R-6 | jar 内 `application-*.yml` 只允许 `${VAR:?}` 占位（变量名取 Spring relaxed-binding 标准名，如 `SPRING_DATASOURCE_URL`，命名契约见 KTD-11），缺变量启动快速失败；`.env.example` 变量名与 yml `${}` 名逐一对应；六类凭证不入仓库不入镜像 | 编码规范 §3.3；安全 §4/§10 |
| R-7 | 聚合性能客户端 POC：POC-A 复跑（5 万点基准）+ POC-B 绘制 CPU 基准 + 书面结论，产出供 [126] 校准 `clusterModeSwitchMetersPerPixel`（暂填 30） | 说明文档 [120] 定案；详设 §21 #2；PRD §12.3 |
| R-8 | 文档回写：详设 §2.3「枚举总数 23」→ 25 与 §1.2「24 个错误码枚举」→ 25；说明文档 §2.8.1 数据基线行失实修正；说明文档 §2.7 POC 处置口径按 KTD-6/PRD:2652 回写（含 §2.8.4 行与进度记录同句）；initdb.d 口径变更说明（HTD-4）；说明文档进度记录更新 | 条目验收点；用户规则 §1.3 |

### Key Decisions

| KTD-ID | 决策 | 依据 | Governs |
| --- | --- | --- | --- |
| KTD-1 | 工程根 = 仓库根目录（`pom.xml`、`src/` 直接落根），**不建 `server/` 子目录** | `deploy/Dockerfile:29-34` 与部署架构设计文档 §2.2 写死；学习沉淀 #4 的 `server/` 表述据此修正 | R-1, R-2 |
| KTD-2 | 持久层用 MyBatis-Plus 3.5.x，**不用 JPA**；`deploy/config/app/application-{dev,staging,prod}.yml` 中的 `spring.jpa/hibernate` 残留一并改写为 MyBatis-Plus 口径 | 详设/技术栈 session-settled（R10）；研究发现 #2 | R-1, R-6 |
| KTD-3 | Java 21 不开虚拟线程（退出条件：Java 24 或压测证明 I/O 阻塞） | 编码规范 §4.1 session-settled | R-1 |
| KTD-4 | **前置决策**：compose `initdb.d` 改写为 `.sh` 脚本（MySQL initdb 的 .sql 不支持变量）：按 `$MYSQL_TRACK_DATABASE`/`$MYSQL_USER` 幂等执行 `CREATE DATABASE IF NOT EXISTS` + `GRANT`，**只建库授权、不建表**；表结构一律由 Flyway 管理，消除「双 schema 管理者」冲突 | 「Flyway 管 schema」定案（编码规范 §4.9）与现状冲突，研究发现 #3；D2 裁定 | R-5 |
| KTD-5 | **前置决策**：两份 V1 DDL 以**复制**（非移动）方式进入 `src/main/resources/db/migration{,_track}/` 并随工程提交；track 副本剔除 `CREATE DATABASE/USE/GRANT` 三句（initdb 专用，应用账号无权限，D1 裁定）；主仓 `docs/database/ddl/` 仅存档 V1 快照，**演进真源为 migration 目录**；复制时记录源文件 SHA-256，验证步比对防主仓漂移（D9 裁定） | 用户裁定「跨仓读主仓」；学习沉淀：DDL 交接是复制非重写 | R-5 |
| KTD-6 | **前置决策**：POC 不通过的处置以 PRD:2652 为准——不得下调目标、不改写 SLA、不下调 Pin 上限；说明文档 §2.7 中「POC 不通过则渲染上限下调、SLA 改写」行须回写对齐 | PRD 优先级高于管理文档，研究发现 #8 | R-7 |
| KTD-7 | 双 datasource Flyway：`spring.flyway` 默认管业务库 `s2s`；`s2s_track` 用手动 `Flyway` Bean（独立 DataSource + `db/migration_track`），启动顺序先于应用就绪 | 详设双库定案；学习沉淀排序风险 | R-5 |

### Success Criteria

1. `mvn test` 全绿，`ErrorCodeTest` 断言四项全过：总数 25、无重复、`code/100==httpStatus`（`OK(0)` 豁免）、8 个 Retry-After 码 `needRetryAfter=true`。
2. 缺任一必需环境变量时应用启动快速失败（负向实测留证，命令与输出记入说明文档进度记录）。
3. Flyway 迁移在空库上一次通过（业务库 15 表 + 埋点库 2 表 + `restart_window`）。
4. POC 书面结论落盘（含 POC-A 复跑数据、POC-B 绘制基准、阈值建议与边界声明），并回写 `nfr_constants.dart` 注释或保持暂填值的明确依据。
5. 文档回写全部完成（R-8 全清单，含详设 §2.3 与说明文档各回写点）。

### Scope Boundaries

**In scope**：工程骨架、common 三组件、ErrorCode、Flyway 迁移、配置外部化与快速失败、deploy yml JPA 残留清理、initdb.d 口径修正、客户端聚合 POC、文档回写（R-8 全清单）。

**Out of scope**：任何业务接口（auth/post/map 等域的实现）、`IdempotencyInterceptor`/`RateLimiter`/`CryptoFacade` 等 common 其余组件（[124]+）、`AuditLogWriter`、定时任务、seed-perf.sql（[130] 前置，仅登记缺口）、短信通道凭证（登记供 [123]）、真机 POC-B（当前无真机，见 OQ-4）。

### Open Questions

| OQ-ID | 问题 | 处置 |
| --- | --- | --- |
| OQ-1 | Spring Boot / Flyway 具体小版本未钉 | 实施期裁量，选定后在 pom 显式钉版并记录理由 |
| OQ-2 | `seed-perf.sql` 规格有、文件无 | 登记缺口，[130] 前必须补齐，本条目不造 |
| OQ-3 | 短信通道凭证无环境变量定义 | 登记缺口供 [123]，本条目 `.env.example` 不加 |
| OQ-4 | POC-B 真机 P95 需安卓真机，本条目仅可得开发机 CPU 数据 | 书面结论标注边界：开发机 CPU 数据 + 分析性外推（非真机 P95，不得据此宣布达标），真机 P95 留给 [126] 校准窗口 |

### 研究发现 → KTD/OQ 映射表

| # | 研究发现 | 处置落点 |
| --- | --- | --- |
| 1 | 工程落点争议（`server/` 子目录表述 vs Dockerfile 写死仓库根） | KTD-1 |
| 2 | deploy 三份 yml 残留 `spring.jpa/hibernate`，与 MyBatis-Plus 定案冲突 | KTD-2 |
| 3 | compose `initdb.d` 自动执行 DDL，与「Flyway 管 schema」双 schema 管理者冲突 | KTD-4 |
| 4 | track 库 V1 DDL 含 `CREATE DATABASE/USE/GRANT`，原样入 Flyway 必失败 | KTD-5（剔除三句）/ R-5 |
| 5 | 依据源文档与 DDL 在主仓未入库，worktree 内不可见 | KTD-5（复制 + SHA-256 防漂移）|
| 6 | 双库双 Flyway 启动顺序错配风险（track 迁移跑到业务库即污染） | KTD-7 / HTD-1 |
| 7 | `${VAR:?}` 与 deploy 外部化 yml 叠加时快速失败行为未验证 | HTD-2 / U-5 负向实测 |
| 8 | 说明文档 §2.7 POC 处置口径与 PRD:2652 冲突 | KTD-6 / R-8 回写 |
| 9 | POC-B 真机不可得，只有开发机 CPU 数据 | OQ-4 / HTD-3 |
| 10 | Spring Boot/Flyway 小版本未钉；`seed-perf.sql` 缺失；短信凭证未定义 | OQ-1 / OQ-2 / OQ-3 |

### Sources

- 条目定义：主仓 `说明文档.md` §2.8.4（行 269）、§2.7、§2.8.1
- 设计依据：主仓 `docs/design/后端详细设计文档.md` §1.2/§2.1/§2.2/§2.3/§21；`docs/api/openapi.yaml` §2–§3；`docs/database/ddl/V1__init_schema.sql`、`V1__init_track_schema.sql`；`docs/architecture/技术栈选型说明.md` §3/§5/§6；`docs/architecture/系统安全设计方案.md` §4/§10；`docs/architecture/完成定义DoD.md`
- 常量真源：主仓 `lib/nfr_constants.dart`（7 常量类，Java 镜像抄录源）
- POC 资产：主仓 `tool/poc_a_cluster_benchmark.dart`、`tool/poc_b_paint_benchmark.dart`、`lib/features/discovery/stress_data.dart`
- 部署现状：`deploy/Dockerfile:29-34`、`deploy/env/.env.dev.example`（23 变量）、`deploy/config/app/application-*.yml`、compose initdb.d 挂载
- 学习沉淀：10 条相关 learnings（凭证注入边界、DDL 复制非重写、负向实测、门禁退出码消费方等）

## Planning Contract

### Key Technical Decisions

继承 Product Contract 的 KTD-1–KTD-7。补充实施期技术口径：

- **KTD-8**：本条目不建 common 常量镜像类——常量类随首个使用它的条目落地（如 `NfrApi` 随幂等组件 [124]）；本条目涉及的值（`restart_window` 列名等）以 DDL 为准，不构成 NFR 阈值，无字面量复制风险。（D4 裁定收口）
- **KTD-9**：包骨架用 `package-info.java` 占位（带域职责注释），不用 `.gitkeep`——Java 工程惯例且让 `flutter analyze` 类静态检查无感。
- **KTD-10**：`GlobalExceptionHandler` 本条目只映射 `BizException→取其 ErrorCode` 与兜底 `→50001`（日志打全栈、响应体无堆栈）；Bean Validation/缺头 `40001`、乐观锁 `40903` 的具体分支随业务条目补，但骨架须留扩展点。
- **KTD-11**：配置命名契约（D3 裁定）——jar 内 yml 占位变量取 Spring relaxed-binding 标准名（`SPRING_DATASOURCE_URL`/`SPRING_DATASOURCE_PASSWORD`/`SPRING_DATA_REDIS_PASSWORD` 等）与自定义语义名（`TRACK_DATASOURCE_URL`、`HMAC_PEPPERS_JSON`、`AEAD_MASTER_KEYS_JSON`、OSS/高德 Key）；compose `environment` 直注同名变量；仓库根 `.env.example` 与 jar 内 `${}` 名逐一对应；deploy 三份环境模板只清理 JPA 残留，不纳入占位核对（D6 裁定）。
- **KTD-12**：主仓文档回写（R-8）在主仓单独提交，**不纳入** `item/121-backend-init` 分支（D5 裁定）——本分支只含后端工程与 deploy 侧改动，保持泳道边界清晰。

### High-Risk / High-Uncertainty Areas

| HTD-ID | 风险点 | 处置 |
| --- | --- | --- |
| HTD-1 | 双 datasource Flyway 启动顺序与迁移目录错配（track 迁移跑到业务库即污染） | U-4 单测/集成实测：空库迁移后逐库核对表清单；流程图见下 |
| HTD-2 | `${VAR:?}` 快速失败在 jar 内 yml 与 deploy 外部化 yml 叠加时的实际行为（外部化 yml 若裸插值会先于占位校验失败还是静默 null） | U-5 负向实测必须覆盖「缺 DB 密码」「缺 pepper JSON」两类，输出留证 |
| HTD-3 | POC-B 开发机测试绑定 CPU 数据不代表真机 P95 | 结论只给阈值建议区间与边界声明（OQ-4），不宣布达标 |
| HTD-4 | initdb.d 改写影响开发环境既有数据 | dev 库数据可弃（D7 裁定）：`docker compose down -v` 重建，由新 initdb.sh 建库授权 + Flyway 建表全新构建；在说明文档进度记录留迁移说明 |

双数据源 Flyway 与启动失败路径：

```mermaid
flowchart TD
    A[应用启动] --> B{环境变量齐?<br/>所有 ${VAR:?} 可解析}
    B -- 否 --> C[启动快速失败<br/>BeanCreationException 留证]
    B -- 是 --> D[业务库 DataSource s2s]
    B -- 是 --> E[埋点库 DataSource s2s_track]
    D --> F[spring.flyway 默认迁移<br/>classpath:db/migration<br/>V1__init_schema + V2__restart_window]
    E --> G[手动 Flyway Bean 迁移<br/>db/migration_track<br/>V1__init_track_schema]
    F --> H[应用就绪]
    G --> H
```

## Implementation Units

### U-1：Maven 工程骨架（仓库根）

- **Files**：`pom.xml`、`src/main/java/com/s2s/server/S2sServerApplication.java`、`.gitignore`（target/、*.class 等）、`src/main/resources/`（空目录占位）
- **Approach**：`spring-boot-starter-parent` 托管版本；依赖最小集：`spring-boot-starter-web`、`spring-boot-starter-validation`、`spring-boot-starter-test`（test）、`mybatis-plus-spring-boot3-starter`（显式版本）、`mysql-connector-j`、`spring-boot-starter-data-redis`、`flyway-core`、`flyway-mysql`、`spring-boot-starter-actuator`（compose healthcheck 与 caddy `depends_on: service_healthy` 依赖 `/actuator/health`，jar 内默认仅暴露 health 端点）；`maven-compiler-plugin` release 21；不开虚拟线程（KTD-3）；Java 21 + Spring Boot 3 小版本选定后钉死（OQ-1）
- **Test scenarios**：`mvn -q compile` 通过；`mvn test` 可运行（空测试套）
- **Verification**：`mvn -v` 显示 Java 21；`mvn test` 退出码 0；`grep -E 'LATEST|RELEASE' pom.xml` 零命中

### U-2：九域包骨架

- **Files**：`src/main/java/com/s2s/server/{common/{web,error,idempotency,ratelimit,crypto,geo,audit},auth,category,post,map,contact,notify,cert,ai,track,task}/package-info.java`
- **Approach**：每个包一个 `package-info.java`，注释写明域职责与出处章节（如 `// 详设 §1.2：map/track 无 entity`）；cert/ai 注释标注「Batch1 空包」；KTD-9
- **Test scenarios**：编译通过；包结构与详设 §1.2 逐字比对
- **Verification**：目录清单与详设 §1.2 对照无差；`mvn compile` 通过

### U-3：common 三组件 + ErrorCode 25

- **Files**：`common/web/ApiResponse.java`、`common/web/ResponseBodyWrapper.java`、`common/web/GlobalExceptionHandler.java`（详设 §1.2 归属 web 子包）、`common/error/ErrorCode.java`、`common/error/BizException.java`；测试：`src/test/java/com/s2s/server/common/error/ErrorCodeTest.java`、`common/web/ResponseBodyWrapperTest.java`、`common/web/GlobalExceptionHandlerTest.java`
- **Approach**：
  - `ApiResponse` 逐字落地详设 §2.1：`public record ApiResponse<T>(int code, String message, T data, String requestId)`，Jackson snake_case 命名策略
  - `ErrorCode` 25 枚举逐字落地 R-4 清单；每枚举注释带 PRD §12.5 语义；`code/100==httpStatus`（`OK(0,200)` 豁免）由单测保证
  - `ResponseBodyWrapper` 实现 `ResponseBodyAdvice`：统一套壳并注入 `request_id`（从 `RequestIdFilter` 上下文取；本条目 `request_id` 生成可用最小实现，`RequestIdFilter` 正式落地在 [124]，此处注释标注）
  - `GlobalExceptionHandler` 按 KTD-10：BizException→取其 ErrorCode（`needRetryAfter=true` 时写整数秒 `Retry-After` 头），兜底→`50001`（日志全栈、响应无堆栈）
  - 所有函数带函数级注释（功能/参数/返回值），注释带章节号（编码规范 §2.2）
- **Test scenarios**：ErrorCodeTest 四断言（25/无重复/code÷100==httpStatus（OK(0) 除外）/8 个 Retry-After 码且逐一点名）；Wrapper 对 String 返回值与 record 返回值的套壳单测；Handler 对 BizException(42901) 写出 `Retry-After`、对未知异常返 50001 且无堆栈
- **Verification**：`mvn test` 全绿；静态扫描 `grep -rn "ApiResponse.ok" src/main` 零命中（唯一套壳处纪律）

### U-4：Flyway 双库迁移 + V2 restart_window

- **Files**：`src/main/resources/db/migration/V1__init_schema.sql`（复制自主仓）、`src/main/resources/db/migration/V2__restart_window.sql`（新建）、`src/main/resources/db/migration_track/V1__init_track_schema.sql`（复制并剔除 `CREATE DATABASE/USE/GRANT` 三句，D1 裁定）、`config/FlywayTrackConfig.java`（手动 Flyway Bean）、`deploy` 侧 compose/initdb.d 改写为 `.sh`（KTD-4，D2 裁定）
- **Approach**：KTD-5 复制 DDL 并记录源文件 SHA-256（写入迁移说明，验证步比对防主仓漂移，D9 裁定）；V2 新建 `restart_window`（业务库，start_at/end_at，按缺口 #1 前半）；双 datasource 按 KTD-7，迁移用应用账号（非 root、无 CREATE DATABASE 权限——建库授权已由 initdb.sh 完成）
- **Test scenarios**：`docker compose down -v` 重建 dev 卷（HTD-4/D7），空库（两个全新 schema）启动一次迁移通过；逐库核对表清单（s2s 15+1 张含 restart_window，s2s_track 2 张）；重复启动幂等（Flyway checksum 不报错）
- **Verification**：迁移日志留证；`SHOW TABLES` 双库核对输出记入说明文档进度记录；DDL 副本与主仓源文件 SHA-256 比对留证（track 副本扣除剔除行后比对）

### U-5：配置外部化与启动快速失败

- **Files**：`src/main/resources/application.yml`、`application-dev.yml`（如需）、`common/config/SecretsProperties.java`（@ConfigurationProperties 启动强制绑定）、`deploy/config/app/application-{dev,staging,prod}.yml`（JPA 残留清理，KTD-2）、仓库根 `.env.example`（与 jar 内 `${}` 名逐一对应，KTD-11）
- **Approach**：jar 内 yml 全部 `${VAR:?}` 占位，变量名按 KTD-11 命名契约；新增最小 `@ConfigurationProperties`（SecretsProperties）启动强制绑定六类凭证（DB 密码、Redis 密码、HMAC pepper 列表、AEAD 主密钥列表、OSS AK/SK、短信/高德 Key），缺失即启动快速失败，零硬编码；yml 固定 `server.error.include-stacktrace: never`（响应体无堆栈双保险）；`.env.example` 与 yml `${}` 名逐一对应（缺一即缺陷）；禁 `app.crypto.*` 带点号键名
- **Test scenarios**：负向实测两类缺失（缺 `SPRING_DATASOURCE_PASSWORD`、缺 `HMAC_PEPPERS_JSON`）启动失败且报错可定位变量名；compose 叠加路径同测（`docker compose up` 缺变量，app 容器启动失败，D8 裁定）；`/error` 触发 500 响应体无堆栈负向断言；补齐后启动成功
- **Verification**：负向实测命令+输出留证；`grep -rnohE '\$\{[A-Z_]+(:\?)?\}' src/main/resources` 与 `.env.example` 双向核对零差异（核对范围仅 jar 内 yml，deploy 三份模板由 KTD-11 命名契约接管，不纳入——D6 裁定）

### U-6：聚合性能客户端 POC

- **Files**：POC 运行（不新增代码）：`tool/poc_a_cluster_benchmark.dart`、`tool/poc_b_paint_benchmark.dart`；产出：`docs/poc/2026-09-10-cluster-poc-conclusion.md`（主仓登记）；视结论回写 `lib/nfr_constants.dart` 的 `clusterModeSwitchMetersPerPixel` 注释
- **Approach**：POC-A 复跑（5 万点，验证 4.73ms 基线可复现）；POC-B 绘制 CPU 基准在开发机以 `flutter test tool/poc_b_paint_benchmark.dart` 运行（测试绑定，只测 build/layout/paint 的 CPU 部分，不需设备/模拟器）并记录数据；书面结论含：数据、阈值建议区间、边界声明（OQ-4/KTD-6）、供 [126] 的校准建议
- **Test scenarios**：两次 POC 运行日志留档；结论文档含「不以模拟器数据宣布达标」声明
- **Verification**：结论文件存在且经自检覆盖 PRD §12.3 校准三要素；说明文档进度记录更新

### U-7：文档回写

- **Files**：主仓 `docs/design/后端详细设计文档.md` §2.3（「枚举总数 23」→25）与 §1.2（「24 个错误码枚举」→25）、主仓 `说明文档.md`（§2.8.1 数据基线行修正 + §2.7 POC 处置口径按 KTD-6/PRD:2652 回写（含 §2.8.4 行）+ 进度记录 [121] 完成标记 + initdb.d 口径变更说明）
- **Approach**：回写只动失实行与进度记录，不重写设计内容；每处回写注明本计划出处；回写在主仓单独提交，不进 `item/121-backend-init` 分支（KTD-12）
- **Test scenarios**：回写后与代码事实一致（ErrorCode 实际枚举数 == 文档数）
- **Verification**：`ErrorCode.values().length == 25` 与详设文字一致；说明文档进度勾选

## Verification Contract

| 闸门 | 命令/动作 | 通过标准 |
| --- | --- | --- |
| 编译 | `mvn -q compile` | 退出码 0，Java 21 |
| 单测 | `mvn test` | 全绿；ErrorCodeTest 四断言过（OK(0) 豁免 code/100） |
| 版本纪律 | `grep -E 'LATEST|RELEASE' pom.xml` | 零命中 |
| 唯一套壳 | `grep -rn "ApiResponse.ok" src/main` | 零命中 |
| 配置对应 | jar 内 `${VAR}` 集合 vs `.env.example` 双向核对 | 零差异 |
| 快速失败 | 缺 `SPRING_DATASOURCE_PASSWORD` / 缺 `HMAC_PEPPERS_JSON` 各启动一次（含 compose 叠加路径） | 均快速失败且报错含变量名；`/error` 响应体无堆栈；输出留证 |
| Flyway | 空库启动迁移 | 双库表清单正确（15+1 / 2），重复启动幂等；DDL 副本 SHA-256 比对一致 |
| POC | POC-A/POC-B 运行 + 结论文档 | 日志留档，结论含边界声明 |
| 回写 | 详设 §2.3 数字与代码一致 | 25 == 25 |
| 静态 | `flutter analyze` + `flutter test`（POC 触前端文件时） | analyze 0 issue；测试全绿，基线 303 项只增不减 |

## Definition of Done

对照 `docs/architecture/完成定义DoD.md` 通用 D1–D11，本条目逐项适用结论：

- D1（代码实现）：U-1–U-5 代码全落地，三全局硬纪律零违反（不复制字面量/不新增错误码/不凭位置信重试——本条目无重试代码，天然满足第三条）
- D2（测试）：U-3 单测四断言 + Wrapper/Handler 单测全绿；U-4/U-5 实测留证
- D3（文档）：U-7 回写全清单完成 + 说明文档进度记录
- D4（配置/密钥）：六类凭证零入库；`.env.example` 与 yml 一一对应
- D5（可观测）：`GlobalExceptionHandler` 兜底日志打全栈、响应体无堆栈（日志 JSON 8 字段的完整落地属 [124] `RequestIdFilter`，本条目注释标注衔接点）
- D6（安全）：响应体无堆栈；凭证零硬编码
- D7（性能）：POC 书面结论产出（R-7）
- D8（兼容性）：不适用于本条目（无对外接口）
- D9（数据迁移）：Flyway 空库一次通过 + 幂等（U-4）
- D10（分支纪律）：`item/121-backend-init` 分支内提交，Conventional Commits，验收后 `--no-ff` 并回
- D11（进度同步）：说明文档 [121] 标记完成并补充结果说明

条目验收点逐项：① ErrorCode 25/无重复/`code/100==httpStatus`（OK(0) 豁免）/8 个 Retry-After 码 ✅（U-3）；② 缺变量启动失败实测 ✅（U-5）；③ 详设 §2.3 回写 25 ✅（U-7）；④ 聚合 POC 书面结论 ✅（U-6）。
