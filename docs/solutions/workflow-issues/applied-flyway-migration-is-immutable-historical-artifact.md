---
title: 已应用的 Flyway 版本化迁移是不可变历史：与口径真源冲突只能新增版本处置，陈旧字面量留作历史快照
date: 2026-10-11
category: workflow-issues
module: docs
problem_type: convention
component: database
severity: high
root_cause: missing_workflow_step
resolution_type: workflow_improvement
applies_when:
  - 某口径/规格数值（如额度、阈值）发生变更，需要同步到各处口径真源
  - 该字面量同时出现在已被 Flyway 应用过的版本化迁移文件中（哪怕只在 SQL 注释里）
  - 迁移文件已在目标数据库执行，其 checksum 已记录于 flyway_schema_history
  - 需要判断「口径真源/不复制字面量纪律」与「迁移不可变」冲突时以何者为准
tags: [flyway, migration-immutability, checksum-validation, single-source-of-truth, schema-versioning, historical-snapshot, database-migration, convention]
---

# 已应用的 Flyway 版本化迁移是不可变历史：与口径真源冲突只能新增版本处置，陈旧字面量留作历史快照

## Context

DEC-30（2026-10-11）把「未实名详情额度」的产品口径从**每日 3 条**改成**每日 5 条**（`docs/decisions/决策登记表.md:44`：未实名每日 5 条详情，原 3 条）。这类改口径在本仓库有成熟做法——先把变更同步进全部口径真源，再让派生件跟上。本轮已同步 PRD §3.7/§3.8/§4.3/§9/§12.5、MRD UR-Grade-02、说明文档 §1.1 目标③、详设 §0.2/§3.4、《数据库设计文档》§7.5（`docs/database/数据库设计文档.md:946` 已写「每日放行 5 条、第 6 条回 `40301`」）与 openapi.yaml。

同步时出现一处「刺眼」的落点：字面量 `3` 还留在 `src/main/resources/db/migration/V1__init_schema.sql` 里，共两处，**都在 SQL 注释内**：

- `V1__init_schema.sql:135`：`-- 未实名详情浏览额度开关（PRD §12.3 每日 3 条 / 第 4 条回 40301）。`
- `V1__init_schema.sql:138`：`-- （每人每天只能看 3 条详情）。故服务端代码路径完整实现、由本开关控制，`

SQL **正文**本身没有写死任何 `3`：该行的种子是 `system_config.detail_quota_enabled = 'off'`（`V1__init_schema.sql:141`），额度数值从不落库、只由开关控制。

按「不复制字面量」的直觉，这两处注释「应该」被改成 `5`。**本轮的决定是：刻意不改**——不改 `V1__init_schema.sql`，也不改它的镜像副本 `docs/database/ddl/V1__init_schema.sql`（第 135、138 行）。原因：V1 早已在线上库执行过，任何一字节改动（哪怕只是注释里的一个数字）都会改变该文件的 Flyway 校验和，下一次启动时校验失败、应用起不来。这条注释因此被**当作历史快照保留**，实时口径以 PRD / DEC-30 为准。

需要区分的是：同一句废弃口径还出现在**Java 注释**里——`src/main/java/com/s2s/server/common/error/ErrorCode.java:31`（`未实名详情额度耗尽（每日 3 条）`）与 `src/main/java/com/s2s/server/post/PostQueryService.java:212`（`「每日 3 条、第 4 条 40301」的结论`）。这两处**没有**不可变约束，属于应当更新的对象；DEC-30 已为下一任务 [149] 留了待办：更新 `ErrorCode.java` 的该注释，并**新增一个额度上限常量**，使业务代码不再硬编码 `5`。可见「不改」是**按文件性质分类**的，不是一律不动。

## Guidance

### 一、已执行的版本化迁移文件是不可变历史，禁止就地编辑

Flyway 的版本化迁移语义（通用行为，非本仓库特有）：每个 `V<n>__*.sql` 在 `flyway_schema_history` 里登记一条记录，含该文件内容的**校验和**；启动迁移前默认会校验已应用迁移的文件是否与登记值一致，不一致即失败。因此一个已经跑过的迁移文件是**历史事实的快照**，不是设计文档的实时副本——**回改它等于篡改历史**，且代价不是「注释不对」而是「应用无法启动」。

本仓库的形态印证了这条路径是「应用内 Flyway 执行、且执行一次」：

