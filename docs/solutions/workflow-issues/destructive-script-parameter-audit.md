---
title: 破坏性脚本的传参审计：参数就是写入授权
date: 2026-09-06
last_updated: 2026-09-09
category: workflow-issues
module: docs
problem_type: workflow_issue
component: database
severity: high
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 调用一个别人写的（或自己很久以前写的）会连库执行 SQL 的脚本
  - 脚本签名里含库名、表名、路径、目标环境这类"写到哪里"的参数
  - 手头同时存在压测库、测算库、演示库等含真实数据的同名族库
  - 环境探测失败后换了一条新路径重试，即将在新环境里首次执行既有脚本
tags: [destructive-operation, script-parameter, data-safety, mysql, test-fixture, verification-gate, docker, wsl]
---

# 破坏性脚本的传参审计：参数就是写入授权

## Context

补跑埋点去重约束的行为断言时，脚本签名是：

```bash
bash docs/database/scripts/assert_behavior.sh <容器名> <业务库名> <埋点库名>
```

三个参数我尽调了两个：容器名先探测过、埋点库名还特意避开了当时实例里那个旧版 DDL 的库（它没有本轮要验的唯一索引——指当时的实例状态，仓库 DDL 已含该索引）。第二个参数——业务库——我看着像是本项目的库名就交上去了，传的是含 50 万行压测数据的既有库。

脚本前 5 项断言随即往里写入：3 条 `post`（表内行数 500000 → 500003）、2 个 `user`、1 条 `user_identity`、1 条 `favorite`，并对 `post.id=1` 做了两次定点改写 —— 先是一条**无任何守卫**的 `UPDATE post SET status='active' WHERE id=1`（`assert_behavior.sh:56`），再是 `UPDATE post SET status='archived', status_reason=1 WHERE id=1 AND status IN ('active','hidden')`（`:62`）。前者丢弃了原值，且丢得毫无痕迹。

**根因不是手滑。** 我压根没读脚本就传参了——而它头部注释第 5 行明写着三个参数的含义。同一个风险我只在一半的参数上防住了，而漏掉的那个恰好是**唯一会被写入**的库。

另一个前情值得记一句：这轮之所以是"补跑"，是因为上一轮我在 Windows 宿主执行 `docker --version` 拿到 `CommandNotFoundException`，就判定环境不具备而把断言挂起了——Docker 其实一直在 WSL 里跑着。**环境探测失败时要区分「这台机器没有这个能力」与「我没找到调用它的路径」**，后者至少该换一条路径再试（宿主 → WSL → 容器 → 远程）。换路径成功之后紧接着就是在新环境里首次跑既有脚本，正是传参审计最该收紧的时刻。

## Guidance

**逐参数过一遍，而不是只过"我正在关注的那个"。** 风险检查的覆盖面要由参数表决定，不由注意力决定。调用前对每一个参数问同一句：这个值会让脚本往哪里写？

**读脚本，只读写操作那几行就够。** 不需要通读实现，`Grep` 一遍 `INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER|>` 就能拿到写入面清单，几秒钟的事：

```bash
# 传参前的最小尽调：这个脚本会写什么
grep -nE 'INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER' docs/database/scripts/assert_behavior.sh
```

本例只要跑这一句，就能看到两条作用于**固定主键**的状态改写：`UPDATE post SET status='active' WHERE id=1`（无守卫）与 `UPDATE post SET status='archived', status_reason=1 WHERE id=1 AND status IN ('active','hidden')`。这类语句比插入危险得多：插入只在表尾追加、逐条删得掉；定点改写精确覆盖一条既有业务数据，**原值不留任何副本**。而无守卫的那条最危险 —— 它连"原状态必须落在某个集合里"这层信息都没留下。

**默认值是隐式授权，比显式传参更危险。** 本例脚本的三个参数都有默认值：

```bash
CONTAINER="${1:-mysql8}"
BIZ_DB="${2:-s2s_batch1}"
TRACK_DB="${3:-s2s_track_batch1}"
```

也就是说不传任何参数直接裸跑，写入目标就是那个压测库。**默认值让"忘记传参"和"故意传了危险值"产生完全相同的后果**，而前者不留任何决策痕迹。破坏性目标不该有默认值；要留默认，就该默认到一个不存在的名字上让它当场失败。（现状说明：这三个默认值至今仍在脚本里，本轮只补了文档侧的调用约束——所以下一段的留档才是当前唯一生效的护栏。）

**把要求写进文档，不要指望下一个人会读脚本。** 我没读脚本，下一个人也不会读。所以修复不是"以后我会更小心"，而是在《数据库设计文档》的实测留档里明写调用约束（`docs/database/数据库设计文档.md:693`）：

> 两个库名参数**必须传独立的空库**，脚本内 A1–A5 会插入测试数据并 `UPDATE post WHERE id=1`，指向任何含数据的库都会造成污染。

