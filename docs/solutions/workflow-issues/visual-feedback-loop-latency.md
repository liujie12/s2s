---
title: 视觉稿的返工量正比于「无反馈期」长度：出图通道与守门探针都要在第一天就位
date: 2026-09-02
category: workflow-issues
module: prototype-figma
problem_type: workflow_issue
component: frontend
severity: high
root_cause: missing_workflow_step
resolution_type: workflow_improvement
applies_when:
  - 用代码生成视觉稿（Figma 插件、SVG 生成器、图表脚本），产物只能靠渲染图核验
  - 项目周期超过两三天，且渲染通道依赖外部工具（插件桥、云端 REST、无头浏览器）
  - 打算「先把页面全写完，再统一出图验收」
  - 需要判断一批机器断言该在什么时候写、写到什么粒度
  - 复盘一个耗时远超预期的实现阶段，想定位时间花在哪里
tags: [figma-plugin, feedback-loop, verification-gate, rework-cost, offline-probe, design-review]
---

# 视觉稿的返工量正比于「无反馈期」长度：出图通道与守门探针都要在第一天就位

## Context

原型稿从 8/25 到 9/2 共 9 天、67 次提交。实测口径（`git log --since=2026-08-25`）：

| 指标 | 实测值 |
|---|---|
| 提交总数 | 67 |
| 提交信息含「修 / 补 / 纠 / 撤」 | **31（46%）** |
| [code.js](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js) | 7340 行，被改 36 次 |
| [probe-layout-offline.js](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js) | 5616 行 / 310 条断言，被改 **33 次** |
| 提交密度峰值 | 08-27 共 17 次；09-01、09-02 各 11 次 |

近一半提交是修自己刚写的东西，守门探针的改动次数与产品代码近乎一比一。

**耗时的根因不是需求变更，也不是代码量，而是「出图 → 挖缺陷 → 补断言」这个回路启动得太晚。** 两条提交信息自证：

```
fix(figma): 四模态首次出图挖出五处缺陷并修复，探针升至 252 项
fix(figma): 24 个变体框首次逐张出图挖出四处缺陷并修复，探针升至 256 项
```

「**首次**出图」出现在第 6–7 天。而 8/30–8/31 两天里断言数链式增长 `200→220→227→237→239→246→248→249→252→256`，每一步背后都是一次出图挖出的缺陷。前 5 天在没有任何视觉反馈的情况下堆了几千行生成代码 —— 那段时间写下的缺陷，全部在第 6 天以后集中付账。

## Guidance

### 一、第一天先打通出图通道，再写第二行生成代码

本项目的插件截图通道（`figma_capture_screenshot` / `exportAsync`）在这台机器上是**挂死**的 —— Promise 永不 resolve，根因是 Figma Desktop 的 GPU 光栅化管线。可行的只有云端 REST 渲染一条路（`/v1/images/:key?ids=a,b,c&scale=2`，需 PAT，可批量）。

这个事实本可以在第 1 天用一个空白矩形试出来，实际到第 6 天才发现。代价不只是那半天排查 —— 是**前 5 天所有代码都是在「以后能出图」的假设下写的**。

判据很简单：**在画第一个真实组件之前，先让通道把一个 1×1 的空矩形导出成 PNG 落到磁盘上。** 通道不通就先解决通道，不要先攒画布。

### 二、「写一页 → 出一张图 → 定稿」，不要「写完二十页 → 统一出图」

批量出图的两个隐性成本：

1. **缺陷会互相掩盖**。50 张图一起看，注意力被摊薄，2px 的错位在缩略图里根本不成立为「缺陷」；
2. **修复要重跑全量**。本项目 Figma 侧的 [batchSetup()](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L3463) 开头就调 `resetPage()`，会删掉全部 master，所以**不存在「只重跑批次 1」这种局部修复** —— 每改一处，都得清空后按 1→2→3→4→5 全量重跑，且 Figma 同一时刻只运行一个插件，全程串行等待。本段共重跑 3 轮。

单页闭环把这两项成本都压到最小：一次只看一张图，一次只重跑一页。

### 三、探针要与画布同步生长，而不是画布写完再回头补 300 条

必须澄清一点：**310 条断言里的绝大多数不是浪费。** 按钮底线 2px 错位、卡片选中态被挤高 2px、弹层按钮破 44px 触控线 —— 这几类在小图上肉眼看不出来，只有断言能守住。

问题在**时序**：断言是在画布定稿后集中补的，于是每补一批就挖出一批已经写死在稿里的缺陷，而每个缺陷的修复又要走一遍第二条说的全量重跑。**同一条断言，写在画布之前只值几行代码；写在画布之后要额外付一次重跑与一次回改。**

