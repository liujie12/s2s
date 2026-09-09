---
title: 视觉参数决策的评审载体与守门人：大尺寸预览会掩盖小尺寸缺陷
date: 2026-08-26
category: workflow-issues
module: prototype-figma
problem_type: workflow_issue
component: frontend
severity: high
root_cause: missing_validation
resolution_type: workflow_improvement
applies_when:
  - 需要用户拍板一个连续视觉参数（占比、间距、字重、圆角）
  - 该参数的产物有一个明确的实际渲染尺寸，且远小于预览时的舒适尺寸
  - 参数由生成脚本产出、并有探针或闸门做机器校验
  - 用户用观感词描述需求（更好看、更醒目、太挤），需要翻译成可调参数
  - 抬高某个参数前，需要判断它的上限由什么决定
tags: [design-token, icon-geometry, review-artifact, verification-gate, svg, figma-plugin, opencv]
---

# 视觉参数决策的评审载体与守门人：大尺寸预览会掩盖小尺寸缺陷

## Context

底部 Tab 中键的「发布」按钮是一枚 **24px** 图标：主色圆盘 + 白色鸭头 + 主色眼点。用户看了预览页后说「中间发布按钮，我觉得这种镂空的更好看，如截图，改一下把」，截图指向页内一段带 24px / 48px / 96px 三格的对照区。

这一轮踩了三个坑，全部与「怎么问、怎么量」有关，而不是与画得对不对有关：

| 坑 | 表现 | 危险程度 |
|---|---|---|
| 按字面执行用户的观感描述 | 差点把一个已经正确的结构推倒重做 | 中 —— 白做，但能发现 |
| **评审载体带了产品里不存在的尺寸** | 48/96px 观感良好，掩盖了 24px 的缺陷；我推荐、用户选择，两边都看走眼 | **高 —— 决策本身是错的，且双方都签过字** |
| **守门人没有守住真正的约束** | 全部断言都在测笔画粗细，没有一条在测环带宽度 | **高 —— 参数被抬到破形的档位，探针仍全绿** |

## Guidance

### 一、用户描述的是观感，不是实现 —— 先去真源确认现状

「镂空的更好看」听起来是要换绘制手法。查证 [code.js](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L640-L664) 与真源 SVG 后发现：**现行版与截图那版手法完全相同** —— 都是「主色圆盘 + 白鸭头 + 主色眼点」（白鸭头是显式染成 `color/surface` 而非留空透底，因为前景层的镂空透出的是底色，形状会消失）。截图那版唯一的差别是白盘只占画板 44%，视觉上鸭头相对更满。

