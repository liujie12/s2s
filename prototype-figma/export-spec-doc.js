/**
 * 把 code.js 里的设计系统真源表导出为《设计系统与组件规范》Markdown 文档。
 *
 * 为什么需要这个脚本（条目 [77] M4-3e 第三层）：
 * 设计系统的**内容**此前已基本齐备，但**没有交付形态** —— 规格散落在
 * code.js 的十几张 JS 表、PRD §1 的 351 行叙述、以及 20 个 Component master
 * 的 description 里。对外交付时没有一份「拿了就能照做」的规范文档；
 * 而若手写一份，它当天就开始与真源脱钩（原则㊾ 记过多次的病）。
 *
 * 与 export-dart-tokens.js 同为**单向出口**：只由本脚本生成、头部标了禁止手改、
 * 且 probe-layout-offline.js 有断言逐项比对产物与真源。脱钩当场变红，
 * 不存在需要人去同步的第二份。
 *
 * 为什么用 eval 整体加载 code.js 而不是正则解析：正则只能取到「写在源码里的
 * 字面量」，取不到求值结果。本文档里大量取值是**派生的** —— TAG_SPECS 的
 * padV 写的是 `SPACING.xs`、BUTTON_SPECS 的 radius 写的是 `RADIUS.md`，
 * 正则拿到的会是这两个字符串本身而非 4 和 8。这条已在 export-dart-tokens.js
 * 验证过，此处沿用同一模式。
 *
 * ⚠️ 对比度比值一律**现算**，不从任何地方抄：CONTRAST_PAIRS 只登记
 * 「哪个色压哪个底 + 阈值 + 判定 + 理由」，比值由下面的 contrastRatio() 按
 * WCAG 2.x 相对亮度公式算出。这样改任何一个色值，本文档里涉及它的每一行
 * 数字都会跟着变，探针再断言算值与 PRD §1.4.2 一致 —— 「改了色忘了回算」
 * 这条既有病根（Accent 那次实测 2.345:1 才发现）从此有机械守门。
 *
 * 用法：node prototype-figma/export-spec-doc.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const BASE = __dirname;
const OUT = path.join(path.dirname(BASE), 'docs', '设计系统与组件规范.md');

/**
 * 要从 code.js 取出的真源表与函数名。
 *
 * 单独提成常量而非内联在 loadSources 里：探针有一条断言要核「这份清单里的
 * 每一项都真的存在于 code.js」，两处若各写一份清单就又是手抄副本。
 */
const SOURCE_NAMES = [
  'SEMANTIC_COLORS', 'CATEGORY_COLORS', 'CATEGORY_DEEP', 'CONTRAST_PAIRS',
  'CARD_STATES', 'TYPE_SCALE', 'SPACING', 'TIGHT_GAP', 'RADIUS', 'CANVAS',
  'MOTION', 'BUTTON_SPECS', 'TAG_SPECS', 'DOT_SIZES', 'FIELD_SPECS',
  'EMPTY_STATE_SIZES', 'CARD_META_SLOTS', 'COMPONENT_SETS', 'TEXT_STYLE_PREFIX',
  'BUTTON_VARIANTS', 'SHELL_TABS', 'CAT_LIST',
  'hexOfRole', 'describeComponents'
];

/**
 * 加载 code.js 并取出全部真源表与两个函数。
 *
 * figma mock 只需 showUI 与 ui.onmessage 两处：code.js 的插件入口只有这两处
 * 会在顶层执行，其余 figma API 都在批次函数内部，本脚本不触及。
 *
 * @returns {Object} 名称 -> 真源表或函数
 */
function loadSources() {
  const figma = {
    showUI: () => {},
    ui: { onmessage: null, postMessage: () => {} }
  };
  const raw = fs.readFileSync(path.join(BASE, 'code.js'), 'utf8');
  const wrapped = new Function(
    'figma', '__html__',
    raw + '\n;return { '
      + SOURCE_NAMES.map((k) => k + ': typeof ' + k + " !== 'undefined' ? " + k + ' : undefined').join(', ')
      + ' };'
  );
  const src = wrapped(figma, '');
  for (const k of SOURCE_NAMES) {
    if (src[k] === undefined) {
      throw new Error('真源缺失：' + k + '（code.js 结构已变，导出脚本需同步）');
    }
  }
  return src;
}

/**
 * 计算单个 sRGB 通道的线性化亮度分量（WCAG 2.x 定义）。
 *
 * @param {number} c 通道值，已归一化到 0–1
 * @returns {number} 线性化后的分量
 */
