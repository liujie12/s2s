---
title: "把书面规格转成会失败的守门测试：占位识别、佐证词豁免与变异自证"
date: 2026-09-08
category: workflow-issues
module: test
problem_type: workflow_issue
component: infrastructure
severity: high
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 后端实现尚未开工，唯一可判定的 API 面是 OpenAPI 契约等书面规格
  - 要把方案文档里的门禁纪律落成 CI 可执行、且真会 FAIL 的守门测试
  - 规格里存在未展开的占位接口（后续批次实现），一刀切的静态判据会把占位误判成缺陷
  - 判据需要豁免通道，又担心豁免被随手登记、变成绕过判据的口子
  - 需要证明新写的判据对「应失败输入」真会失败，而不只是对样例输入跑通
tags: [gate-check, verification-gate, openapi, contract-testing, false-negative, exemption-register, mutation-testing, four-state-gate]
---

# 把书面规格转成"会失败的守门测试"：零实现阶段的契约/门禁落地模式

## Context

书面规格（接口契约、安全/DevSecOps 方案条款）在落地为实现之前，处于一个尴尬区间：**文档存在、实现不存在，因此"没法测"**。常见结果是规格评审靠人肉，条款在实现期被静默违反也无人发现——而规格自身的内部矛盾（承诺的错误码没有任何示例承载、码与 HTTP 状态不对齐、要求写接口带幂等头却无人引用）在人肉 review 中必然漏检，且漏了不报错。

本学习沉淀的是一种可迁移模式：**不等待实现，先把规格解析为可断言的结构，让"规格内部跨条目一致性"和"条款本身"在今天就变成 FAIL/PASS 的自动判据；同时用真实 HTTP 栈的内存级 mock 固定未来实现的测试范式。** 伴生问题是：任何判据都有正当例外（未展开的占位、一次性原型资产），例外通道处理不当会把判据掏空。本文给出三种构造，使"判不了不得报通过"在存在例外时仍然成立。

下文中，**加粗的"准则"句不依赖任何具体技术栈**；"本仓库实证"段落仅作为证据与样例。

## Guidance

### 1. 静态守门判"跨条目一致性"，不判语法

**准则：** 规格文件可解析只是前提，真正值得自动化的是规格内部**不同位置之间的承诺对齐**——它人肉必漏、机器可判，且违背时不会在任何其他环节报错：

- **集合完整性（双向）**：规格在枚举表中宣称的全集，必须恰好等于另一处（示例、复用响应）实际承载的集合。多了 = 写了未登记的东西；少了 = 承诺的东西没有承载。断言用**集合相等**而非子集，两个方向同时封死。
- **编码对齐**：宣称"业务码前三位即 HTTP 状态码"时，对枚举表中每一条机械验证 `code 前缀 == HTTP`，逐条失败逐条列出。
- **纪律引用**：宣称"所有写接口必带某头/某参数"时，遍历全部写操作，检查是否真的引用了该参数定义；再对参数定义本身断言其格式约束（如版本位正则、required）。
- **条款承载**：方案要求"某错误必须回某响应头"时，断言对应复用响应声明了该头，且头定义含类型与最小值约束。

