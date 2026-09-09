---
title: 多格式交付件一致性同步：内容源不对称与几何溢出审计
date: 2026-08-23
last_updated: 2026-09-09
category: workflow-issues
module: docs
problem_type: workflow_issue
component: documentation
severity: high
applies_when:
  - 同一套需求口径需要在 docx 与 pptx 等多个交付件之间保持一致
  - 交付件由脚本生成，但不同脚本的内容源机制不一致
  - 存在「不允许文字重叠」这类版式约束，需要在生成后自动验证
  - 权威源 MD 刚发生结构级变更（新增整章、章节编号顺推），派生交付件尚未重生
  - 交付件即将对外提交（评审、软著登记、备案）前的最后核验
tags: [prd, pptx, docx, python-pptx, consistency, overflow-check, single-source-of-truth]
---

# 多格式交付件一致性同步：内容源不对称与几何溢出审计

## Context

项目有三份对外交付件，均由 Python 脚本生成：

| 交付件 | 生成脚本 | 内容源 |
|---|---|---|
| 找鸭找-产品需求文档-v2.1.docx | `gen_prd_v2.1_docx.py` | **读取 `PRD.md`** |
| 找鸭找-商业需求文档-v2.1.pptx | `gen_brd_pptx.py` | **脚本内硬编码字典** |
| 找鸭找-市场需求文档-v2.1.pptx | `gen_mrd_pptx.py` | **脚本内硬编码字典** |

当需求口径发生变更（本次是 8 项核心口径，含技术栈更换、性能承诺改为前置 POC、指标定义收窄等），需要把变更从权威源传导到全部三份交付件。

这里埋了两个坑，都是在实际操作中踩到才暴露的：

