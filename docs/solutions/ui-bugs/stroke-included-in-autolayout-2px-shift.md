---
title: Figma Auto Layout 默认把描边计入布局：1px 描边造成 2px 高度差与横排底线错位
date: 2026-09-02
category: ui-bugs
module: prototype-figma
problem_type: ui_bug
component: frontend
symptoms:
  - 次要按钮比同排的幽灵按钮高 2px，横排容器里两键顶对齐、底部不齐
  - 卡片选中态高 78 而正常态与下架态均为 76，列表里某张卡被选中后整列下移 2px
  - 规格表写明「其余一切不变」，实际加了描边就变了尺寸
  - 离线探针全绿，缺陷只在实机核验读取真实几何时才暴露
root_cause: wrong_api
resolution_type: code_fix
severity: medium
framework_version: figma plugin api (2026-09)
tags: [figma-plugin, auto-layout, stroke, layout-shift, design-system, css-outline]
---

# Figma Auto Layout 默认把描边计入布局：1px 描边造成 2px 高度差与横排底线错位

## Problem

Figma 的 Auto Layout 容器上 `strokesIncludedInLayout` **默认为 `true`**，于是一道 1px INSIDE 描边会把内容框上下各挤 1px，使容器实际高度比同规格的无描边容器多 2px。项目里两个组件因此走形：只有「带描边的那一档」变高，而规格表写的是「加边框，其余一切不变」。

## Symptoms

| 受害组件 | 带描边档实测高 | 同规格其余档 | 用户可见后果 |
|---|---|---|---|
| `btn/secondary` | 47 | 45（另五个变体） | **5 处横排容器里两键顶对齐、底部差 2px** |
| `card/*` 选中态 | 78 | 76（正常态 / 下架态） | 列表里某张卡被选中，整列往下错 2px，像列表在抖 |

按钮的 5 处实处全部核过：[_pub-actions](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L6474-L6477) 在「我的发布」页出现 4 次（`items` 数组 4 条各一个：编辑/下架 ×2、刷新重发/删除、继续编辑/删除），加发布完成页的 [_actions](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L6905-L6907)（去首页看效果 / 我的发布）。这些容器都是 `align: MIN`（顶对齐），所以 2px 的高度差直接表现为底边不齐。

**2px 在单个组件上看不出来。** 它成为可见缺陷的条件是「同规格的两个实例相邻」—— 按钮是横排相邻，卡片是列表纵向相邻。

## What Didn't Work

- **离线探针查不出**。5616 行、310 条断言全绿。mock 不模拟描边对几何的挤压，它算出的高度只跟 padding 与行高有关，所以「描边让容器变高」这个物理事实在离线侧根本不存在。
- **读源码也查不出**。源码里 `stroke` 与 `strokeWeight` 都写对了，规格表也写对了。缺陷在一个**没有被显式赋值的属性的默认值**里 —— 代码里根本没有那一行可读。
- **只修 selected 一档是不够的**。首次修复只改了卡片，因为卡片是实机核验时先看到的那个。扩大扫描后才发现按钮一族也中招，而按钮的危害更大（横排相邻，肉眼可见）。

## Solution

### 根源：通用构造器只设了描边、没设描边的布局语义

[box()](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L1254-L1257) 是全稿容器的唯一构造器，它的描边分支是：

```javascript
if (opt.stroke) {
  f.strokes = [paintOf(opt.stroke)];
  f.strokeWeight = opt.strokeWeight || 1;
}
```

设了「描边长什么样」，没设「描边算不算尺寸」—— 后者留在 Figma 的默认值 `true` 上。

### 修法一：按钮构造器里无条件设 false

见 [buttonRaw()](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L2136-L2148)：

```javascript
b.strokesIncludedInLayout = false;
```

**无条件设，而不是只对 secondary 设。** [六个变体](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L629)（primary / secondary / ghost / danger / capsule / disabled）共用同一个构造器，将来任何变体加描边都会立刻踩同一个坑，条件判断只会漏。

### 修法二：卡片按档设

见 [card()](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L2560-L2566)：

```javascript
if (stateKey === 'selected') c.strokesIncludedInLayout = false;
```

这里**按档设是有理由的**，与按钮的处理相反：卡片三档中只有 selected 有描边，另两档设它等于写一个无意义的属性。而按钮六变体是一个开放集合（随时可能加 outline 变体），所以要无条件兜住。**判断依据是「这个集合会不会长出新的带描边成员」，不是「现在有几个成员带描边」。**

### 修法三：把跨端口径写进规格真源

这个坑不是 Figma 独有的 —— CSS 的 `border` 同样占据盒模型尺寸。若实现侧照「加 1px 边框」直译成 `border: 1px solid`，浏览器里会复现完全相同的 2px 位移。

