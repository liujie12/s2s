---
title: "fail-closed 质量守门：判据工程化、变异自检与合并态活体实证"
date: 2026-09-14
category: workflow-issues
module: test
problem_type: best_practice
component: infrastructure
severity: high
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 编写或加固质量守门（gate）脚本及其测试时
  - 守门扫描面可能为空、不可读、含非 UTF-8 或 NUL 字节时
  - 存在豁免/登记册机制且可能与真实命中同行混排时
  - 契约或引用（如 OpenAPI $ref）可能不可解析时
symptoms:
  - 守门全绿但实测拦不住必拦样本
  - 空扫描面被当作 PASS 放行
  - 同行既有豁免又有真实命中时被连坐误放行
  - 密钥或后门字符串静默进入仓库
related_components: [documentation, ci]
tags: [fail-closed, gate-tests, mutation-testing, secret-scanning, test-infrastructure, contract-testing]
---

# fail-closed 质量守门：判据工程化、变异自检与合并态活体实证

## Context

条目 [121] 给仓库引入测试骨架（`test/gates/` 质量门禁、`test/contract/` 契约示范、`test/support/` 脚手架）时，骨架本身已经「能跑绿」。但三轮独立评审（落地评审 15 项、第二轮 11 项、第三轮 6 项，修复提交 009b5ef / 13a70fe / 2e725ad，见本次会话记录）暴露出一个系统性缺口：**守门测试跑绿只证明它没报红，不证明它遇到该拦的东西真会拦**。「能跑绿」≠「可证明会红」。

评审发现的假绿通道覆盖守门全链路：

- **扫描面静默缩水**：旧 512KB 体积上限把 >1MB 的 `prototype/index.html` 整体静默跳扫（未登记的高德 Key 因此漏网）；git `quotePath` 默认把 CJK 文件名转义成八进制序列，含中文名文件在扫描面中消失；解码失败走 WARN+continue，「没扫」被报成「干净」。
- **判据失声**：`firstMatch` 只判行内首个 hex，占位串在前时同行真密钥被掩蔽；「行 contains 登记串」的豁免口径把同行新密钥连带豁免（同行连坐）。
- **空候选面恒绿**：`$ref` 全部不可解析时遍历空转，断言无对象可判而 PASS。
- **环境判定写窄**：`CI == 'true'` 字面值比较让 `CI=1`/`TRUE` 等平台写法下 git 失败退回 SKIP，而 SKIP 在 CI 报告里与绿勾同形，门禁静默落空。
- **契约示范失真**：双模式共用断言打的是契约 38 个路径中不存在的 `GET /categories`，「切真服务断言一行不改」的承诺实际不成立。

第三轮评审后骨架以 `--no-ff` 合并回 main（合并提交 `bbf9acb`，main 历史可达）。**合并态复验当场实证了缺口的真实性**：G-Q2 首次在 main 全量文件面下运行即 FAIL——`说明文档.md` 两处转抄了 `prototype/index.html`、`prototype/test.html` 已登记豁免的高德 Web 服务 Key 完整明文（登记于条目 [115] 的既有泄露，非本次新增）；删除明文后转绿（`说明文档.md:4653`）。这正是本学习文档的素材：把「能跑绿」加固成「可证明会红」的判据模式。

## Guidance

以下模式按「守门写在哪、怎么写才 fail-closed」组织，每条附当前树可核实的代码位置（相对仓库根 `d:\developer\code\aicoding\s2s`）。

### 1. fail-closed 扫描面：「没扫完」必须红，禁止 WARN+continue 转绿

凡文件未能完整受扫，一律记入 `scanGaps` 并 FAIL，覆盖四类形态：git 已跟踪但工作区缺失（`test/gates/quality_gate_test.dart:510-517`，HEAD 内容未扫描）、行内含 NUL 字节疑似 UTF-16/二进制（`:533-537`，NUL 是合法 UTF-8 不抛异常，但逐字符打断正则使判据失声）、读取或 UTF-8 解码失败（`:550-554`，单文件异常不得让整道门失声也绝不放过）、取消体积上限改流式逐行读（`:521-528`，内存与文件大小解耦）。

```dart
if (!gapRecorded && line.contains('\x00')) {
  scanGaps.add('$rel: 行内含 NUL 字节（疑似 UTF-16/二进制，'
      '扫描判据逐字符失声）');
  gapRecorded = true;
}
```