1. **内容源不对称**：我最初假定三个脚本行为一致，改完 `BRD.md` / `MRD.md` 就直接重跑脚本。结果两份 PPTX 内容毫无变化 —— 因为 `gen_brd_pptx.py` 的 [build_content_map()](file:///d:/developer/code/aicoding/s2s/docs/gen_brd_pptx.py#L77-L86) 返回的是「形状路径 → 文本」的硬编码字典，从不打开任何 `.md` 文件；而 `gen_prd_v2.1_docx.py` 的 [main()](file:///d:/developer/code/aicoding/s2s/docs/gen_prd_v2.1_docx.py#L509-L514) 确实读取 `PRD.md`。
2. **验证盲区**：用户在看到 MD 文件大量改动、而 PPTX 表面无明显变化时，直接质疑「我看只改了 md 文档」。当时我只有时间戳和文件大小作为证据，无法证明内容已落盘。

## Guidance

### 一、先测绘内容源，再动手改

面对一组「由脚本生成的交付件」，第一步不是改内容，而是确认每个脚本的内容源。判定方法是搜索脚本里是否存在读文件的动作：

```
Grep pattern: "\.md|open\(|read_text" 于生成脚本目录
```

命中的是「MD 驱动型」，改 MD 即可；未命中的是「硬编码型」，必须直接改脚本内的文案字典。

据此得出本项目的传导路径：

```
口径变更
  ├─ PRD.md ──────────────► gen_prd_v2.1_docx.py ──► PRD.docx      （改 MD 即可）
  ├─ BRD.md（口径留档）
  │   └─ 同步手改 ────────► gen_brd_pptx.py ───────► BRD.pptx      （必须改脚本）
  └─ MRD.md（口径留档）
      └─ 同步手改 ────────► gen_mrd_pptx.py ───────► MRD.pptx      （必须改脚本）
```

硬编码型脚本的 MD 仍然要改 —— 它是口径留档与评审载体，只是**不再具备驱动力**，必须与脚本文案成对修改。本次共改动 BRD.md / MRD.md 口径 26 处、脚本硬编码槽位 14 处（BRD 7 + MRD 7）。

### 一之二、MD 驱动型的残余风险：「改 MD 即可」不等于「改完就同步了」

上面那张传导图把 PRD 一路标成「改 MD 即可」，容易被读成「MD 驱动型没有同步风险」。**2026-08-24 的一次事故证明恰恰相反 —— 出事的就是 MD 驱动型这一路。**

当天 13:04 `PRD.md` 新增了整个「第十部分：工程契约（接口 / 数据 / 非功能）」约 420 行（§12 接口需求 / §13 数据需求 / §14 非功能需求），并把原「第十部分：附录」顺推为「第十一部分：附录」。但派生的 `找鸭找-产品需求文档-v2.1.docx` 仍是前一天 19:26 生成的旧版（95,909 字节），**滞后近 18 小时，整章工程契约根本不在里面**。脚本本身完全正常，它确实读 MD —— 只是没有人重跑它。

这个缺口不是任何报错暴露的，是用户追问「两者信息拉齐同步了吗」才触发核查。**权威源与派生件之间的时间差是一种静默缺陷**：没有编译失败，没有脚本报错，两个文件各自都是内部自洽的合法文件，只有把它们放在一起比才看得出来。

所以「MD 驱动型」的准确含义是：改 MD 是**必要而非充分**条件，后面还有两步都得人做。

**残余风险一：脚本不产出最终文件名。** [gen_prd_v2.1_docx.py](file:///d:/developer/code/aicoding/s2s/docs/gen_prd_v2.1_docx.py#L509-L514) 的 `main()` 把输出目标写死为 `..._tmp.docx`，L512 行尾注释明确写着「避开 Word 文件锁，生成后由外部改名」。跑完脚本会打印 `[OK] 已生成 ..._tmp.docx`，看起来成功了，但正式交付件文件根本没被替换 —— 这是又一个静默失败面。完整两步：

```powershell
# 重跑前先确认没有 WINWORD 进程占用
Get-Process WINWORD -ErrorAction SilentlyContinue

$env:PYTHONUTF8 = 1
python docs\gen_prd_v2.1_docx.py
Move-Item -Force "docs\找鸭找-产品需求文档-v2.1_tmp.docx" "docs\找鸭找-产品需求文档-v2.1.docx"
```

两个配套经验：`docs` 下若见 `~$*` 锁文件要看清扩展名 —— 那次的两个是 pptx 残留，与 docx 无关，不构成阻塞。以及 Windows 下 Python 按默认 GBK 读中文文件会 `UnicodeDecodeError`，**自写读 MD 的探针与随 skill 附带的校验脚本**是这个错的高发处，都得先设 `$env:PYTHONUTF8=1`（既有闸门 [verify_prd_docx.py](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L10-L11) 只用 `sys.stdout.reconfigure` 处理了输出侧 —— 它自己不读文本文件，只读 docx 二进制，所以不会撞解码错，但也就没有现成的读入侧范例可抄）。

**残余风险二：闸门覆盖面不会自己长。** [verify_prd_docx.py](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L77-L90) 的一级章节清单是硬编码的 `"0. 产品总览"` 到 `"11. 功能模块验收清单"`，止于 §11。新增的 §12–§14 与两个「第十部分 / 第十一部分」H1 标题都不在清单里，核心关键词表同样没有工程契约词条。**即使 docx 整段丢失工程契约三章，这五段闸门也不会因此产生任何一条 FAIL 或 MISS** —— 这就是滞后 18 小时没被自动拦住的机制性原因。闸门是按某一时刻的文档结构写死的，文档长出新章节后它会静默失效，新增章节时必须同步扩容清单。

顺带纠正一处仓库既存口径：该脚本实际是**五段**校验，不是流传的「四段」—— [L29](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L29) 核心规格关键词 34 项、[L55](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L55) Scope 红线 7 项、[L65](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L65) 统一口径 6 项、[L75](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L75) 一级章节 12 项、[L98](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L98) 版本演进痕迹 18 项。「四段」这个说法在 `说明文档.md` 与本篇早期版本里都出现过 —— **闸门段数这类可数事实也要回代码点，不要沿用留档里的转述**。

顺带一个已确认的反向问题：该脚本曾把「替换」「替代」列为必须 0 次的版本痕迹禁用词，而 `PRD.md` 有多处正常动词用法（换底图流程「替换配置」、Logo「转曲后替换」等），MD 驱动型脚本会原样渲染进 docx，会让闸门产生与新增章节无关的自伤式误报。**该问题已于 2026-09-02 按本篇建议收窄落地**：[verify_prd_docx.py L110-L118](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L110-L118) 现把裸词黑名单改为带版本语境的组合（「替代 v2」「替换为 v」「替换旧」等），注释明确「不拦替换配置/不可替代的优势」；当前 PRD.md 的 4 处「替换」命中（L409 转曲后替换 / L1081、L1082 换底图 / L1298 替换配置）均属正常动词、不再误报。

### 二、定位硬编码槽位用关键词而非逐行读

硬编码字典按幻灯片序号组织（本项目 BRD 23 页、MRD 28 页），逐页读代价高。改为用口径关键词直接命中：

```
Grep pattern: "聚合|POC|实名|风险|举报|下架|后台|北极星|冷启动|漏斗|意向|P95"
```

一次扫出全部待改槽位，再按形状路径逐个 SearchReplace。

### 三、用几何尺寸做溢出审计，而不是文本长度比

原有工具 `cmp_len.py` 的判定规则是「新文本长度 > 旧文本 × 1.4 且差值 ≥5」。它有两个失效场景：

- **对模板占位符失真**：模板原文可能是「标题」这类 2 字占位符，任何正常文案都会超 1.4 倍，报警全是噪音；
- **覆盖不全**：它的两个 probe 报告路径写死在 `main()` 里，只覆盖 MRD。

替代方案是按形状的真实几何尺寸估算容量，见 [check_fit.py](file:///d:/developer/code/aicoding/s2s/docs/check_fit.py#L62-L83)：

```python
# 中文全角字符宽约等于字号，英文数字约 0.55 倍，按混排折算平均宽
han = sum(1 for c in text if ord(c) > 0x2E80)
other = len(text) - han
avg_w = (han * 1.0 + other * 0.55) / max(len(text), 1)
char_w_emu = size * avg_w * EMU_PER_PT
line_h_emu = size * 1.25 * EMU_PER_PT
usable_w = shp.width - Emu(91440) * 2      # 框宽减左右内边距
usable_h = shp.height - Emu(45720) * 2     # 框高减上下内边距
per_line = max(int(usable_w / char_w_emu), 1)
need_lines = -(-len(text) // per_line)     # 向上取整
cap_lines = max(int(usable_h / line_h_emu), 1)
if need_lines > cap_lines:
    ...  # 报溢出
```

**关键一步是先跑一遍模板本身建立容差基线**。本项目模板自身就有 9 处 `need=2 / cap=1`（2026-08-23 的运行时观测值，非可复现常量，换模板须重测），说明这类形状依赖 PowerPoint 的自动缩放，属设计容差而非缺陷。因此实际处置门槛定为 `need ≥ 3`，只精简真正超出的 6 处，避免把模板固有特征当 bug 追。

### 四、交付件验证必须提取文件内文本

时间戳与文件大小不构成证据。可信做法是提取交付件内的实际文本，逐条核对本轮改写过的**原句片段**：

```python
def pptx_text(path):
    """提取 pptx 全文（递归展开 Group）。"""
    prs = Presentation(path)
    parts = []

    def walk(shapes):
        for shp in shapes:
            if shp.shape_type is not None and str(shp.shape_type).startswith("GROUP"):
                walk(shp.shapes)   # Group 内的文本必须递归，否则大量漏检
                continue
            if shp.has_text_frame:
                parts.append(shp.text_frame.text)

    for slide in prs.slides:
        walk(slide.shapes)
    return "\n".join(parts)
```

见 [verify_pptx_edits.py](file:///d:/developer/code/aicoding/s2s/docs/verify_pptx_edits.py)（上面片段的行内注释为讲解后加，源码无此注释），本次核对 26 项特征句（BRD 13 + MRD 13）全部命中，这才是可以拿给用户看的证据。

docx 侧目前没有等价的固化工具（`verify_prd_docx.py` 验的是规格清单而非本轮改写原句），临时探针照同一思路写即可 —— 注意**段落与表格单元格都要收**，否则落在表里的内容会漏检：

```python
from docx import Document

doc = Document(r"docs\找鸭找-产品需求文档-v2.1.docx")
text = "\n".join(p.text for p in doc.paragraphs)
for t in doc.tables:
    for row in t.rows:
        for c in row.cells:
            text += "\n" + c.text

for k in ["第十部分：工程契约", "12. 接口需求", "completeness_conditions",
          "Idempotency-Key", "publish_memory", "audit_log", "NFR 验收清单"]:
    print(f"[{'OK ' if k in text else 'MISS'}] {k}")
```

**探针要正反成对：新内容要命中，旧标题要消失。** 只验「新内容在不在」会被「新旧并存」骗过。8/24 那次把旧标题「第十部分：附录」作为反向探针，修复后确认它已 GONE，才能证明章节编号顺推也一起落盘了，而不是新章追加在旧结构后面。

**特征句要用改写后的原句片段，不要用通用词表。** 我中途试过用 `["POC", "Flutter", "基线", "举报率"]` 这类通用词表跨三份文档扫描，结论不可用：MRD 是市场文档，本就不该出现 `Flutter`，报 MISS 是正常的；PRD 里的「举报率」实际出现在「不使用举报率作为信誉信号」这句正向红线里，报 BAD 是误判。通用词表无法区分「该出现」与「不该出现」，只有原句片段可以。

**「用原句」还要再收紧一层：原句必须逐字复制，含行内 Markdown 标记。** 8/24 那次 13/14 命中，唯一 FAIL 是我把特征句写成剥离星号的 `本部分不新增任何产品需求`，而权威源 [PRD.md L2035](file:///d:/developer/code/aicoding/s2s/docs/PRD.md#L2035) 实际是 `本部分**不新增任何产品需求**`，MD 驱动型脚本原样渲染进 docx，字符串比对当然不命中。逐段打印 `doc.paragraphs` 后确认内容其实完整落盘 —— 这是**探针缺陷而非文档缺陷**。

**探针 FAIL 时先怀疑探针。** 一次假 FAIL 会让人开始忽略整份报告；把「文档缺陷」与「探针缺陷」明确区分并写清结论，报告才有长期可用性。辨别方式就是逐段打印实际落盘文本，而不是继续调整探针直到变绿。

## Why This Matters

- **内容源假设错误会导致静默失败**：改了 MD、脚本跑成功、文件时间戳更新，一切看起来正常，但交付件内容根本没变。这类失败不报错，只能靠验证发现。
- **漏掉重跑同样是静默失败，且代价可能更大**：内容源假设错误至少还有「脚本跑过」这个动作，漏掉重跑连动作都没有。8/24 那次整章缺失，两个文件各自合法、无任何工具报错，唯一检出手段是主动做源–派生比对。当时的交付窗口是 8/25 的软著登记材料，漏出去的后果不是返工，是提交了一份与权威源不符的登记材料。
- **一次追问顶不了下一次**：那次是用户恰好问了才查出来。把「重跑 + 改名 + 提取全文核对」固化成流程的价值，就在于不再依赖有人想起来问。
- **PPTX 正文体量远小于 MD**，本项目 BRD.pptx 全文仅 2712 字、MRD.pptx 2976 字，而 MD 是几百行。同样的改动在 MD 里视觉显著，在 PPTX 里只是几个短句被替换，肉眼比对极易误判为"没改"。这正是用户产生质疑的根因，也是必须有脚本化证据的理由。
- **版式约束需要可执行的闸门**。"不允许文字重叠"若只靠人眼翻页检查，页数一多必然漏检；几何估算把它变成可重复执行的检查。
- **闸门自身也会过期**。写死结构清单的闸门在文档长出新章节后会给出全绿的假安心，比没有闸门更危险 —— 没闸门时人还会手动查。
- **描述闸门的文字也会过期**。本篇初版沿用了留档里的「四段闸门」，回代码点才发现是五段；「MD 改动 40 处」也串到了另一批次的数字上。**关于工具的可数事实（段数、条目数、覆盖范围）必须回代码数，不能沿用任何留档转述** —— 否则经验文档自己就成了错误口径的传播链。

## When to Apply

- 修改任何由脚本生成的 pptx / docx 交付件之前 —— 先确认该脚本的内容源类型
- 一处口径变更需要同步到多个格式的交付件时
- 权威源 MD 发生**结构级**变更之后 —— 新增或删除整章、章节编号顺推、大段搬移。这类变更比改几个词更容易在派生件里留下整块空洞，且必须连带检查闸门脚本的规格清单是否需要扩容
- 任何交付件即将对外提交之前（评审、客户、软著登记、备案），无论感觉上「应该已经同步了」
- 有人问「这两个同步了吗」的时候 —— 正确的回答形式是一份命中/未命中清单，不是一句「时间戳看起来是新的」
- 需要向他人证明"交付件确实已更新"时
- 交付件受版式约束（固定模板、不可溢出），且页数多到无法逐页目检时

## Examples

**反例（本次踩到的）**：

```
1. 改 BRD.md / MRD.md 共 26 处口径
2. 跑 gen_brd_pptx.py / gen_mrd_pptx.py
3. 交付件时间戳已更新 → 判定完成
   ✗ 实际 PPTX 内容零变化，脚本从不读 MD
```

**正例**：

```
1. Grep 生成脚本确认内容源类型（MD 驱动 / 硬编码）
2. MD 驱动型改 MD；硬编码型用口径关键词定位槽位后改脚本文案
3. 重生交付件
4. 先对模板跑 check_fit.py 建立容差基线，再对交付件跑，只处置超基线项
5. 用 verify_pptx_edits.py 按改写原句核对落盘，得到 "命中 26/26"
   ✓ 有可复现的证据链
```

**反例二（2026-08-24，MD 驱动型这一路）**：

```
1. PRD.md 新增第十部分「工程契约」约 420 行（13:04），附录顺推为第十一部分
2. 派生 docx 仍是前一天 19:26 生成，无人重跑脚本
3. 若只看「MD 已更新、交付件存在、传导图标着改 MD 即可」→ 判定可交付
   ✗ 提取全文核对 12 项特征 → 命中 0/12，整章缺失
   ✗ 旧标题「第十部分：附录」仍在，连编号顺推都没落盘
   ✗ 五段闸门此时若跑，因清单止于 §11，整章缺失一条都报不出来
```

**正例二（修复与验证）**：

```
1. Grep 确认 gen_prd_v2.1_docx.py 为 MD 驱动型（main() 直读 PRD.md）
2. 确认无 WINWORD 进程；辨明 ~$*.pptx 锁文件与 docx 无关
3. $env:PYTHONUTF8=1；python docs\gen_prd_v2.1_docx.py
4. Move-Item -Force 把 ..._tmp.docx 改名为正式交付件名（这一步不能省）
5. 提取全文复核：129,890 字节 / 全文 93,831 字 / 28 条目录项（原 24 条）
   正向特征 13/14 命中；反向探针「第十部分：附录」= GONE
   唯一 FAIL 经逐段打印确认为探针剥离 Markdown 星号所致，非文档缺陷
   ✓ 有可复现的证据链
```

**顺带修掉的连带问题**：交叉核验时用 PRD 全文扫描，发现权威源自身残留 2 处旧口径（§4.7 与 §9.10 的边界表仍写「举报率触发复核」「误报不计入举报率」）。**权威源也要接受同一套核验** —— 传导前先验证权威源自洽，否则会把残留口径一路传导下去。

## Related

- 进度与决策留档：[说明文档.md](file:///d:/developer/code/aicoding/s2s/说明文档.md) 记录 [20]（本篇原始来源）、[35]（8/24 的 MD 驱动型滞后事故）
- 同域姊妹篇：[cross-document-reference-verification.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/cross-document-reference-verification.md) —— 那篇管权威源**内部**的跨章节引用与口径搬运核验（§12–§14 写入 PRD 时的教训），本篇管权威源**到派生交付件**的传导与新鲜度。两篇是同一次变更的前半段与后半段，共用一条原则：以权威源原文为准逐条对账，不凭记忆或印象。
- 溢出审计工具：[check_fit.py](file:///d:/developer/code/aicoding/s2s/docs/check_fit.py)
- 落盘验证工具：[verify_pptx_edits.py](file:///d:/developer/code/aicoding/s2s/docs/verify_pptx_edits.py)（PPTX 侧已固化；docx 侧尚无等价工具，目前用临时探针）
- 本篇的下游产物：[verify_brd_v22.py](file:///d:/developer/code/aicoding/s2s/docs/verify_brd_v22.py) 的文件头写明「设计依据」是本篇，并同时校验 pptx 与 md 两侧 —— 可作为把本篇原则固化成脚本的参考样式
- PRD 闸门校验：[verify_prd_docx.py](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py) —— **待扩容**：章节清单止于 §11，不含 §12–§14（「替换/替代」禁用词过宽一项已于 2026-09-02 收窄为带版本语境组合，见正文「一之二」）
- 被替代的长度比工具：[cmp_len.py](file:///d:/developer/code/aicoding/s2s/docs/cmp_len.py)（仅覆盖 MRD，规则对模板失真）