**本仓库实证：** 契约静态守门共 14 项（[openapi_contract_gate_test.dart](file:///d:/developer/code/aicoding/s2s/test/gates/openapi_contract_gate_test.dart)）。集合完整性见 openapi_contract_gate_test.dart:62-76（递归收集示例中业务码的 `collectCodes` 见 :24-36，与"24 个错误码 − 后台专用码"集合相等，reason 明确写出多了/少了的含义）；码↔HTTP 逐条对齐见 :87-92；幂等头引用遍历见 :118-153，参数自身的 UUID v4 正则断言见 :155-165；Retry-After 头声明与定义（integer/minimum 1）见 :168-191。

### 2. 零实现期的双轨：静态守门现在判，契约测试用内存 mock 固定范式

**准则：** 被实现对象不存在时，把测试拆成两轨，不要合并等待：

- **静态轨**：解析规格文件本身（只依赖文件与解析库），与实现就绪与否无关，CI 立刻可跑。
- **行为轨**：用语言自带 HTTP 栈在 localhost 起最小内存服务（真实状态码、真实响应头、真实 JSON 编解码——不用拦截器层 mock），按"方法+路径"登记处理器；客户端用生产同款 HTTP 库对它发真实请求。**断言只针对协议形态，不针对实现**，实现就绪后仅替换 baseUrl，断言一行不改。判据对象（规格文件）缺失时应直接 FAIL（抛异常），不得 skip——否则规格被删光时门禁反而全绿。

**本仓库实证：** 加载器对文件缺失抛 FormatException（[openapi_loader.dart:24-37](file:///d:/developer/code/aicoding/s2s/test/support/openapi_loader.dart#L24-L37)），setUpAll 直接加载、失败即整组红（openapi_contract_gate_test.dart:42-45）。内存服务走 dart:io 真实 HTTP 栈、绑 loopback 随机端口（[mock_api_server.dart](file:///d:/developer/code/aicoding/s2s/test/support/mock_api_server.dart)）；4 个示范（统一成功包/429+Retry-After/缺幂等键 40001/合法 JSON）见 [api_contract_example_test.dart:43-136](file:///d:/developer/code/aicoding/s2s/test/contract/api_contract_example_test.dart#L43-L136)，文件头注释即"换成真实基址，断言一行不用改"。

### 3. 三种必备构造，让例外通道不掏空判据

**准则（通用）：** "判不了不得报通过"与"存在正当例外"并不矛盾，前提是例外只能以以下三种形态出现，且**每种都留痕、可反向验证**：

1. **占位识别（不判，但列名）**：规格中显式标注为"未展开"的部分（批次标记 + 响应体未展开）识别后跳过；判据必须是"明确标记 **且** 无实质内容"两个信号的合取，不能只看名字。跳过结果必须打印列名——占位不可静默，否则"漏检"与"占位"在输出里无法区分。
2. **自证豁免（登记表 + 规格内反向佐证词）**：豁免不是一句话声明，而是登记表中的一条，且每条携带一个**能在被判对象中反向断言存在的佐证词**。例：豁免理由是"无写入副作用/不写库"，测试就断言该接口的规格描述文本真的包含该词。佐证词缺失即 FAIL——这把豁免从"声明"升级为"证据"，使有副作用的接口无法靠改登记表混入豁免。
3. **登记册双向核对**：未登记命中 → FAIL；登记了但代码/规格中对应内容已不存在 → FAIL。后者防的是"东西删了登记册留着凑数"，它与前者同样重要：只单向核对的登记册会随时间腐烂成噪声。定位用"文件 + 行内稳定子串"而非行号，避免行漂移。

所有豁免/占位命中都要打印列名（SKIP/豁免必须可见）。

**本仓库实证：** 占位判定（x-batch 非首批且 200 响应无 content）openapi_contract_gate_test.dart:102-107，占位与豁免打印于 :146-148；豁免表仅一条且带佐证词"不写库" :112-116，反向断言 :129-138。后门码登记册双向核对见 quality_gate_test.dart:207-223（未登记 FAIL）与 :225-236（过期登记 FAIL），登记条目结构含存在理由与删除条件 :26-61。密钥豁免登记同构 :64-128、其双向核对 :305-315。

### 4. 判据自身先过变异测试：正向跑通不构成证据

**准则：** 弱判据（基于形态+上下文、存在误报空间）必须抽成**纯函数**，配独立单测同时证明两件事：(a) 对应当失败的真实违规形态**返回命中**（漏报测试）；(b) 对已知合法噪声**不命中**（误报测试），典型噪声包括：标准格式 ID（如带连字符的 UUID）、注释行、无密钥语义上下文的等长串、模板占位假值。只写"扫描器跑通且当前树干净"等于零证据——当前树可能恰好没有违规形态。判据是否真有检出力，只能由针对判据函数本身的测试证明。

**本仓库实证：** 弱判据纯函数 `looksLikeEmbeddedSecret`（32 位 hex ∧ 密钥语义上下文 ∧ 非注释）quality_gate_test.dart:156-166；占位形态纯函数 :172-173；登记匹配纯函数 :179-181。4 组自检（真实形态必须命中/噪声必须不命中/全同字符识别/跨文件不可冒名）:329-359。最强证据不是自检本身，而是判据首轮运行即真实拦到问题（见 Why 第 3 点）。

### 5. 强判据不给豁免通道；弱判据才配"占位/豁免/FAIL"三分支

**准则：** 按误报率给判据分级，**例外机制只配给弱判据**：

- **强判据**（固定形态、误报率近零，如标准私钥头、云厂商固定前缀的访问密钥 ID）：命中即 FAIL，代码中不提供豁免分支。给强判据开豁免口，等于为真实事故留门。
- **弱判据**（形态宽松、需语义上下文辅助，如"N 位 hex + 密钥命名上下文"）：命中后三分支——① 按概率特征可判定为模板假值（32 位全同字符，真实随机串中出现概率可忽略）→ 排除；② 命中登记册且佐证有效 → 列名豁免；③ 否则 FAIL。模板假值的排除依据应是可论证的概率特征，而非"看起来像假的"。

**本仓库实证：** 私钥 PEM 头、云 AK 正则命中直接进 findings 不可豁免 quality_gate_test.dart:273-278；弱判据三分支 :280-290；全同字符占位 :282-284 与纯函数 :172-173。

### 6. 扫描面为空 / 环境不可判定：FAIL 与 SKIP 各归其位，绝不报 PASS

**准则：** 区分三种状态并诚实呈现：

- **关键路径缺失（扫描面为空）**：抛异常 FAIL。空目录上的"扫描通过"是假阴性，比没有判据更糟。
- **环境不具备判定条件**（如非版本库环境无法读索引）：用测试框架的 skip 原语显式 SKIP，并在原因中写明"没扫过不等于干净"。
- **CI 只放代码面可真实判定的判据**：判据对象在 CI 运行环境中不存在的检查（部署环境、域名、IAM、运行中容器），放进 CI 只会全部 SKIP，制造"绿勾但内容为空"——失效门禁的默认落点是"通过"，比没有门禁更差。这类判据留在对象真实存在的环境（发版机/部署机）执行，并强制消费其退出码。

**本仓库实证：** 扫描前先断言关键路径存在（[repo_paths.dart:47-59](file:///d:/developer/code/aicoding/s2s/test/support/repo_paths.dart#L47-L59)，quality_gate_test.dart:185）；非 git 环境 markTestSkipped 见 :257-260 与 :369-372；CI 只承载 analyze 0 error、守门测试、全量测试三道代码面判据（[ci.yml](file:///d:/developer/code/aicoding/s2s/.github/workflows/ci.yml)），部署面判据刻意排除的论证见该文件头部注释与《DevSecOps 接入方案》§8 末（部署检查为何不进 CI）、§9 落地清单第 11 项。

## Why This Matters

1. **错误会沿规格向所有实现复制。** 后端/客户端以契约为准生成与校验，契约自身错一个码、漏一个头，错误会被复制进每一处实现；静态守门在零代码阶段就切断这个复制源。
2. **跨条目不一致是人肉 review 的盲区，且漏了没有任何报错。** "枚举表 25 个码、示例只承载了 23 个"这类问题不存在编译期信号；集合相等断言让它第一次具备失败能力。
3. **判据首轮运行即真实拦到问题，证明模式有效而非仪式：**
   - 7 个部署脚本在 git 索引中的模式位错误（100644，应为 100755）被执行位判据首轮拦出并修复——含门禁脚本自身，quality_gate_test.dart:362-389。
   - 早期交互原型中 4 处硬编码的真实形态密钥（2 把不同的 key：1 个地图 Web Key、1 个大模型 API Key 出现在 3 个文件）被弱判据首轮命中，现全部在豁免登记册中留证，并如实标注"进 git 历史即视为泄露，唯一处置是控制台作废更换"（quality_gate_test.dart:95-128；实际命中位于 prototype/pathDetail.html:1315、prototype/search.js:59、prototype/semanticProcessingSystem.js:16、prototype/smartParse.js:17）。
4. **豁免通道是判据最容易腐烂的位置。** 一句话声明式豁免会随迭代被滥用；佐证词反向断言与双向核对把每条豁免绑定到一个可验证事实和一个删除条件，使登记表无法悄悄膨胀。
5. **四态诚实性（PASS/FAIL/SKIP/豁免列名）决定门禁可信度。** 自动化不是重新立法，而是把书面裁决（"命中行人工逐处确认，无法确认即失败"、"lint 0 error"、"密钥命中即拒绝"）变成机器可执行的 FAIL。

## When to Apply

- 存在一份**结构化规格**（OpenAPI/Protobuf/JSON Schema/数据库 schema/码表）且实现尚未开始或尚未完成时——先写静态守门，不要等。
- 规格包含**全局纪律条款**（统一响应包、必带头、错误码表、格式约束、限流头）且这些条款会被多处实现复制时。
- 方案文档含**可机械化的红线**（禁用串/后门码扫描、文件权限位、忽略名单覆盖、产物字符串计数），且要求"命中即拒绝"时。
- 团队已有或预期出现**正当例外**（联调后门、一次性原型、未展开批次）时——在判据上线的同一天上线占位识别/佐证豁免/双向核对，不要事后补。
- 配置 CI 时：逐条问"判据对象在 runner 上是否真实存在"，否则该判据移到对象所在环境，不进 CI。

不适用：纯主观质量（可读性、架构品味）；判定对象无法在任何自动化环境中稳定获得且误报代价高的检查（保留人工评审）。

## Examples

### 例 1：豁免从"一句话声明"升级为"可反向断言的证据"（before / after）

before——声明式豁免，有副作用的接口改名混进来也不会失败：

```dart
// 反模式：登记表只是字符串集合，理由写给人看，机器无法验证
const idempotencyExempt = {'POST /posts/precheck'};
if (idempotencyExempt.containsKey(key)) continue; // 静默放过，无留痕
```

after——本仓库实证（openapi_contract_gate_test.dart:112-138），豁免值是必须在规格描述中真实出现的佐证词：

```dart
// key: METHOD path；value: 规格中证明其无副作用的佐证词
const idempotencyExempt = <String, String>{
  'POST /posts/precheck': '不写库',
};
if (idempotencyExempt.containsKey(key)) {
  final witness = idempotencyExempt[key]!;
  final desc = op.raw['description']?.toString() ?? '';
  expect(desc, contains(witness), // 佐证词不在规格里 → FAIL
      reason: '$key 登记豁免但契约描述找不到佐证「$witness」');
  exempted.add('$key（佐证：$witness）');
  continue;
}
// 豁免清单随后 print 列名，不静默（:146-148）
```

### 例 2：弱判据三分支与判据自检（本仓库实证，精简）

```dart
// 扫描处置（quality_gate_test.dart:360-371）
const pemPrefix = 'PRIVATE KEY';
final pemMarker = '$pemPrefix-----'; // 插值拼装防自扫描（相邻字面量会被坍缩通道还原，评审 #5）
if (line.contains(pemMarker)) findings.add('$loc 强判据，不可豁免'); // 强判据无豁免口
if (looksLikeEmbeddedSecret(line)) {
  final hex = RegExp(r'\b[0-9a-f]{32}\b').firstMatch(line)!.group(0)!;
  if (isRepeatedCharPlaceholder(hex)) continue;              // ① 模板假值（概率特征）
  if (isRegisteredFinding(rel, line)) exempted.add('$loc');  // ② 登记豁免（列名留证）
  else findings.add('$loc 未登记豁免');                        // ③ FAIL
}
```

判据必须同时证明有检出力与不误杀（quality_gate_test.dart:330-342；下例载荷以占位符示意，逐字用例见该测试文件）：

```dart
expect(looksLikeEmbeddedSecret("apiKey: 'sk-<32 位随机 hex 载荷>'"), isTrue);  // 真实形态必命中
expect(looksLikeEmbeddedSecret('final uuid = "<8-4-4-4-12 连字符 UUID>";'), isFalse); // 标准 ID 不命中
expect(looksLikeEmbeddedSecret('// key: 注释行里的 <32 位 hex 载荷>'), isFalse);      // 注释不命中
expect(looksLikeEmbeddedSecret('const padding = "abcdefghijklmnopqrstuvwxyz012345";'), isFalse); // 无密钥上下文不命中
```

### 例 3：环境不可判定时 SKIP，绝不 PASS（本仓库实证）

```dart
// quality_gate_test.dart:253-260
final files = trackedFiles(); // git ls-files；非版本库环境返回 null
if (files == null) {
  markTestSkipped('扫描面不可得——记 SKIP 而非 PASS：没扫过不等于干净。');
  return;
}
```

对照：关键路径（契约文件、lib/、部署脚本目录）缺失时是直接抛异常 FAIL 而非 SKIP（repo_paths.dart:47-59）——"判不了"要区分"环境不具备"（SKIP）与"判据对象被删光"（FAIL）。

## Related

- [verification-code-fails-silently-as-pass.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/verification-code-fails-silently-as-pass.md)：上游原则——正向跑通不构成证据、SKIP 是独立态；本文把其一次性人工负向实测固化为随 CI 运行的判据变异自检。
- [gap-register-triage-and-enforceable-discipline.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/gap-register-triage-and-enforceable-discipline.md)：纪律句拆"判据/卡点/失败后果"三件套；本文是三件套在可代码判定时的自动化形态，并新增占位/豁免两种条款形态。
- [gate-exit-code-needs-a-consumer.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/gate-exit-code-needs-a-consumer.md)：门禁有效性公式与四态、带理由放行；本文补反向准入——不可在 CI 真实判定的条款不进 CI。
- [cross-document-reference-verification.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/cross-document-reference-verification.md)：溯源标注即审计闸门；本文的佐证词反向断言是其"规格↔测试"自动化版本。
- [phase-boundary-verification-scaffolding.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/phase-boundary-verification-scaffolding.md)：零实现阶段验证不得替下一阶段做决策；静态解析 + mock 是该边界下的合规正面形态。