合法二进制资产的**唯一出口**是 `isScanExcluded` 显式登记（`:149-176`），评审可见；排除规则须根级锚定——`p == 'build' || p.startsWith('build/')`（`:154`）而非 `contains('/build/')`，否则 `lib` 之下任意深度再嵌一层名为 build 的跟踪目录都会被连坐排除，扫描面静默缩水。配套地，扫描面取数本身也要防失声：`git -c core.quotePath=false ls-files` + 显式 UTF-8 解码（`:425-443`），并断言输出含 CJK 文件名 `说明文档.md` 作为扫描面自证（`:461-464`）。

### 2. 空扫描面守卫：先断言待判对象存在，再执行判据

「扫描面为空时 PASS 是假阴性」是固定句式。入口 `setUpAll(assertRepoLayout)`（`quality_gate_test.dart:339`；实现 `test/support/repo_paths.dart:60-72`，对象缺失抛 `StateError` 即 FAIL 而非跳过）；每条统计型断言自带计数下限：码对齐断言 `inspected > 0`（`test/gates/openapi_contract_gate_test.dart:153` 与 `:173-175`）、Retry-After 断言 `candidates > 0`（`:298` 与 `:313-315`）、G-Q3 `seen > 0`（`quality_gate_test.dart:764` 与 `:778-780`）。

```dart
expect(inspected, greaterThan(0),
    reason: '码对齐断言未检视任何响应……候选面为 0 时 PASS 是假阴性');
```

### 3. 逐命中三分支分类：处置粒度是「命中」而非「行」，防同行连坐

弱判据 `looksLikeEmbeddedSecret`（32 位 hex + 密钥语义上下文、排除注释行，`quality_gate_test.dart:219-229`）命中后，对 `hex32Pattern.allMatches` 的**每个命中**独立分类（`:492-503`），委托纯函数 `classifySecretHex`（`:317-321`）：

```dart
SecretHitVerdict classifySecretHex(String relPath, String hex) {
  if (isRepeatedCharPlaceholder(hex)) return SecretHitVerdict.placeholder;
  if (isRegisteredSecretHex(relPath, hex)) return SecretHitVerdict.exempted;
  return SecretHitVerdict.unregistered;
}
```

- 占位排除走概率性判据 `isRepeatedCharPlaceholder`（全同字符 32 位，`:235-236`）；
- 豁免判定 `isRegisteredSecretHex` 按「文件 relPath + 登记定位串 contains 命中串」精确匹配（`:308-310`）——旧口径「行 contains 登记串」会把同一已登记文件内与泄露串同行的新密钥连带豁免（收紧记录见 `:303-305`）；
- 未登记 → FAIL。占位与真密钥同行时只跳占位，同行连坐通道被封死（自检 `:635-648`）。

### 4. 拆写通道还原：同行坍缩 + 跨行拼接，三通道互补

把 32 位 hex 拆成两段相邻字面量即可躲过逐行正则。`collapseAdjacentLiterals` 还原同行相邻字面量（可选 `+`、混引号，`:250-251`），`crossLineCandidate` 还原跨行拼接（混引号、行尾/行首 `+`，`:266-287`）；扫描主流程对原行、坍缩候选、跨行候选三通道各跑一遍判据（`:538-547`），原行仍是第一通道，候选只作附加。

### 5. 盲区负向固化：已知不覆盖的形态写成「期望失败」的用例

3 行及以上拆分、块注释夹隔、行尾 `//` 注释夹隔（词法上注释等价空白，仍构成合法相邻字面量）是当前不还原的形态。不掩盖、不假装覆盖：函数注释登记「已知盲区」（`:262-265`），并用期望 `isNull` / `isNot(contains)` 的负向用例固化为可见限制（`:707-733`）——日后通道扩展到覆盖这些形态时用例变红，强制同步更新盲区登记。

```dart
final lineCommentForm =
    crossLineCandidate("    key: '${_gaodeSample.substring(0, 16)}' // 注释",
        "'${_gaodeSample.substring(16)}',");
expect(lineCommentForm, isNull);
```

### 6. G-Q1 计数剥除法：登记位抵扣一次，同行追加不连坐，异文件不连坐