**污染要靠主动核对发现，别等它自己报错。** 本例脚本没有产生任何**指向污染**的错误信号——A1 与 A3 的预期输出本身就是 MySQL 报错（生成列不可写、盲索引唯一冲突），属设计预期；其余语句全部成功，脚本 `set -uo pipefail` 不带 `-e`，无条件走到 `### DONE`，退出码 0，8 项断言全绿。是我跑完之后主动去核对库的行数，才看到数字不对。所以在真实库附近执行任何脚本，前后各取一次行数快照是事后唯一可靠的检出手段——事前预防靠的是上面那份写入面清单，两者不互相替代。

**回滚要逐项精确，复核的不变量必须覆盖每一处写入面。** 按写入面清单反向逐项撤销（删 3 条新增 `post`、`id=1` 状态复位、清 3 张辅助表、`AUTO_INCREMENT` 复位），然后复核到污染前的确定值。但第一次复核我只查了三项：

```sql
SELECT (SELECT COUNT(*) FROM s2s_batch1.post),                                  -- 期望 500000
       (SELECT COUNT(*) FROM s2s_batch1.post WHERE status_reason IS NOT NULL),   -- 期望 0
       (SELECT MAX(id) FROM s2s_batch1.post);                                    -- 期望 500000
```

三项全过，我就宣布复原了。**但它们恰好一项都检不出 `id=1` 的 status 错值** —— 行数对、`status_reason` 已清空、`MAX(id)` 已复位，唯独那一列本身没人查。我当时把 `id=1` 复位成了 `active`，而造数脚本的赋值表达式是 `ELT((FLOOR(n/1000) % 4) + 1, 'draft', 'active', 'active', 'archived')`（`explain_pins_real.sh:59`），`n=1` 落在第一档 `draft`。这处残留在后续复核中才被发现，实测印证：`id=2..5` 全为 `draft`，而 status 分布是 `draft 124999 / active 250001 / archived 125000` —— 恰好错位一行。

补上按写入面推导的完整不变量后才真正复原：

```sql
SELECT (SELECT COUNT(*) FROM s2s_batch1.post),                                   -- 500000
       (SELECT COUNT(status_reason) FROM s2s_batch1.post),                        -- 0
       (SELECT MAX(id) FROM s2s_batch1.post),                                     -- 500000
       (SELECT status FROM s2s_batch1.post WHERE id=1);                           -- draft（按造数公式反推）
SELECT status, COUNT(*) FROM s2s_batch1.post GROUP BY status;                     -- 125000/250000/125000
```

**教训比原事故更尖锐：复核不变量选得不全，与没有复核在观感上完全一致 —— 它给出的是全绿。** 不变量必须由写入面逐项推导出来（脚本改了哪一列，就查哪一列），而不是挑几个"看起来能代表健康度"的聚合数字。回滚一个定点改写时，光复原"改成了什么"不够，还得知道"原本是什么"，而这个值只能从造数逻辑反推——这正是无守卫 UPDATE 的代价。

复核通过后改用两个独立空库重跑全部断言，验完即 `DROP DATABASE`。

## Why This Matters

**这类失误不产生任何指向它的错误信号。** 脚本正常退出、断言全部通过、日志里没有一行异常（A1/A3 的报错是设计预期，反而更容易掩盖真问题）。它与「造数分布不真实」是同一族缺陷：语法没问题、逻辑没问题、跑得很顺，缺陷只存在于「我以为它写到哪里」与「它实际写到哪里」之间。

但危害等级不同。改错一个只影响渲染产物的参数，重跑一次就好；改错一个触发写入的参数，**代价落在真实数据上且不可重跑**。本例侥幸可以逐项回滚，是因为写入面小、且我恰好在同一次会话里发现——如果污染的是行数本就在变的表，或者过了一天才发现，就再也分不清哪些行是脚本插的、`id=1` 原本是什么状态。事实上即便在同一会话里，我也只回滚对了一半（见上文 status 残留），差别只在于原值还能从造数逻辑反推出来。

**「一次性验证脚本无需管」这个豁免是错的。** 项目里另有一条已固化的判据：一段连库执行 SQL 再断言的脚本不含需要拍板的选择，因此不算验证脚手架（见 `phase-boundary-verification-scaffolding.md:42`、`:81`）。那条判据给的排除理由是两条——「不含决策」且「不会被误当作资产继承」，都只针对**决策痕迹**。而写入型脚本恰好落在第二条的盲区里：它确实不会被谁误继承为架构资产，却会留下不可逆的数据副作用。两套纪律各管一头，前者管"别替下一阶段做选型"，后者管"别写坏真实数据"，不互相覆盖。