故把口径写进 [CARD_STATES.selected.spec](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L186-L188)，并随生成器传导到 [设计系统与组件规范.md](file:///d:/developer/code/aicoding/s2s/docs/设计系统与组件规范.md#L198)：

> 硬约束：边框不得占据布局尺寸 —— Figma 侧须设 `strokesIncludedInLayout = false`，CSS 侧须用 `outline` 或 `box-shadow` 描边而非 `border`

**规格必须给出两侧的做法。** 只写 Figma 侧那半句，实现的人看到的是一条与自己无关的插件配置。

## Why This Works

`strokesIncludedInLayout = false` 让描边脱离 Auto Layout 的尺寸计算，容器高度只由 padding 与内容决定，于是带描边档与无描边档回到同一高度。描边本身照旧渲染，只是不再参与排版。

CSS 侧 `outline` 与 `box-shadow` 之所以等效，是因为二者都不参与盒模型尺寸计算 —— 与 `border` 的区别正是这一点。

## Prevention

### 一、这类缺陷只有实机核验能查出，所以出图通道要早通

离线 mock 不模拟渲染引擎的物理行为（描边挤压、字体度量、光栅化），凡是「引擎默认行为」类的缺陷都只在实机现形。本项目直到第 6 天才打通出图通道，这个缺陷因此在稿子里躺了很久 —— 见 [visual-feedback-loop-latency.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/visual-feedback-loop-latency.md)。

### 二、离线侧仍要补断言，但要诚实标注它测的是什么

离线探针测不出那 2px，但能拦住「有人把这行删掉」。所以断言核的是**属性值**而非高度差，且注释里写明这一点，见 [probe-layout-offline.js](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js#L3520-L3538)：

```javascript
// 本 mock 不模拟描边挤压几何，故只能核 strokesIncludedInLayout 的
// 属性值 —— 那 2px 是实机量出来的，此处只负责拦住「有人把这行删掉」。
const btnStrokeBad = [];
for (const v of M.BUTTON_VARIANTS) {
  const node = cache['ui/button/' + v];
  if (!node) { btnStrokeBad.push(v + ':master 缺失'); continue; }
  if (node.strokesIncludedInLayout !== false) {
    btnStrokeBad.push(v + ':strokesIncludedInLayout=' + node.strokesIncludedInLayout);
  }
}
```

**遍历真源变体表而非逐个点名**，这样新增变体自动纳入检查。卡片侧同理，见 [同文件 :4328-4336](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js#L4328-L4336)。

不写明「测的是属性值不是高度」会有后患：下一个人以为这条断言守住了高度，于是不再做实机核验。

### 三、mock 的属性搬运漏一个就是一条假信号

新断言首跑报「六个变体全 `true`」的**假红** —— 源码明明设对了。根因是 mock 里 `createComponentFromNode` 是**逐属性手抄搬运**的，漏抄了这一个，Frame 上设的值到不了 master。见 [probe-layout-offline.js:509-515](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js#L509-L515)：

```javascript
// 描边与「描边是否计入布局」也要搬（2026-09-02 补，第三次踩逐属性搬运的坑）：
// 漏了它，Frame 上设的 strokesIncludedInLayout = false 到不了 master，
// 「六类按钮等高」那条断言会对着 mock 默认 true 报红 —— 而源码明明设对了。
// 这类假红比假绿好，但仍是探针在测自己造出来的东西。
c.strokes = node.strokes;
c.strokeWeight = node.strokeWeight;
c.strokesIncludedInLayout = node.strokesIncludedInLayout;
```

这是同一个 mock 上第三次栽在逐属性搬运（前两次漏 `textAlignHorizontal`）。**这次靠假红引出是运气** —— 只要 mock 的默认值方向反过来（默认 `false`），同一个漏抄就会表现为假绿，缺陷会被探针背书为「已修复」。

结构性的解法是把搬运改成属性白名单驱动，而非手抄清单；这项尚未做。

### 四、检索同类风险时按「属性组合」而非按症状扫

扫描判据用的是「带描边 + Auto Layout + 该轴 AUTO + `strokesIncludedInLayout` 非 false」，命中 110 处。逐类核后只有按钮一族是真受害者，其余刻意不动：

| 类别 | 数量 | 不动的理由 |
|---|---|---|
| `row/*` | 16 | 彼此同高，无对照物，2px 无处可比 |
| `_annotation/*` | 50 | 标注框不上产品画面 |
| 其余（`_sheet-reset` 等） | 28 | 逐个核过，同名同高、无对照 |

**「无对照物」是这个缺陷不成立的唯一条件**，所以判断某处要不要修，看的是「附近有没有同规格的无描边兄弟」，不是「它有没有描边」。

## Related Issues

- [visual-feedback-loop-latency.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/visual-feedback-loop-latency.md) —— 本缺陷是「越晚出图越贵」的实例；其中第五条讲离线 mock 与实机的数字不可互换
- [design-parameter-review-and-gating.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/design-parameter-review-and-gating.md) —— 「守门人没守住真正的约束」，与本文 Prevention 第二、四条同源
- [CONCEPTS.md](file:///d:/developer/code/aicoding/s2s/CONCEPTS.md) —— 「实机核验」「守门型探针」的定义