`collectBackdoorLines` 逐行统计 `888888` 出现次数（`:344-360`）；`uncoveredInLine` 对命中行逐个登记条目剥除其定位串后再数剩余次数（`:369-377`）——同一登记串被多个条目重复登记不会重复抵扣，同行追加的第二个字面量剥除后仍被数出。配变异自检三例（登记位抵扣=0 / 同行追加=1 / 异文件=1，`:409-420`）。完整 before/after 见 Examples 例 2。

### 7. 变异自检（mutation self-check）：证明判据对应当失败的输入真会失败

正向跑通不构成证据。独立分组「G-Q2 判据自检」（`:599`）逐条断言：真实形态必须检出（`:600-610`，含大写 hex、KEY/Token 大小写上下文）、合法噪声不误报（`:612-618`，UUID/注释/普通文本）、登记册精确匹配不跨文件不冒名（`:626-633`）、拆写通道确实能还原（`:650-705`）、`isCi` 纯函数 8 例覆盖平台写法差异（`:735-744`：true/TRUE/1/yes/false/FALSE/空串/无键）。

「判不了」分支的唯一处置：`skipOrFailOnCi`（`:198-204`）——CI 上判据对象不可得必须 `fail`，仅本地允许 `markTestSkipped`，杜绝 CI 假绿。

```dart
if (isCi()) fail(ciFailReason);
markTestSkipped(localSkipReason);
```

### 8. 契约 $ref 不可解析即红：检出链每一环都不许静默 continue

`resolveResponse` 支持链式 `$ref`（深度上限 8 防环、前缀 `#/components/responses/`），外部引用 / 错误前缀 / 缺键 / 非映射 / 超深一律返回 null（`test/support/openapi_loader.dart:142-153`）；唯一迭代骨架 `forEachResolvedOperationResponse` 把不可解析条目记入 `unresolvable`，调用方并入 `bad` FAIL（`openapi_contract_gate_test.dart:62-85`、`:172`、`:312`），与 `OpenApiSpec.load`「契约文件缺失直接抛错、不许降级跳过」（`openapi_loader.dart:27-37`）同口径。检出链第一环必须有独立单测（`:378-415`：内联原样返回、链式解析到终点、外部/错前缀/缺键/非映射各返 null）。补充绑定：`code=0` 仅 2xx 状态键下合法，非 2xx 承载成功码即契约自相矛盾记 bad（`:158-165`）。

```dart
for (var depth = 0; depth < 8; depth++) {
  if (current is! YamlMap) return null;
  final ref = current[r'$ref']?.toString();
  if (ref == null) return current;
  if (!ref.startsWith(prefix)) return null; // 外部/错前缀
  current = components?[ref.substring(prefix.length)];
}
```

### 9. 占位/豁免判定向 fail-closed 方向写：宁多查一遍，不少查一个

- `isPlaceholder` 从只看 `responses['200']` 放宽为「任意 2xx 带 content 即已展开」（`openapi_contract_gate_test.dart:190-204`）：只看 200 会把以 201/204 承载成功的写接口误判为占位而跳过幂等头检查——那是 fail-open 方向的缺陷，放宽判定面是朝 fail-closed 修复。
- 豁免必须显式登记且附契约文本佐证：幂等头豁免 `POST /posts/precheck` 登记时要求 description 含「不写库」佐证词，找不到即 FAIL（`:209-213` 与 `:226-234`）；占位与豁免清单打印留证不静默（`:240-245`）。
- `code=0` 仅 2xx 合法是同一原则：把「成功码出现在错误状态」从默认放行改为显式记 bad。

### 10. 契约示范必须打契约内真实端点

双模式（内存 mock / 真服务 `S2S_API_BASE_URL`）共用的断言面，必须打契约中真实存在的公开只读端点 `GET /categories/tree`（`test/contract/api_contract_example_test.dart:173-199`；契约 `docs/api/openapi.yaml:489` 声明、`security: []` 免登录见 `:496`）。原断言打 `GET /categories`——契约 38 个路径（对 `docs/api/openapi.yaml` 顶层路径键计数核实）中无此项，切真服务必 404，「切真服务断言一行不改」的承诺失真；这是第三轮评审唯一 major。mock 专属场景与桩字面值用 `skipMockOnlyInRealMode` 显式记 N/A（`:69-74`），不伪装通过。