**新打通的执行路径是高危时刻。** 换路径（宿主 → WSL）成功带来的是"终于能跑了"的推进感，而这恰好是最不该省掉尽调的一刻：新环境里的库列表、容器状态、数据规模全是未知的，此前所有关于"哪个库是空的"的印象都作废了。

## When to Apply

**任何时候一个脚本的参数决定了它往哪里写。** 判据是问一句：**这个参数传错了，撤销它需要付什么代价？**

- 重跑一次就好（渲染参数、查询条件、输出路径）→ 常规谨慎即可
- 需要逐项回滚才能复原（库名、表名、目标环境、清理路径）→ 传参前必须过写入面清单

同族的高危参数形态：库名 / schema 名、目标环境（dev/staging/prod）、要清理的目录、`--force` / `--yes` 之类的确认开关、任何"从哪一版开始迁移"的起点。

不适用：纯读脚本（`EXPLAIN`、`information_schema` 查询、`grep` 类分析）。但注意区分——本例的断言脚本从名字看像是"验证"，实际 A1–A5 全部走写路径（A1 是被 DDL 拒绝的写尝试，A2–A5 实际落行），A6 与 A8.1–A8.3 写埋点库，只有 A7、A8.4、A8.5 是纯读。**名字不构成豁免理由，"验证脚本"这个词尤其不构成。**

## Examples

**传参前（错误做法）：** 只对自己关注的参数尽调

```bash
# 我查过 s2s_track 是旧版 DDL、没有 uk_event_dedup，所以特意换成 s2s_track_batch1
# 第二个参数看着像本项目的库名，直接就交了
wsl -e bash docs/database/scripts/assert_behavior.sh mysql8 s2s_batch1 s2s_track_batch1
```

**传参后（正确做法）：** 先取写入面，再逐参数确认，最后给独立空库

```bash
# 1. 写入面清单（会看到两条 UPDATE post WHERE id=1，其中一条无守卫）
grep -nE 'INSERT|UPDATE|DELETE|TRUNCATE|DROP' docs/database/scripts/assert_behavior.sh

# 2. 逐参数确认：容器名（纯传导，安全）/ 业务库（会写！）/ 埋点库（会写！）
#    → 两个会写的参数都必须指向空库

# 3. 全程在 WSL 内执行 —— 脚本内部直调 docker，宿主 PowerShell 里跑会 CommandNotFoundException
wsl -e bash -c 'docker exec -i mysql8 mysql -uroot -pXXX -e "CREATE DATABASE s2s_biz_assert;"'
wsl -e bash docs/database/scripts/assert_behavior.sh mysql8 s2s_biz_assert s2s_track_batch1
wsl -e bash -c 'docker exec -i mysql8 mysql -uroot -pXXX -e "DROP DATABASE s2s_biz_assert;"'
```

**留档修复：** 让约束附着在脚本的使用说明上，而不是留在某个人的记忆里——见 `docs/database/数据库设计文档.md:693` 的实测方法留档段。

## Related

- [test-data-fidelity-for-performance-claims.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/test-data-fidelity-for-performance-claims.md) — 同一批数据库脚本的另一面：造出来的数据不真实会让结论无效甚至反向。该篇提到"独立测算库、用完即删、不污染主库"这条隔离纪律，本篇补的是它没有覆盖的部分：**传参环节**的审计。
- [phase-boundary-verification-scaffolding.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/phase-boundary-verification-scaffolding.md) — 明确把一次性造数脚本排除在验证脚手架管辖之外（按"是否含决策"判定）。本篇填的正是那个空位：不含决策≠不含破坏性。
- [multi-format-deliverable-consistency.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/multi-format-deliverable-consistency.md) — "先测绘脚本行为再动手改"的读侧版本（脚本从哪取内容），本篇是写侧版本（脚本往哪写）。
- [credential-revocation-target-mismatch-from-ledger-summary.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/credential-revocation-target-mismatch-from-ledger-summary.md) — 同一预防规则在「控制台作废密钥」场景的实例：不可逆操作前必须确证作用对象（作废哪把 key、哪个 provider、哪个控制台）。
- [assert_behavior.sh](file:///d:/developer/code/aicoding/s2s/docs/database/scripts/assert_behavior.sh) — 本例涉及的脚本。写路径：A2–A5 写业务库、A6 与 A8.1–A8.3 写埋点库、A1 为被 DDL 拒绝的写尝试；纯读：A7、A8.4、A8.5。**三个参数的默认值至今仍在**（默认业务库正是压测库），本轮修复只落在文档侧的调用约束上，未改脚本；同目录的 `explain_pins_real.sh` 更是硬编码库名 + `TRUNCATE TABLE post`（2026-09-09 refresh 更正：`explain_pins_hot.sh` 仅硬编码库名、纯 SELECT/EXPLAIN 查询，无 TRUNCATE、无写语句，属「不适用」——原文误把 hot 一并指控），读者不应以为默认值隐患已消除。