所以用户要的不是「换手法」，而是「鸭头再大些」，落成一个参数：[build_mini_symbol()](file:///d:/developer/code/aicoding/s2s/prototype-figma/build-4b-assets.py#L144) 的 `ratio`。

**顺带推翻了一个想当然**。我原打算据此宣布「现状已经是镂空、无需改动」。为稳妥起见还是实测了「evenodd 真挖空」与「叠白鸭头染色」两种实现的逐像素差异，结果 IoU 只有 0.9863（ratio 0.72）/ 0.9871（0.88），差 1787 / 2118 像素，来自圆盘弧线与鸭头轮廓交界的抗锯齿。虽然不影响观感结论，但**「不实测就宣布两种实现等价」这个动作本身是错的**。

### 二、评审载体的尺寸必须等于实际使用尺寸

首版对照图并列 24 / 48 / 96px 三格。88% 档在 48/96px 下观感相当好 —— 我据此推荐 88%，用户据此选了 88%。**大尺寸格给了用户一个在真实场景里不存在的判断依据。**

修法是把对照图收窄到只有实际使用尺寸，见 [sheet_24()](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-mini-negative.py#L149)：

```python
# 只渲染 24px，放大用 INTER_NEAREST，看真实像素而非插值出来的想象
big = cv2.resize(img, (24 * zoom, 24 * zoom), interpolation=cv2.INTER_NEAREST)
```

两条硬规则：

- **只渲染产品里真实存在的尺寸**，一档都不多给；
- **放大只允许 `INTER_NEAREST`**。平滑插值会把断裂的 1px 环带补成连续的灰边，等于用插值算法替用户做了决策。

换成 24px 单档对照图后，84% / 88% 两格的喙尖捅破圆盘、主色环断开，肉眼当即可见。

### 三、约束要找对那个先崩的

我第一轮只测了一个指标：24px 下鸭头笔画的最大内切圆直径。88% 时它是 10.38px，**看着极其安全**，于是推荐了 88%。

漏掉的是**主色环带宽度** —— 鸭头最远点到圆盘边缘的余量。环带是「这是一枚按钮」的体量感载体，24px 下不足 1px 就会断续。补 [head_clearance()](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-mini-negative.py#L122) 逐档实测后：

| ratio | 环带占画板 | 24px 折算 | 鸭头占圆盘半径 | 判定 |
|---|---|---|---|---|
| 0.72 | 0.121 | 2.92px | 0.753 | OK |
| 0.76 | 0.101 | 2.43px | 0.795 | OK |
| **0.80** | **0.079** | **1.90px** | **0.839** | **OK（上限，采用）** |
| 0.84 | 0.059 | 1.42px | 0.880 | WARN |
| 0.88 | 0.039 | 0.93px | 0.922 | WARN（喙尖已捅破圆盘） |
| 0.96 | 0.003 | 0.06px | 0.995 | WARN |

同一个参数往上抬时，**最先崩的往往不是最显眼的那个指标**。笔画还有 10px 的时候环带只剩 0.93px 已经断了。

**只看 span 比例不够。** 鸭头是有机形，长边铺到 88% 时对角方向可能已经顶到圆盘弧线。可靠做法是求「白鸭头像素到圆心的最大距离」再与圆盘半径相比，而不是量包围盒：

```python
r_disc = (0.5 - 0.0078) * px
d = np.sqrt((xs - c) ** 2 + (ys - c) ** 2)
inside = d <= r_disc * 0.995     # 排除圆盘外透明区被渲染成白的像素
band = (r_disc - d[inside].max()) / px
```

`inside` 这一步不能省 —— 圆盘之外是透明区，渲染器把透明画成白，不排除的话量出来的永远是满画板。

### 四、放宽过期断言时，必须把真正的约束一起补上

改完 `ratio` 后探针报 `mini head spans ~72% of canvas [0.799]`。这次确实属于「断言的基准值过期」（我改了 `ratio` 却没改它），是该放宽的情形。但**只改数字就等于白挨这一刀**：原来的断言体系里没有任何一条在守环带，下一个人再抬 `ratio` 会重犯同一个错。

所以是两处改动，见 [probe-assets-verify.py](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-assets-verify.py#L138-L163)：

```python
check("mini head spans ~80% of canvas", 0.76 <= span <= 0.84, f"{span:.3f}")
# 上一轮只测了笔画粗细没测这里，才误判 88% 可行，故固化成守门人
check("mini@24px brand ring >= 1.5px", band_px_24 >= 1.5, f"{band_px_24:.2f}px")
```

新断言实测 1.92px，与独立探针 [probe-mini-negative.py](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-mini-negative.py) 算出的 1.90px 互相印证 —— 两套独立实现算出同一个数，这本身就是「测量方法没错」的证据。断言注释里写明了「本轮为什么会漏掉它」，而不只是写它在测什么。

### 五、连带项要顺着依赖链走一遍

`ratio` 是一个上游参数，抬它会连带改动四处，漏一处就出现「真源与副本脱钩」：

1. 生成脚本默认值（[build-4b-assets.py:144](file:///d:/developer/code/aicoding/s2s/prototype-figma/build-4b-assets.py#L144)），docstring 同步记录逐档实测数据与「上限由环带而非笔画决定」；
2. 重生成全部 12 个 SVG 真源；
3. 消费侧的内联副本 —— Figma 插件沙箱读不到文件，[code.js:660-664](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L660-L664) 必须存一份逐字相同的路径与眼点常量，由一致性探针守住；
4. **代码注释里的数字也是副本**。`code.js` 上方仍写着「缩放到占画板 72%」，`Grep "72%|0\.72"` 才扫出来。

一个连带项是自然消解的：眼点半径随鸭头同一变换放大到 45.37（24px 下 2.13px），已自然超过 2px 底线，[EYE_R_MINI_FLOOR](file:///d:/developer/code/aicoding/s2s/prototype-figma/build-4b-assets.py#L37) 这个下限保护不再生效 —— 保护失效要写进注释，否则下次有人以为它还在起作用。

回归结果：assets 校验 32/32、真源与副本一致性 16/16、Tab 栏渲染 12/12。本轮改动截至撰写时尚未提交。

## Why This Matters

- **错误的评审载体产出的是「双方都签过字的错误决策」**，比单方失误难纠正得多。用户选了 88%，我推荐了 88%，两边都有据可依 —— 唯一的错误在于那个「据」里混进了产品中不存在的尺寸。这类错误不会被任何探针发现，因为探针测的是产物，而缺陷在提问方式里。
- **测一个不会先崩的指标，等于没测**。笔画粗细在 88% 时余量 5 倍以上，环带同时已经断裂。守门人守着一条永远不会触发的线时，它给出的是假安心 —— 与「闸门覆盖面不会自己长」是同一类失效，只是这次是从一开始就没覆盖对，而不是随时间失效。
- **按字面执行观感描述的成本是重做一遍已经正确的东西**。「镂空」在实现层压根不是镂空。先回真源确认现状，再把观感翻译成可调参数，比重画一遍省得多，也避免推倒一个结构上正确的实现。
- **放宽断言是一个高风险动作**，因为它总是发生在「我刚改完、我确信是对的」这个心态下。要求同时补上真正的约束，是给这个动作加一道成本，让它不能被轻易执行。

## When to Apply

- 任何需要用户拍板视觉参数的场合 —— 造对照页之前先问「产品里这东西实际多大」，只渲染那个尺寸
- 抬高任何参数之前 —— 先列出它会挤压哪几个量，把最先崩的那个测出来，而不是只测最显眼的
- 用户用观感词提需求时 —— 先读真源确认现状，把需求翻译成参数，再决定要不要动手
- 探针失败时 —— 先判断它拦对了没有；确认是基准值过期后，同一次改动里必须补上原本缺失的约束
- 改动上游参数后 —— 顺依赖链走一遍：生成脚本 → 真源 → 内联副本 → 注释里的数字 → 因参数变化而失效的保护逻辑
- 宣布「两种实现等价、无需改动」之前 —— 实测一次，IoU 不到 1.0 就说明不等价

## Examples

**反例（本轮踩到的）**：

```
1. 用户说「镂空的更好看」→ 准备改绘制手法
2. 造对照图，并列 24/48/96px 三档
3. 只测 24px 下笔画粗细：88% 档 10.38px，达标 → 推荐 88%
4. 用户看 48/96px 格观感良好 → 选定 88%
   ✗ 88% 时主色环带仅 0.93px，喙尖已捅破圆盘边缘
   ✗ 缺陷只在 24px 可见，而对照图里 24px 那格被另两格的观感盖住了
   ✗ 全部既有断言仍会通过 —— 没有一条在测环带
```

**正例**：

```
1. 读 code.js 与真源 → 查明现行手法与截图相同，需求实为「鸭头更大」→ 落成 ratio
2. 实测「真挖空 vs 叠白鸭头」IoU=0.9863，不等价 → 不宣布无需改动
3. 逐档扫描 0.72~0.96，同时测笔画与环带 → 环带先崩，达标上限 0.80
4. 对照图改为只渲染 24px，INTER_NEAREST 放大 12 倍 → 84%/88% 破形肉眼可见
5. 重新提问 → 用户定 80%
6. 顺依赖链改四处：生成脚本 → 12 个真源 → code.js 内联副本 → 注释里的 72%
7. 断言基准改 80%，同时新增「24px 下环带 >= 1.5px」→ 实测 1.92px，
   与独立探针的 1.90px 互相印证
8. 回归 32/32 + 16/16 + 12/12
   ✓ 决策有 24px 实拍证据，约束有守门人，双份副本有一致性探针
```

## Related

- 进度与决策留档：[说明文档.md](file:///d:/developer/code/aicoding/s2s/说明文档.md) 条目 [47] 与 [47-b]（本篇原始来源），沉淀原则 ㉚–㉜
- 规格权威源：[PRD.md](file:///d:/developer/code/aicoding/s2s/docs/PRD.md) §1.4.1.2 档位降级规则、§1.4.1.3 几何与绘制基准（已登记「24px 下主色环带 ≥ 1.5px」硬约束）
- 决策探针：[probe-mini-negative.py](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-mini-negative.py) —— 逐档扫描与 24px 单档对照图的生成者
- 守门人：[probe-assets-verify.py](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-assets-verify.py) 素材几何校验、`probe-duck-inline.py` 真源与内联副本一致性、`probe-tabbar-verify.py` Tab 栏渲染
- 同域姊妹篇：[multi-format-deliverable-consistency.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/multi-format-deliverable-consistency.md) —— 那篇的「闸门自身也会过期」讲闸门随文档增长而失效，本篇讲闸门**从一开始就没覆盖对约束**；两篇共用「守门人的红灯必须与真实风险挂钩」这条原则
- 同域姊妹篇：[cross-document-reference-verification.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/cross-document-reference-verification.md) —— 那篇的「探针 FAIL 时先怀疑探针」与本篇第四节互为正反两面：那次是探针错了，这次是探针的基准值过期而它守的东西本身缺失