### 11. 合并回主干前的活体复验：守门必须在合并结果态的全量文件面下重跑

分支内绿 ≠ 合并态绿——扫描面是两侧文件的并集。本条目合并态首次复验 G-Q2 即 FAIL，拦下 `说明文档.md` 两处转抄的已登记高德 Key 完整明文；删除明文后转绿；据本次会话结论，随后故意在磁盘留存明文复跑立即 FAIL，实证守门读工作区而非 git 索引（事件记录 `说明文档.md:4653`）。配套教训：该 Key 曾误记为「测试探针新 Key」拟重复挂账，经 `git log -S` 与登记册核对确认为同一把既有登记 Key，作废责任归口条目 [115]，不重复挂账（`说明文档.md:4654`）——**泄露挂账也要核实，否则作废责任错配**。复验数据（`说明文档.md:4656`）：`flutter analyze` 0 issue；`CI=true flutter test test/gates/ test/contract/` 43/43；全量 318/318 = 合并前基线 275 + 净增 43，逐文件核对精确吻合。

### 12. 评审方法论：主审候选 → 双独立复核 → 共识置信度

据本次会话结论：主审形成候选发现后，派 2 个独立 sub-agent 并行只读复核全部候选并主动找新问题，按 2/2、1/2 共识标置信度；fail-closed 方向的假阳性（如 path 级 parameters 不合并）记录不修。三轮共修 32 项（15+11+6，记录于 `说明文档.md:4647-4650`）。守门代码自身的评审密度应高于业务代码——它是其他全部代码的信任根。

## Why This Matters

- **假绿守门 = 密钥、后门、契约漂移静默入库**。本条目提供了活体实证：main 合并态首次跑 G-Q2 即拦下两处完整明文 Key 转抄。若守门留有任意一条假绿通道——WARN 转绿、行级连坐豁免、体积上限跳扫、CJK 文件名漏扫——这次泄露就无声进入 main 历史。
- **「能跑绿」的守门比没有守门更危险**：它制造虚假安全感，让评审者与 CI 读者以为防线存在。守门是信任根，信任根的假阴性会把错误放大到它守卫的全部对象上（契约错了会把错误复制到所有按契约生成的实现里）。
- **fail-open 的「宽容」每一处都是免费通道**：占位判定写窄、豁免口径写宽、SKIP 当通过——攻击者与失误者共享这些通道。fail-closed 方向的代价至多是假阳性惹人烦（记录不修即可）；fail-open 方向的代价是无声事故。改守门代码时先问：这一改让门更严还是更松？
- **计数诚实的复利**：318 = 275 + 43 逐文件核对、基线只增不减的口径，让「测试变多但守护变少」这类漂移无处可藏；合并态复验把「分支绿」与「主干绿」的差异显性化。

## When to Apply

- 编写任何静态扫描 / 安全门禁 / 契约守门测试时（密钥扫描、后门登记册、许可证检查、API 契约绑定、feature flag 登记）：默认按 fail-closed 设计，为判据写变异自检。
- 给既有守门新增判据或调整豁免/排除口径时：做方向检查——这一改是 fail-open 还是 fail-closed；豁免必须显式登记 + 留证 + 双向核对防凑数。
- 分支合并回主干前：守门必须在合并结果态（全量文件并集）下重跑一遍，而非仅信分支内结果。
- 设计 CI 环境判定与跳过语义时：记住 SKIP 在 CI 报告里与绿勾同形，「判不了」在 CI 上必须红。
- 发现判据存在覆盖盲区时：不掩盖——用期望失败的负向测试把盲区固化为可见限制，并同步注释登记。

## Examples

### 例 1：`isPlaceholder` 只看 200 → 任意 2xx 带 content（fail-open 缺陷的修复方向）

Before（复审三 #6 前形态，据本次会话记录；缺陷原理注释见 `openapi_contract_gate_test.dart:192-194`）：

```dart
final ok = op.responses?['200'] as YamlMap?;
// 以 201/204 承载成功的写接口被误判为占位 → 跳过幂等头检查（fail-open）
return batch != 'Batch1' && ok?['content'] == null;
```

After（`test/gates/openapi_contract_gate_test.dart:196-201`；判定结论 `:203` 为 `batch != 'Batch1' && !has2xxContent`）：