- 业务库迁移目录 `classpath:db/migration`，由 `spring.flyway` 自动装配执行（`src/main/resources/application.yml:67-69`；`src/main/java/com/s2s/server/config/FlywayTrackConfig.java:20-22`）。
- 埋点库 `classpath:db/migration_track`，由 `FlywayTrackConfig#trackFlyway` 手动装配迁移（`FlywayTrackConfig.java:23-24`），对应文件 `src/main/resources/db/migration_track/V1__init_track_schema.sql`。
- V1 文件头自述执行方式已从容器 entrypoint 切到 Flyway datasource（`V1__init_schema.sql:13-16`）。
- V3 明写「Flyway 版本化迁移，只执行一次，故不写 `DROP` / 幂等保护」（`V3__seed_category.sql:28`）。

> 本仓库 `application.yml` 的 `spring.flyway` 块只声明了 `enabled: true` 与 `locations`（`:68-69`），**未**显式配置 `validate-on-migrate` / `clean-disabled` / `baseline`；全仓检索亦无这些键的业务配置命中。故上述校验行为按 **Flyway 的版本化迁移通用语义**陈述，不作「本仓库配置如此」的断言。真正的红线不依赖某个开关：**已应用迁移不就地改，是本项目在 DEC-30 由 DEC 记录确认的处置约定**。

### 二、口径变更的合法出口只有三个，不用「改老迁移」

| 变更对象 | 合法出口 | 本轮落点 |
| --- | --- | --- |
| 需要**改变库内数据/schema** | 新增一个**更高版本号**的迁移文件，不改已有文件 | 本仓库既有先例：V2 restart_window / V4 seed_template / V5 加列，均为增量新版本 |
| 变更的只是**一个可引用的数值/阈值** | 改它所属的**口径真源 + 常量真源**，业务代码只引用常量名 | 改 PRD §12.5 / 详设 / 数据库设计 §7.5；Java 侧在 `src/main/java/com/s2s/server/common/constants/`（`NfrPost`、`NfrPerf` 等同级类）补额度常量 |
| 变更落在**已冻结的历史文件**里（如已应用迁移的注释） | 不改文件；把新口径写进权威源，并在该处标注「本注释是历史快照，现行口径见 XX」 | 本轮不改 `V1__init_schema.sql:135,138`，口径以 PRD / DEC-30 为准 |

「新增迁移版本」在本仓库是被明文写下的既定流程——`V3__seed_category.sql:23` 直接引 `说明文档 §2.8.1「变更走新 Flyway 版本」`，并解释为什么不放手工脚本：迁移保证「重建库即可复现同样结果」，避免每台机器手工操作漂移。

### 三、区分「历史快照」与「可编辑副本」

不是所有写着 `copy` 的文件都不可改，判据是**它是否已被 Flyway 应用**：

- **`docs/database/ddl/V1__init_schema.sql`** 是 `src/main/resources/db/migration/V1__init_schema.sql` 的文档侧镜像（两份 `:135,:138` 同文）。它本身不被 Flyway 执行，但**保持逐字一致**才有意义；既然正本不可改，镜像也不改——否则镜像与真源分叉，反而制造新的口径源。
- **`编码规范.md` 附录里标注「同源副本」的表格**（`docs/architecture/编码规范.md:298`：`本表是同源副本——改动须两处同改`）属另一类：它要求**两处一起改**，因为两处都可编辑。这与迁移不可改是相反的处理。
- **Java 注释**（`ErrorCode.java:31`、`PostQueryService.java:212`）不在 Flyway 管辖内，属于应更新的对象——正是 [149] 待办的内容。

一句话：**「不可改」由「是否已被 Flyway 应用」决定，不由「是否是副本 / 是否含旧数字」决定。**

## Why This Matters

- **改注释 = 改校验和 = 应用启动失败。** 这是最反直觉的一点：直觉里「注释不影响运行」，但在版本化迁移里注释**属于文件内容**，同样进校验和。一个看似无害的「把 3 改成 5」，代价是从「文案不齐」升级为「服务起不来」。这类故障还很难往注释上想。
- **历史文件的本分是记录「当时是什么」，不是「现在是什么」。** 把 V1 的注释改成 `5` 会造成双重误导：既篡改了「V1 落地那一刻口径是 3 条」的事实，又让后人对「这条注释为何是 5」失去溯源头。保留 `3` 并指向 PRD / DEC-30，反而让口径的演变可追溯。
- **「不复制字面量」红线管的是业务代码引用，不管历史快照。** `docs/architecture/编码规范.md:24` 要求阈值只引常量名、禁写死数字——指向的是**会参与运行**的代码。已经冻结的迁移注释不产生运行时行为，强行套用这条规则反而触发上面第一条事故。
- **同一句废弃口径散落在不同性质的文件里，处置必须分流。** 本轮同时暴露了「迁移注释（不可改）」与「Java 注释（应改）」两类。一刀切地「全改成 5」会改坏迁移；一刀切地「一律不改」会漏掉 `ErrorCode.java:31` 与 `PostQueryService.java:212` 这两处本该更新的陈旧注释。分类是第一位的动作。