function linearize(c) {
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
}

/**
 * 计算 HEX 色的相对亮度（WCAG 2.x）。
 *
 * 系数 0.2126 / 0.7152 / 0.0722 是 WCAG 规范原值，不可调。
 *
 * @param {string} hex 形如 '#0B7C8C' 的色值
 * @returns {number} 相对亮度，0（纯黑）到 1（纯白）
 */
function relativeLuminance(hex) {
  const m = /^#([0-9A-Fa-f]{6})$/.exec(hex);
  if (!m) throw new Error('非法色值：' + hex);
  const n = parseInt(m[1], 16);
  const r = linearize(((n >> 16) & 255) / 255);
  const g = linearize(((n >> 8) & 255) / 255);
  const b = linearize((n & 255) / 255);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/**
 * 计算两色的对比度比值（WCAG 2.x）。
 *
 * @param {string} hexA 色值一
 * @param {string} hexB 色值二
 * @returns {number} 比值，1（同色）到 21（黑白）
 */
function contrastRatio(hexA, hexB) {
  const a = relativeLuminance(hexA);
  const b = relativeLuminance(hexB);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

/**
 * 把对比度比值格式化为「x.xx:1」。
 *
 * 保留两位小数：PRD §1.4.2 的表就是两位，且 text-secondary 那档余量只有 0.12，
 * 一位小数会把 4.62 与 4.5 的差距抹掉。
 *
 * @param {number} ratio 比值
 * @returns {string} 形如 '4.62:1'
 */
function fmtRatio(ratio) {
  return ratio.toFixed(2) + ':1';
}

/**
 * 判定符号：把 CONTRAST_PAIRS 的 verdict 枚举渲染成人读的判定列。
 *
 * 刻意不用 emoji（本项目通行红线，emoji 由系统字体渲染、跨端不一致），
 * 改用纯文字词。
 *
 * @param {string} verdict CONTRAST_PAIRS 的 verdict 字段
 * @returns {string} 判定列文本
 */
function verdictText(verdict) {
  const map = {
    pass: '达标',
    ban: '**禁用此组合**',
    exempt: '豁免',
    compensated: '需补偿'
  };
  if (!map[verdict]) throw new Error('未知 verdict：' + verdict);
  return map[verdict];
}

/**
 * 渲染 Token 一览三张表（语义色 / 分类色 / 数值阶）。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderTokens(s) {
  const semantic = Object.keys(s.SEMANTIC_COLORS)
    .map((k) => '| `color/' + k + '` | `' + s.SEMANTIC_COLORS[k] + '` |')
    .join('\n');
  const category = Object.keys(s.CATEGORY_COLORS)
    .map((k) => '| `category/' + k + '` | `' + s.CATEGORY_COLORS[k]
      + '` | `category/' + k + '-deep` | `' + s.CATEGORY_DEEP[k] + '` |')
    .join('\n');
  const spacing = Object.keys(s.SPACING)
    .map((k) => '| `spacing/' + k + '` | ' + s.SPACING[k] + ' |')
    .join('\n');
  const radius = Object.keys(s.RADIUS)
    .map((k) => '| `radius/' + k + '` | ' + s.RADIUS[k] + ' |')
    .join('\n');
  const type = Object.keys(s.TYPE_SCALE)
    .map((k) => {
      const t = s.TYPE_SCALE[k];
      return '| `' + k + '` | ' + t.size + ' | ' + t.weight + ' | ×' + t.lineHeight
        + ' | ' + (t.size * t.lineHeight).toFixed(1) + ' |';
    })
    .join('\n');

  return `## 1. Design Token

Token 是本设计系统的唯一取值来源。Figma 侧对应 Variables 集合 \`ZhaoYaZhao Tokens\`，
Flutter 侧对应 \`lib/design_tokens.dart\`（由 \`export-dart-tokens.js\` 生成）。
**任何取值改动都改 \`code.js\` 顶部的真源表，然后重跑两个导出脚本**。

### 1.1 语义色板（${Object.keys(s.SEMANTIC_COLORS).length} 项）

| Token | HEX |
|---|---|
${semantic}

三色拆职责（勿混用）：\`success\` / \`warning\` / \`error\` 原值作文字时对比度只有
2.15–3.76:1，全部不过 AA。故**原三色只用于填充、圆点、描边等非文本图形**，
一切文字用途取 \`*-text\` 三色。写代码时禁止把 \`color/error\` 传给文字参数。

### 1.2 分类色（5 大类 × 2 档）

| 原色 Token | HEX | 深色变体 | HEX |
|---|---|---|---|
${category}

**原色只作图形**（Pin 填充、图例圆点、卡片分类色条），其上不得放承载内容的文字；
**\`-deep\` 只作承载白色文字或图标的底**。两者色相一致，同屏并置不构成语义割裂。
凡将来新增分类色，必须**同时**补 \`-deep\` 变体，不得只加原色。

### 1.3 字阶（${Object.keys(s.TYPE_SCALE).length} 档）

| 档位 | 字号 px | 字重 | 行高倍数 | 行高 px |
|---|---|---|---|---|
${type}

行高**不入 Variables**：它是「字号 × 倍数」的派生值，单独存一份就是第二份副本。
Figma 侧对应的 Text Style 命名为 \`${s.TEXT_STYLE_PREFIX}<档位>\`（6 档）；
Paint Style 刻意**不加前缀**，名字直接沿用 role 名（\`color/*\` 与 \`category/*\`），
与变量面板同名，可肉眼对照。

### 1.4 间距与圆角

| 间距 Token | px |
|---|---|
${spacing}

| 圆角 Token | px |
|---|---|
${radius}

**\`${s.TIGHT_GAP}px\` 是间距阶梯之外唯一获准的豁免值**（常量 \`TIGHT_GAP\`），
只用于「一个语义单元内部的两行」之间（圆标与其标签、色块名与其色值）。
不得把它当通用间距用，也不得加进 \`spacing/*\` —— 阶梯是 4 的倍数，2 破坏该规律。

### 1.5 画布规格

设计画框固定 **${s.CANVAS.w} × ${s.CANVAS.h}**（iPhone 14 逻辑分辨率，与 Flutter 逻辑像素一致）。
`;
}

/**
 * 渲染对比度实测表。比值现算，不抄任何数字。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderContrast(s) {
  const rows = s.CONTRAST_PAIRS.map((p) => {
    const fgHex = s.hexOfRole(p.fg);
    const bgHex = s.hexOfRole(p.bg);
    if (!fgHex || !bgHex) {
      throw new Error('CONTRAST_PAIRS 里的 role 查不到色值：' + p.fg + ' / ' + p.bg);
    }
    return '| ' + p.label
      + ' | ' + fmtRatio(contrastRatio(fgHex, bgHex))
      + ' | ' + (p.threshold === null ? '—' : p.threshold)
      + ' | ' + verdictText(p.verdict)
      + ' | ' + p.note + ' |';
  }).join('\n');

  const banned = s.CONTRAST_PAIRS.filter((p) => p.verdict === 'ban').length;

  return `## 2. 对比度实测表（${s.CONTRAST_PAIRS.length} 组，含 ${banned} 组禁用）

**红线**：正文级文字 ≥ **4.5:1**（WCAG AA）；非文本图形 ≥ **3.0:1**；
纯装饰与占位符豁免。触控区最小 **44 × 44**。

⚠️ **本表的比值全部由 \`export-spec-doc.js\` 现算**，不是抄来的数字。
真源只登记「哪个色压哪个底 + 阈值 + 判定 + 理由」（\`code.js\` 的 \`CONTRAST_PAIRS\`），
比值按 WCAG 2.x 相对亮度公式算出。**故任何调色都会让本表数字自动变化**，
且离线探针有断言核对算值与本红线，改了色忘了回算会当场变红。

| 组合 | 实测 | 阈值 | 判定 | 说明 |
|---|---|---|---|---|
${rows}

**「需补偿」的含义**：该组合自身低于阈值，但靠非颜色通道补齐 ——
完整度圆点三档同尺寸同位置形成可辨序列，且完整度在信息卡内另有文字版。
**颜色永远不得是某项信息的唯一载体。**
`;
}

/**
 * 渲染按钮六档规格表。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderButtons(s) {
  const rows = s.BUTTON_VARIANTS.map((v) => {
    const b = s.BUTTON_SPECS[v];
    const shape = b.radius === s.RADIUS.full ? '全圆角胶囊' : '圆角 ' + b.radius;
    return '| `' + v + '`'
      + ' | ' + (b.fill || '无（透明）')
      + ' | ' + b.textColor
      + ' | ' + (b.stroke ? b.stroke + ' 1px' : '无')
      + ' | ' + shape
      + ' | ' + b.usage + ' |';
  }).join('\n');

  return `## 3. 按钮（${s.BUTTON_VARIANTS.length} 档）

内边距一律 **纵 ${s.SPACING.md} / 横 ${s.SPACING.lg}**，高度由内边距与字号撑出，**勿写死高度**。

| 档位 | 填充 | 文字 | 描边 | 形状 | 用途 |
|---|---|---|---|---|---|
${rows}

- **一屏不得出现两个 \`primary\`**；
- \`disabled\` 档的对比度（${fmtRatio(contrastRatio(s.hexOfRole(s.BUTTON_SPECS.disabled.textColor), s.hexOfRole(s.BUTTON_SPECS.disabled.fill)))}）**刻意不达标** —— 它表达的正是「不可用」，
  故此档**禁止用于任何可点元素**，且须同时降至 40% 不透明度以声明范围；
- Figma 侧这六档合成为一个 Component Set，变体属性为 \`${s.COMPONENT_SETS['ui/button'].join(', ')}\`。
`;
}

/**
 * 渲染卡片规格与三态登记。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderCard(s) {
  const states = s.CARD_STATES.map((st) => '| ' + st.label
    + ' | ' + (st.inStock ? '有' : '**无**')
    + ' | ' + st.spec
    + ' | ' + st.note + ' |').join('\n');
  const slots = s.CARD_META_SLOTS.map((m) => '| `' + m.key + '`'
    + ' | `' + m.node + '`'
    + ' | ' + m.scale
    + ' | ' + m.color
    + ' | ' + m.usage + ' |').join('\n');
  const missing = s.CARD_STATES.filter((st) => !st.inStock).length;

  return `## 4. 卡片

列表卡宽 **${s.CANVAS.w} − ${s.SPACING.lg} × 2 = ${s.CANVAS.w - s.SPACING.lg * 2}**，
结构为「左侧 4px 分类色条 · 主体（标题 h3 + 摘要 small）· 右侧元数据」。

### 4.1 三态（${s.CARD_STATES.length} 档，${missing === 0
    ? '全部有实处'
    : '其中 ' + missing + ' 档本轮未出稿'}）

| 态 | 稿内实现 | 规格 | 说明 |
|---|---|---|---|
${states}

### 4.2 右侧元数据三槽位

同一个位置在三个页面承载三种不同语义，故拆为三个具名槽位。
字阶与颜色**一律取自真源表，调用点无从自定** —— 否则「元数据一律 caption/primary」
这条规格就又只存在于注释里了。

| 槽位 | 图层名 | 字阶 | 颜色 | 用途 |
|---|---|---|---|---|
${slots}

这三格是**卡片右侧元数据**，不是标签组件：它们是纯文本、无容器无底色。
套上标记容器会把它们提到与标题同级的视觉权重。
`;
}

/**
 * 渲染标签四族规格。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderTags(s) {
  const t = s.TAG_SPECS;
  return `## 5. 标签与标记（四族）

PRD §1.7 把「标签/徽章」列为必做组件，但稿内的 11 处实物**并非同类**。
按语义拆开后只有 A 族内部真的不一致、需要归一；另三族要么样本量为 1、
要么本来就已自洽、要么根本不是标签。故按族分栏，不硬压成同一条规格。

### 5.1 A 族 · 可点选择胶囊

| 项 | 取值 |
|---|---|
| 内边距 | 纵 ${t.chip.padV} / 横 ${t.chip.padH} |
| 圆角 | ${t.chip.radius === s.RADIUS.full ? '全圆角（full）' : t.chip.radius} |
| 字阶 | ${t.chip.scale} |
| 未选中 | 底 \`${t.chip.offFill}\` + 字 \`${t.chip.offText}\` |
| 选中 | 底 \`${t.chip.onFill}\`（代表某分类时取该分类 \`-deep\` 档）+ 字 \`${t.chip.onText}\` |
| 实处 | ${t.chip.nodes.map((n) => '`' + n + '`').join(' · ')} |

${t.chip.usage}。**未选中态已归一** —— 回改前三种画法并存
（无填充无描边 / 无填充+border 描边 / background 填充），三者在同一屏里
会被读成三种不同的可点性强弱，而它们其实是同一件事。

### 5.2 B 族 · 静态标记

| 项 | 取值 |
|---|---|
| 内边距 | 纵 ${t.mark.padV}（TIGHT_GAP）/ 横 ${t.mark.padH} |
| 圆角 | ${t.mark.radius} |
| 字阶 | ${t.mark.scale} |
| 填充 / 文字 | \`${t.mark.fill}\` / \`${t.mark.textColor}\` |
| 实处 | ${t.mark.nodes.map((n) => '`' + n + '`').join(' · ')} |

${t.mark.usage}

### 5.3 C 族 · 浮层提示条

| 项 | 取值 |
|---|---|
| 内边距 | 纵 ${t.hintBar.padV} / 横 ${t.hintBar.padH} |
| 圆角 | ${t.hintBar.radius} |
| 填充 / 文字 | \`${t.hintBar.fill}\` / \`${t.hintBar.textColor}\` |
| 字阶 | ${Object.keys(t.hintBar.scaleByNode).map((n) => '`' + n + '` = ' + t.hintBar.scaleByNode[n]).join(' · ')} |
| 实处 | ${t.hintBar.nodes.map((n) => '`' + n + '`').join(' · ')} |

${t.hintBar.usage}。字阶如实登记两值而非假装已统一：1px 之差不值得改动已验收画面，
且 \`_hint\` 是一句需读完的操作指引、\`_map-caption\` 是一句状态说明，前者略大有其道理。

### 5.4 D 族 · 圆角 full 但不是标签

实处：${t.notTag.nodes.map((n) => '`' + n + '`').join(' · ')}

${t.notTag.usage}

登记它们是为了防止下一个人再把它们数进标签里。**其中前两个是手搓按钮、
绕过了按钮真源表**，改走真源表列为遗留项。
`;
}

/**
 * 渲染圆点档位登记。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderDots(s) {
  const rows = Object.keys(s.DOT_SIZES).map((k) => {
    const d = s.DOT_SIZES[k];
    return '| `' + k + '` | ' + d.size + ' | ' + d.nodes.map((n) => '`' + n + '`').join(' · ')
      + ' | ' + d.usage + ' |';
  }).join('\n');

  return `## 6. 圆点（${Object.keys(s.DOT_SIZES).length} 档）

这是**登记**而非硬统一：8px 的未读红点与 12px 的 Pin 角标本就不该同尺寸 ——
前者是余光可见即可的存在性提示，后者要在花花绿绿的底图上仍能辨色。
强行统一成一档会牺牲其中一头。

| 档位 | 边长 px | 实处 | 用途 |
|---|---|---|---|
${rows}
`;
}

/**
 * 渲染输入框两套规格与各自状态表。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderFields(s) {
  const blocks = Object.keys(s.FIELD_SPECS).map((key) => {
    const f = s.FIELD_SPECS[key];
    const stateRows = Object.keys(f.states).map((sk) => {
      const st = f.states[sk];
      return '| `' + sk + '`'
        + ' | ' + st.sample
        + ' | `' + st.fill + '`'
        + ' | `' + st.stroke + '` ' + st.strokeWeight + 'px'
        + ' | `' + st.textColor + '`'
        + ' | ' + st.usage + ' |';
    }).join('\n');
    return '### ' + key + '\n\n'
      + '| 项 | 取值 |\n|---|---|\n'
      + '| 高度 | ' + f.h + ' |\n'
      + '| 圆角 | ' + (f.radius === s.RADIUS.full ? '全圆角（full）' : f.radius) + ' |\n'
      + '| 横向内边距 | ' + f.padH + ' |\n'
      + '| 内元素间距 | ' + f.gap + ' |\n'
      + '| 标签 | ' + (f.labelScale ? f.labelScale + ' / `' + f.labelColor + '`' : '无独立标签') + ' |\n'
      + '| 输入文字 | ' + f.textScale + ' |\n'
      + '| 实处 | ' + f.nodes.map((n) => '`' + n + '`').join(' · ') + ' |\n\n'
      + f.usage + '\n\n'
      + '| 状态 | 样本 | 填充 | 描边 | 文字 | 说明 |\n|---|---|---|---|---|---|\n'
      + stateRows + '\n';
  }).join('\n');

  return `## 7. 输入框（两套并列）

**为什么允许两套而不归一**：表单字段与导航栏搜索框在 5 个维度上都不同，
而这个不同是有依据的 —— 导航栏搜索框取 32 高有 PRD 明文依据
（导航栏 48 上下各留 8 呼吸；横向命中面积远超 44×44 等效值，不适用图标按钮的
44px 下限）。强行压成一套，要么让表单框缩到 32 破触控下限、要么让导航栏被撑破。

⚠️ **样本量如实标注**：状态表里标「业务页有实处」的是从既有产品画面归纳的；
标「仅状态实样板」的在 19 个业务页面里**零实处**、规格是本轮新拟的，
只在「00 · Tokens 与组件」页有一处规范演示位可供比对形态。不要以为它们是从产品画面里量出来的。

${blocks}
**三态的取值依据（都不靠颜色单通道）**：\`focus\` 换主色描边**且**加粗到 1.5；
\`error\` 描边取 \`error-text\`（作文字达标）而非 \`error\`（作图形仅需补偿），
并**强制配一行错误文案** —— 颜色之外必须有文字通道，色盲用户才读得到哪里错了；
\`disabled\` 底色降为 \`background\`，但**标签色不降级**，标签仍须读得清。
`;
}

/**
 * 渲染空态三档与骨架屏规格。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderEmptyAndSkeleton(s) {
  const rows = Object.keys(s.EMPTY_STATE_SIZES).map((k) => {
    const e = s.EMPTY_STATE_SIZES[k];
    return '| `' + k + '` | ' + e.duck + ' | ' + e.tier + ' | ' + e.leadScale
      + ' | `' + e.leadColor + '` | ' + (e.padV === null ? '—' : e.padV)
      + ' | ' + e.sample + ' | ' + e.usage + ' |';
  }).join('\n');

  return `## 8. 空态与骨架屏

### 8.1 空态三档

鸭子 IP 的形态是**由尺寸单向推导**的（≥96 full / 64–95 compact / <64 mini），
故这三个数字不只是「多大」，它们同时决定了用哪一套形。谁若把 40 顺手改成 64，
形会整体换掉而看不出是为什么 —— 这是本表存在的理由。

| 档位 | 鸭子 px | 形档 | 主文案字阶 | 主文案色 | 纵向留白 | 样本 | 用途 |
|---|---|---|---|---|---|---|---|
${rows}

⚠️ \`loading\` 档**不是空态**：它说「等一下」，另两档说「没有了」，语义相反。
放同一张表是因为三档共用同一个鸭子构造器与同一套尺寸推导规则，
分表登记会让「64 属于哪一档」再次无处可查。

### 8.2 骨架屏

复刻列表卡的三段结构（分类色条位 + 标题行 + 摘要行），而非画一个空灰矩形 ——
骨架屏的语义是「结构已定、内容未到」，只画灰块看不出将要填什么。

| 部件 | 尺寸 | 填充 |
|---|---|---|
| 色条位 | 4 × 44，圆角 ${s.RADIUS.sm} | \`color/border\` |
| 标题条 | 180 × 16，圆角 ${s.RADIUS.sm} | \`color/border\` |
| 摘要条 | 120 × 12，圆角 ${s.RADIUS.sm} | \`color/border\` |
| 卡容器 | 内边距 ${s.SPACING.lg}，圆角 ${s.RADIUS.lg} | \`color/surface\` |

- 灰阶一律走 \`color/border\`（Token 内已有的最浅可见灰），**不新造 skeleton 专用 Token** ——
  骨架屏是同一套灰阶的临时用法，不是新的语义色；
- **条数为 3**，是 PRD 逐字给的值，不取整不省略；
- **骨架屏与真实内容不得同时可见**：骨架屏移除后内容才起淡入（见动效 \`fade\` 档）。
`;
}

/**
 * 渲染动效六档。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderMotion(s) {
  const rows = Object.keys(s.MOTION).map((k) => {
    const m = s.MOTION[k];
    return '| `' + k + '` | ' + m.scene + ' | ' + m.dur + 'ms | ' + m.ease
      + ' | ' + m.impl + ' | ' + m.prd + ' |';
  }).join('\n');

  return `## 9. 动效（${Object.keys(s.MOTION).length} 档）

| 档位 | 场景 | 时长 | 缓动 | 实现口径 | 判据 |
|---|---|---|---|---|---|
${rows}

- \`ease\` 保留 PRD 原词，**不擅自换成 CSS 或 Flutter 的具名曲线** ——
  \`spring\` 在 Flutter 是 \`SpringSimulation\`、在 CSS 里根本没有对应值，
  替设计师把语义词落成具体参数超出「冻结契约」的范围；
- 动效**不入 Figma Variables**：\`createVariable\` 只收 COLOR / FLOAT / STRING / BOOLEAN，
  没有时间与缓动类型。故动效契约以画布 annotation + 本表承载。
`;
}

/**
 * 渲染 Component Set 与 20 条组件契约。
 *
 * 契约文本直接取 describeComponents() 的输出，不手抄 —— 那已是「从真源现算」
 * 的产物（每条描述里的间距、圆角、配色都是从 SPACING / RADIUS / BUTTON_SPECS /
 * CATEGORY_COLORS 现算的）。此处用一个 Proxy 当 cache，把 20 条收回来：
 * 无需预知键名，也不需要跑起 Figma。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} Markdown 片段
 */
function renderComponents(s) {
  const collected = [];
  // Proxy 冒充「任何键都命中一个 COMPONENT 节点」的 cache：
  // describeComponents 对每个键取 cache[name]、核 type 后写 description，
  // 于是每写一次就被这里截获一条。刻意不 mock 整个 Figma 文档 ——
  // 契约文本的生成不依赖任何画布状态。
  const fakeCache = new Proxy({}, {
    get: (_, name) => {
      const node = {
        type: 'COMPONENT',
        set description(v) { collected.push({ name: String(name), text: v }); },
        get description() { return ''; }
      };
      return node;
    }
  });
  const n = s.describeComponents(fakeCache);
  if (n !== collected.length) {
    throw new Error('契约条数自报 ' + n + ' 与实收 ' + collected.length + ' 不符');
  }

  const setRows = Object.keys(s.COMPONENT_SETS).map((k) => '| `' + k + '`'
    + ' | ' + s.COMPONENT_SETS[k].map((p) => '`' + p + '`').join(' · ')
    + ' | ' + collected.filter((c) => c.name.indexOf(k + '/') === 0).length + ' |').join('\n');

  const contracts = collected.map((c) => '### `' + c.name + '`\n\n'
    + c.text.split('\n').map((line) => '- ' + line).join('\n') + '\n').join('\n');

  return `## 10. 组件库（${collected.length} 个 master）

### 10.1 Component Set 与变体轴

| Set | 变体属性 | 变体数 |
|---|---|---|
${setRows}

Figma 的变体属性**只能**从图层名读，格式硬性 \`Property=Value\`、多属性用 \`, \` 分隔。
故同一个组件有三套并存的命名口径，各只服务一件事：
**扁平名**（如 \`ui/button/primary\`）是代码内部的组件身份；
**变体名**（如 \`variant=primary\`）只存在于 master 图层名上；
**画布名**（如 \`btn/primary/发布\`）是 Instance 图层名。

Set 之外另有 **${collected.length - Object.keys(s.COMPONENT_SETS).reduce((acc, k) => acc + collected.filter((c) => c.name.indexOf(k + '/') === 0).length, 0)} 个独立 master**（无变体轴，不参与合成）。

### 10.2 逐组件契约

以下 ${collected.length} 条是各 Component master 的 description 原文，
**由 \`code.js\` 的 \`describeComponents()\` 从真源表现算**（每条里的间距、圆角、
配色都不是手写值）。契约讲的是「这个组件在任何页都成立的约束」；
「这一页为什么这么设计」那类页级判据留在画布标注卡里，同一条信息不两处写。

${contracts}`;
}

/**
 * 组装完整的 Markdown 产物。
 *
 * @param {Object} s loadSources() 的返回值
 * @returns {string} 产物全文
 */
function render(s) {
  const tokenCount = Object.keys(s.SEMANTIC_COLORS).length
    + Object.keys(s.CATEGORY_COLORS).length
    + Object.keys(s.CATEGORY_DEEP).length
    + Object.keys(s.TYPE_SCALE).length
    + Object.keys(s.SPACING).length
    + Object.keys(s.RADIUS).length;

  return `# 找鸭找 · 设计系统与组件规范

<!--
  由 prototype-figma/export-spec-doc.js 自动生成，请勿手改。

  真源是 prototype-figma/code.js 里的设计系统真源表（同时也是 Figma Variables
  与 Component master description 的来源）。改规格请改那里再重跑：

      node prototype-figma/export-spec-doc.js

  prototype-figma/probe-layout-offline.js 有断言逐项比对本文件与真源，
  手改或忘记重跑都会当场变红。本文件与 lib/design_tokens.dart 同为单向出口。
-->

> **本文件由脚本生成，请勿手改。** 改规格请改 \`prototype-figma/code.js\` 的真源表，
> 然后重跑 \`node prototype-figma/export-spec-doc.js\`。
>
> 上游判据：\`docs/PRD.md\` §1（设计系统）与 §1.8（无障碍红线）。
> 下游产物：Figma Variables 集合 \`ZhaoYaZhao Tokens\`、\`lib/design_tokens.dart\`。
>
> 计数：Token ${tokenCount} 项 · 对比度 ${s.CONTRAST_PAIRS.length} 组 · 动效 ${Object.keys(s.MOTION).length} 档

## 0. 怎么用这份文档

1. **取值一律查本文档**，不要从渲染图上量、也不要从别的实现里抄；
2. 本文档标「本轮未出稿」「仅状态实样板」的项，表示**19 个业务页面里没有对应画面** ——
   规格有效，但没有产品语境中的对照参考，实现时若发现规格不适用应回头提出，而非默默改掉；
3. 凡颜色相关的改动，都必须回到 §2 那张表重算 —— 那张表的比值是现算的，改了色会自动变；
4. 本文档**不含**页面级设计意图（为什么这一页这么排），那部分在 Figma 画布的标注卡与 PRD 里。

${renderTokens(s)}
${renderContrast(s)}
${renderButtons(s)}
${renderCard(s)}
${renderTags(s)}
${renderDots(s)}
${renderFields(s)}
${renderEmptyAndSkeleton(s)}
${renderMotion(s)}
${renderComponents(s)}
## 11. 本设计系统当前的已知缺口

如实登记，避免接棒人误以为「文档里有的稿里就一定有」：

| 缺口 | 现状 | 处置 |
|---|---|---|
| Pin 变体覆盖 | ${s.CAT_LIST.length} 类 × 供需 2 态 = ${s.CAT_LIST.length * 2} 种走组件；**选中态（48×48）与完整度角标态不走组件** | Figma 禁止对 Instance 增删子节点，这两态属结构差异，API 限制改不了。实现侧自行构造 |
| 卡片选中态 / 下架态 | 2026-09-02 已补：\`card()\` 支持三态，实样在「00 · Tokens 与组件」页；**业务页内仍无实处** | 见 §4.1 的说明 —— 选中态在原型内没有交互载体（列表卡点击即跳详情），实现侧引入多选时按登记表构造 |
| 输入框 focus / error / disabled | 2026-09-02 已补：\`field()\` 五态实样在「00 · Tokens 与组件」页；**业务页内仍无实处** | 见 §7，属新拟规格而非归纳 |
| 暗色模式 | 不做 | PRD §1.7 明写本期不做 |
| 多行输入（textarea） | 稿内零实现 | 发布页当前是四个单行框；补它属改产品形态，不属补规范 |
| 动效进 Variables | 不做 | Figma 变量类型不支持时间与缓动 |
| 画布文本挂 Text Style | Style 已注册，**既有文本节点尚未挂上 \`textStyleId\`** | 遗留项 |
| \`_sheet-reset\` / \`_sheet-confirm\` | 手搓按钮，绕过按钮真源表；**且破 PRD §1.8 触控下限** —— 实测高 36 / 34，低于 44。各出现 3 次（T3 三级筛选树三层弹层的底部动作行） | **实现侧务必补到 44 高**，不要照稿取值。Figma 侧不改的原因：改走真源表须先给按钮补一档「满宽 grow + full 圆角」（现有 capsule 档宽度写死 312），master 数会由 20 变 22，牵动 Component Set 与全部断言基线 |
`;
}

/**
 * 生成并落盘规范文档，附计数自报。
 *
 * 只在本文件被直接 `node` 执行时调用（见文件末尾的 require.main 判断）：
 * 探针要 require 本模块拿 render() 现算一份期望文本去比对产物，
 * 若落盘发生在模块求值期，探针一 require 就会把产物改写掉 ——
 * 那时「产物与真源同步」这条断言验的是自己刚写下的东西，永远绿。
 *
 * @returns {void}
 */
function main() {
  const sources = loadSources();
  const text = render(sources);
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  const before = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : null;
  fs.writeFileSync(OUT, text, 'utf8');
  console.log(
    (before === null ? 'created ' : before === text ? 'unchanged ' : 'updated ')
    + path.relative(path.dirname(BASE), OUT)
  );
  console.log(
    'TOKEN ' + (Object.keys(sources.SEMANTIC_COLORS).length
      + Object.keys(sources.CATEGORY_COLORS).length
      + Object.keys(sources.CATEGORY_DEEP).length
      + Object.keys(sources.TYPE_SCALE).length
      + Object.keys(sources.SPACING).length
      + Object.keys(sources.RADIUS).length)
    + ' + CONTRAST ' + sources.CONTRAST_PAIRS.length
    + ' + MOTION ' + Object.keys(sources.MOTION).length
  );
}

// 供 probe-layout-offline.js 取用。刻意只导出「算什么」而不导出「写哪里」之外的
// 副作用入口：探针需要的是 OUT 路径、loadSources 与 render 三样，
// 拿它们现算一份期望文本与磁盘上的产物逐字比对（单向出口的核心断言）。
module.exports = { OUT, SOURCE_NAMES, loadSources, render };

if (require.main === module) main();