```dart
var has2xxContent = false;
responses?.nodes.forEach((key, value) {
  final status = int.tryParse(key.toString());
  if (status != null && status >= 200 && status < 300 && value is YamlMap) {
    if (value['content'] != null) has2xxContent = true;
  }
});
```

### 例 2：G-Q1 整行 contains 豁免 → 计数剥除法（堵同行追加连坐）

Before（复审三 #5 前形态，据本次会话记录——同一登记行追加第二个 `888888` 会被连带豁免，评审记录见 `说明文档.md:4650`）：

```dart
final covered = registeredBackdoors.any(
  (b) => b.file == file && line.contains(b.lineContains),
); // 整行命中登记串即豁免：同行新后门连坐变绿
```

After（`test/gates/quality_gate_test.dart:370-376`，函数 `uncoveredInLine`；变异自检三例 `:409-420`）：

```dart
var remaining = line;
for (final b in registeredBackdoors) {
  if (b.file == file && remaining.contains(b.lineContains)) {
    remaining = remaining.replaceFirst(b.lineContains, '');
  }
}
return RegExp('888888').allMatches(remaining).length;
```

### 例 3：密钥豁免按行 → 逐命中分类（同一原则在 G-Q2 的镜像）

Before（复审 #4 前形态，收紧记录注释见 `quality_gate_test.dart:303-305`）：`firstMatch` 只判行内首个 hex，且「行 contains 登记串」豁免整行——同一已登记文件内与泄露串同行写 `BACKUP: '<新32hex>'` 直接变绿。

After（`quality_gate_test.dart:492-503` 逐命中循环 + `:308-310` 精确匹配）：

```dart
for (final match in hex32Pattern.allMatches(text)) {
  final hex = match.group(0)!;
  switch (classifySecretHex(rel, hex)) { /* placeholder/exempted/unregistered */ }
}
// isRegisteredSecretHex：registeredSecretFindings
//     .any((r) => r.file == relPath && r.lineContains.contains(hex));
```

三个例子是同一判据模式的三个实例：**处置粒度从「行/文件」下沉到「命中」，豁免从「整片放行」改为「逐处抵扣」**——粒度每粗一级，连坐豁免的免费通道就宽一分。

## Related

- [spec-to-failing-gate-tests-with-self-proving-exemptions.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/spec-to-failing-gate-tests-with-self-proving-exemptions.md)：同一测试骨架（test/gates/）的首轮沉淀——占位识别、佐证词豁免、变异自证、四态诚实性在该文首建（建立）；本文记录其后三轮评审加固——fail-closed 扫描面、逐命中三分支防同行连坐、$ref 即红、空扫描面守卫、合并态活体实证（加固），两者构成「建立→加固」连续谱系。
- [verification-code-fails-silently-as-pass.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/verification-code-fails-silently-as-pass.md)：fail-closed 原则的上游源头——「检查对象缺失落入 else 输出 PASS」「扫描面为空是 SKIP 不是 PASS」与本文的「不可读/缺失文件即 FAIL」「inspected>0 空扫描面守卫」是同一失效族在 bash 门禁脚本与 Dart 守门测试两个载体上的镜像。
- [review-findings-require-empirical-verification.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/review-findings-require-empirical-verification.md)：本文「三评审交叉验证法（2 独立 sub-agent 共识置信度）」与该文「评审结论必须实测核验后再修复（推翻率 ~19%）」互为方法论支撑：一个解决多评审意见的采信阈值，一个解决评审结论的真实性。
- [gate-exit-code-needs-a-consumer.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/gate-exit-code-needs-a-consumer.md)：共享四态门禁（PASS/FAIL/SKIP/豁免列名）与「判据严谨度×消费方」公式；本文的判据工程化只在判据一侧发力，退出码消费是另一侧的既定学习。
- [credential-revocation-target-mismatch-from-ledger-summary.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/credential-revocation-target-mismatch-from-ledger-summary.md)：同一 G-Q2 密钥检出事件（高德/火山 key，prototype/ 硬编码）的两个侧面：该文讲处置对象张冠李戴的纠正，本文讲检出判据本身在合并态被活体验证（实证守门读工作区非索引），互链闭合「检出→处置」链。