## When to Apply

命中以下任一触发条件时套用本文：

- 口径变更（阈值、额度、上限、TTL、批次）会落到一个**已被 Flyway 应用**的迁移文件里——无论落点是注释、种子数据还是 DDL。
- 仓库存在「迁移文件 + 文档侧镜像」（如 `src/main/resources/db/migration/V1__*.sql` 与 `docs/database/ddl/V1__*.sql`），需决定镜像是否跟着改。
- 需要判断某处含旧数字的文本**该改还是该留**：先问「这个文件被 Flyway 应用过吗？」应用过 → 留 + 标注；没应用过且是业务代码 → 改口径源 / 常量。
- 打算「顺手」清理一条过时注释时——先确认该注释不在任何已应用迁移文件内。
- 迁移需要真正改变库内数据/schema 时——一律走**新增更高版本号**的迁移文件。

## Examples

**反例（本轮明确拒绝的动作）**

```
✗ 打开 src/main/resources/db/migration/V1__init_schema.sql
✗ 把 :135 的「每日 3 条」改成「每日 5 条」
✗ 把 :138 的「只能看 3 条详情」改成「只能看 5 条详情」
→ 文件校验和改变 → 下次启动 Flyway 校验失败 → 应用无法启动
→ 同时篡改了「V1 落地时口径 = 3 条」的历史事实
```

**正例（本轮的处置）**

```
✓ 已应用迁移（V1__init_schema.sql:135,138）不改：保留其「历史快照」身份
✓ 其文档侧镜像 docs/database/ddl/V1__init_schema.sql 同步保持逐字一致，不改
✓ 新口径写进全部口径真源：
    PRD §3.7/§3.8/§4.3/§9/§12.5、MRD UR-Grade-02、说明文档 §1.1 目标③、
    详设 §0.2/§3.4、数据库设计 §7.5（:946 已写「每日放行 5 条」）、openapi.yaml
✓ 可编辑的陈旧注释按 [149] 待办更新：
    ErrorCode.java:31 的「每日 3 条」注释 + 新增额度上限常量（使业务代码不硬编码 5）

未来若需真正改库内值：新增 V<n+1>__.sql，绝不回改 V1
```

**「新增版本」而非「改老版本」的最小示意（本仓库命名惯例）**

```sql
-- 新增：src/main/resources/db/migration/V6__xxx.sql（版本号递增、只执行一次）
-- 老文件 V1..V5 一律不动；重建库时 V1→V6 顺序重放即可复现（V3__seed_category.sql:23 的口径）
```

**判定脚本（判断某文件是否可改）**

```
问：这个文件被 Flyway 应用过吗？
  在 db/migration 或 db/migration_track 下、已随某次发布上线 → 不可改（留历史快照 + 标注）
  在 docs/ 下、只是文档/镜像、从不被执行           → 随其真源，保持逐字一致
  是 Java/Dart 业务代码或注释                        → 可改；数值走 common/constants 常量
```

## Related

- 决策原文：`docs/decisions/决策登记表.md:44`（DEC-30 行：未实名每日 5 条，原 3 条）与 `:97`（[149] 待办正文：更新 `ErrorCode.java` 的 `DETAIL_QUOTA_USED` 注释 + 新增限额常量）。
- 迁移「变更走新版本」的既有明文：`src/main/resources/db/migration/V3__seed_category.sql:23`（引 `说明文档 §2.8.1「变更走新 Flyway 版本」`）与 `:28`（版本化迁移只执行一次）。
- Flyway 在本仓库的装配形态：`src/main/resources/application.yml:67-69`（业务库）、`src/main/java/com/s2s/server/config/FlywayTrackConfig.java:20-24`（双库 + 埋点库目录 `db/migration_track`）。
- 口径/常量真源纪律：`docs/architecture/编码规范.md:24`（不复制字面量，Java 在 `common` 建同名常量类）与 `:298`（「同源副本——改动须两处同改」）。
- 常量真源落点：`src/main/java/com/s2s/server/common/constants/`（`NfrPost`、`NfrPerf`、`NfrTask` 等同类），[149] 的额度常量应落在此处同级。
- 姊妹篇（口径传导核验）：`docs/solutions/workflow-issues/multi-format-deliverable-consistency.md`（权威源→派生件传导）与 `docs/solutions/workflow-issues/cross-document-reference-verification.md`（权威源内部跨章节引用核验）。本文管的是第三类：**权威源与「不可变历史文件」冲突时，改哪一处、留哪一处**。
- 相邻主题：`docs/solutions/workflow-issues/phase-boundary-verification-scaffolding.md`——同以「Flyway 迁移 / 命名即零成本兼容」为背景，讨论的是阶段边界；本文讨论的是**已冻结产物的不可变性**。