### 四、每条断言写完就反向验一次

守门型探针的失效模式是**恒绿**，而恒绿与「真的没问题」在输出上完全一样。本段抓到的三类实例：

- **补完实现让断言空转**。那条「未出稿的档位必须如实声明」原体是 `if (st.inStock) continue`，只查 `false` 的档；三态补齐后 `inStock` 再无 `false`，循环空转、断言恒绿。改为逐档双向核对（有实处的档被误标「未出稿」同样报红）。
- **点名式判据覆盖不到新节点**。44px 触控断言原本是逐个点名（只查 `_tab-` 和 `_nav-bell`），所以两个手搓的弹层按钮从未进入检查范围，各出现 3 次、一个都没拦住。改为遍历 `btn/*` 全族加两个手搓件，整体排除 `_annotation/*` 子树，见 [probe-layout-offline.js](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js#L4483-L4498)。
- **豁免机制本身也要被守门**。豁免名在稿内已找不到（改名或删除）时，那条豁免就成了替一个不存在的节点永久开口子的僵尸条目。补了一条「豁免名单无僵尸条目」断言，反向验证方式是把豁免名改成 `_XX-reset`，确认它精准报红。

做法：**每写一条断言，就故意把被测对象改坏一次，确认它真的报红，再改回来。** 本项目把这类反向验证也固化成了断言（提示语前缀 `[反向]`），例如「去掉 `layoutGrow` 赋值后『贴底』判据确实触发」。

### 五、离线 mock 与实机是两套数字，都不许当成对方

离线探针跑在 mock 的 Figma API 上，实机跑在真 Figma 里。两边的行高算法不同：mock 按 `fontSize × 1.4` 估（small 12 → 17），真机 small 行高是 20。**两侧都没错，但混用会让断言在离线永远报红。**

所以豁免项要记两个值，见 [TOUCH_WAIVED](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js#L4477-L4480)：

```javascript
const TOUCH_WAIVED = {
  '_sheet-reset':   { at: 33, live: 36, why: '...已在规范 §11 声明，实现侧须补到 44' },
  '_sheet-confirm': { at: 33, live: 34, why: '...' }
};
```

`at` 是离线值、用于防回归；`live` 是实机值、写进给实现侧看的规范文档。当时若图省事去调低阈值或让这两个名字无条件跳过，就造出了一条永久免检的口子。

还有一类更隐蔽的：**mock 是逐属性手抄搬运的，漏抄一个属性就是一条假信号。** 本段栽了两次（克隆漏搬 `textAlignHorizontal`、`createComponentFromNode` 漏搬 `strokesIncludedInLayout`），都靠假红引出。假红是运气 —— 只要 mock 的默认值方向反过来，同一个漏抄就会表现为**假绿**。为此给 mock 的文本构造器补了显式默认值（[probe-layout-offline.js:401](file:///d:/developer/code/aicoding/s2s/prototype-figma/probe-layout-offline.js#L401) `t.textAlignHorizontal = 'LEFT'`）：`undefined` 会把「真的设成 LEFT」与「属性根本不存在」混为一谈。

### 六、一条永远报红的判据等于没有判据

[verify_prd_docx.py](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx.py#L102-L118) 把「替代」「替换」当**裸词**列入版本痕迹禁用词，导致五处正常技术用词（「唯一不可替代优势」「转曲后替换」「替换 map-bg.png」「替换配置」）全部误报。

**这种误报比漏报更坏**：闸门每次跑都亮两条红灯，下一个人无从区分「已知自伤」与「新出的真问题」，最终会把整段校验当噪音跳过。改为逐个列举带版本语境的组合（`替代 v2`、`替换旧`……）。

同类陷阱当场差点重犯一次：新写的源-派生比对脚本首版把「docx 的 mtime 早于 md」当**成败判据**，还原一个测试文件后立即假红 —— `mtime` 对 Git 检出、编辑器保存、脚本还原都敏感。已改为时间序只作提示、不参与退出码。

### 七、特征句必须从权威源逐字复制，且先验证它在源里存在

写源-派生比对探针时，三条特征句是我凭记忆写的，全错：

| 我写的 | 真相 |
|---|---|
| `Figma Variables` | PRD 里根本没这个词 |
| `24px 下必须可辨` | 原文是 `**24px** 下必须可辨` —— 跨 `**` 标记边界 |
| `44px 最小触控` | 原文是「按钮最小触控区 44×44 px」 |

第二条尤其阴险：**在 md 里匹配不上，却在 docx 里能匹配**（docx 提取的是纯文本，标记已被消化）。

固化的两条机制见 [verify_prd_docx_sync.py](file:///d:/developer/code/aicoding/s2s/docs/verify_prd_docx_sync.py#L13-L19)：比对前统一剥掉 `**` 与 `` ` ``；特征句一律**先在 md 侧验明存在**（报 `[脑补]`，要改清单）再查 docx（报 `[MISS]`，要重生 docx）。分开报是因为处置方式完全不同 —— 混为一谈时假 MISS 会淹没真 MISS。

「必须复制原句」这条此前只以记忆形式存在，明知却仍犯三次。**记忆挡不住的规则要变成脚本。**

### 八、交付目录必须是一键可重建的产物

`prototype-figma/assets/render/` 累计 216 个文件，其中只有 `r76-*` 那 50 张是当前版。手工拷出来的交付目录下一轮改稿后必然脱节，**而脱节了看不出来** —— 上一批渲染图过期两轮才被发现，成因正是这个。

故写了生成器 [build-delivery.js](file:///d:/developer/code/aicoding/s2s/prototype-figma/build-delivery.js)，自报 `created / updated / unchanged`，轮次前缀收成一个常量 `ROUND`。

其中一个缺陷只有在真跑失败一次才现形：首版是「先清空目录、再边拷边验」，校验失败时目录已被清空且只拷了一半，**下次跑又报 `created`，看不出上次是失败中断的**。改为 [planRenders()](file:///d:/developer/code/aicoding/s2s/prototype-figma/build-delivery.js#L95-L111) 先分组、先验完整性与文件存在性、全部通过后才动目录。

## Why This Matters

四个成本项按本段实际耗时排序：

| # | 成本项 | 本可避免的方式 |
|---|---|---|
| 1 | 出图通道坏了，第 6 天才发现 | 第 1 天导一个空矩形 |
| 2 | 每次修复要全量重跑，且插件串行 | 单页闭环，一次只重跑一页 |
| 3 | 探针自身缺陷制造假信号（3 假绿 + 3 假红） | 每条断言写完反向验一次 |
| 4 | 凭记忆断言事实（4 起） | 动手前先读真源；把规则写成脚本 |

第 1 项是乘数项 —— 它一晚发现一天，第 2、3 项的返工量就整体放大一天。**返工量与无反馈期的长度成正比，而不是与代码量成正比。**

## When to Apply

- 任何「代码生成视觉产物」的项目启动时（第一条最迟在写第一个组件前执行）
- 决定一批断言的编写时机时（默认与被测代码同一次提交）
- 渲染通道、导出 API、截图桥出现超时或挂起时（先判定通道死活，不要绕着写代码）
- 派生交付件（docx / pptx / 交付目录）需要与权威源保持同步时

## Examples

**布局陷阱的具体形态（本段最大的技术发现）**：Figma 的 Auto Layout 默认 `strokesIncludedInLayout = true`，1px INSIDE 描边会把内容框上下各挤 1px。两处受害：卡片选中态高 78 而另两档 76；`btn/secondary` 高 47 而另五个变体 45 —— 后者在 5 处 `align: MIN` 的横排容器里表现为**两键顶对齐、底部差 2px，肉眼可见**。

修法是在构造器里**无条件**设 `false`，而不是只对带描边的变体设 —— 六个变体共用一个构造器，条件判断只会漏。见 [buttonRaw()](file:///d:/developer/code/aicoding/s2s/prototype-figma/code.js#L2136-L2148)。

CSS 侧口径一并写进规范：须用 `outline` 或 `box-shadow` 而非 `border`，否则实现侧照「加 1px 边框」写就会在浏览器里复现同一位移。

**这个缺陷离线探针查不出、只有实机核验能查出** —— 它正是第一条的反面教材：越晚出图，这类只在实机现形的缺陷就越晚暴露、修起来越贵。

## Related

- [design-parameter-review-and-gating.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/design-parameter-review-and-gating.md) —— 评审载体的尺寸失真与「守门人没守住真正的约束」，与本文第三、四条同源
- [multi-format-deliverable-consistency.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/multi-format-deliverable-consistency.md) —— 派生交付件滞后的落盘核对机制，本文第七、八条是它的延伸
- [cross-document-reference-verification.md](file:///d:/developer/code/aicoding/s2s/docs/solutions/workflow-issues/cross-document-reference-verification.md) —— 凭记忆引用而不核真源的同族问题
- [CONCEPTS.md](file:///d:/developer/code/aicoding/s2s/CONCEPTS.md) —— 「守门型探针 / 测量型探针」「闸门」「实机核验」「无反馈期」的定义
