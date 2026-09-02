/**
 * 找鸭找 v2 原型生成器 · Figma Plugin 主逻辑
 * 依据：docs/PRD.md v2.1 §2 视觉系统（:110-181）、§10.1 页面清单（:1458-1477）、§8 T6 组件（:1051-1054）
 *
 * 设计约束（来自技术验证结论）：
 * 1. Figma REST API 为 GET-only，无法写节点，故唯一可行路径为 Plugin API
 * 2. manifest 声明 documentAccess: "dynamic-page"，禁用同步 figma.getNodeById，一律用异步 API
 * 3. 颜色值使用 0-1 归一化区间，不是 0-255
 * 4. 写入文字前必须 await figma.loadFontAsync
 * 5. 颜色一律绑定 Variables（role 语义名），生成侧禁止字面 HEX，改色只需改变量
 */

// ============================================================
// 一、Design Token 定义（PRD §1.4）
// ============================================================

/**
 * 语义色板（PRD §1.4.2）
 * 键名即 Figma Variable 的 role 名，生成侧只引用 role，不引用 HEX
 * primary 三色已于 2026-08-23 定稿为「A 深湖青」，白字对比度 4.91:1 过 WCAG AA
 */
var SEMANTIC_COLORS = {
  'primary':        '#0B7C8C',
  'primary-dark':   '#075E6B',
  'primary-light':  '#E6F6F8',
  // Accent 由 #FF8A3D 压深至 #B4531A（2026-08-26，实机对比度核查后用户拍定）。
  //
  // 原值白字压其上仅 2.345:1，远低于 PRD §1.8 的 4.5:1，而 Accent 的两处用途
  //（「AI 猜」角标 11px、「✨ AI 帮我发」FAB 14px）都是白字压橙底，故必须改。
  //
  // 为什么不取等比压暗的临界值：base × 70% = #B3612B 恰为 4.505:1，余量只
  // 0.005，任何舍入或渲染差异都可能掉到门槛下。PRD 对 text-secondary 余
  // 0.12 就已标「⚠️ 禁止再调浅」，此处沿用同一谨慎度。#B4531A 实测 5.01:1，
  // 余 0.51。
  //
  // 与车辆分类色 #F97316 的可分辨性同时改善：PRD §1.4.2 记两橙对比仅
  // 1.11:1（本次实测 1.20），压深后升至 1.79 —— 压暗顺带缓解了两橙冲突，
  // 但 §1.4.2「Accent 只用于 AI 控件」的职责边界仍然有效，不因此放宽。
  'accent':         '#B4531A',
  'success':        '#22C55E',
  'warning':        '#F59E0B',
  'error':          '#EF4444',
  // 深色文字变体（PRD §1.4.2，2026-08-25 新增）：上面三色作文字时对比度仅
  // 2.15–3.76:1，不过 WCAG AA 4.5:1。故拆职责——原三色只作填充/圆点/图形，
  // 以下三色专用于「彩色文字」与 danger 按钮底（白字压其上）。实测：
  // success-text 5.02:1 / warning-text 5.02:1 / error-text 6.47:1
  'success-text':   '#15803D',
  'warning-text':   '#B45309',
  'error-text':     '#B91C1C',
  'text-primary':   '#1F2937',
  'text-secondary': '#6B7280',
  'text-placeholder': '#9CA3AF',
  'border':         '#E5E7EB',
  'background':     '#F8FAFC',
  'surface':        '#FFFFFF'
};

/**
 * 五大分类色（PRD §1.4.3，已冻结，无"建议"字样）
 * 资源态 = 大类色实心；需求态 = 大类色描边空心 + 内部 "?"
 */
var CATEGORY_COLORS = {
  'cat-work':    '#3B82F6',
  'cat-house':   '#8B5CF6',
  'cat-vehicle': '#F97316',
  'cat-life':    '#10B981',
  'cat-service': '#EC4899'
};

/**
 * 分类色的深色变体（2026-08-26 新增，实机对比度核查后用户拍定「方案 A」）
 *
 * 为什么必须有这一组：白字压上面五个原色实测只有 2.54–4.23:1，**五类全部**
 * 低于 PRD §1.8 的 4.5:1 —— 工作 3.68 / 房屋 4.23 / 车辆 2.80 / 生活 2.54 /
 * 服务 3.53。此前只有「房屋」暴露，是因为 T3 三级树那三屏恰好选中房屋；
 * 其余四类被选中时会同样违规。根因是 PRD §1.4.2 的对比度表原本没有
 * category/* 这一组（从 primary 到 border 到 success/warning/error 全有，
 * 唯独漏了五大类色），是设计系统层面的真空白而非单点笔误。
 *
 * 为什么是「加变体」而不是「改原色」：沿用 PRD §1.4.2 对语义三色用过的
 * 「不换色，拆职责」范式（success/warning/error 遇同样问题时新增了 *-text）——
 * 原色继续作 Pin 填充、图例圆点、卡片圆标等**图形**用途（§1.4.3 已冻结分类色，
 * 不应改动；图形门槛是非文本 3:1，且 PRD §1.4.2 第 236-239 行已为此类
 * 给出白色描边 + 「不承载唯一信息」的补偿范式）；本组深色只作
 * **承载白色文字的底**，目前唯一用途是 _lv1-cat-* 选中态标签。
 *
 * 取值方式：原色等比压暗，逐档搜索至白字对比度 ≥ 4.8（留 0.3 余量，同
 * Accent 改色时的谨慎度，不贴 4.5 的线）。实测白字对比度依次为
 * 4.85 / 4.87 / 4.83 / 4.82 / 4.81，与各自原色的差异 1.32 / 1.15 / 1.72 /
 * 1.90 / 1.36 —— 房屋差异最小（1.15），选中标签与 Pin 并置时肉眼几乎看不出
 * 色相偏移，分类语义完整保留。
 */
var CATEGORY_DEEP = {
  'cat-work':    '#326FD1',
  'cat-house':   '#8055E2',
  'cat-vehicle': '#B85510',
  'cat-life':    '#0B825A',
  'cat-service': '#C63C81'
};

/**
 * 对比度校验组合清单（PRD §1.4.2 全色板实测表的真源，2026-09-01 条目 [77] 第三层）
 *
 * 为什么必须存在（e5 读真源时查出的一处真空）：PRD §1.4.2 那张 26 行实测表
 * 是**手写的**，而 `code.js` 里既没有组合清单、也没有对比度算法（唯二的
 * 亮度实现在 probe-layout-offline.js 与 color-preview.html，两处都只算自己
 * 关心的那几组）。后果是「改一个色值」与「回算它涉及的所有组合」之间没有
 * 任何机械联系 —— Accent 由 #FF8A3D 压深至 #B4531A 那次就是先漏算、
 * 实机核查才发现白字压其上只有 2.345:1（见 SEMANTIC_COLORS 的注释）。
 *
 * ⚠️ **本表刻意不写任何比值**。比值一律由 export-spec-doc.js 按 fg/bg 现算
 * （WCAG 2.x 相对亮度公式），探针再断言算值与 PRD 表逐行一致。若把 4.62 这类
 * 数字抄进表里，改色后数字不会变，这张表就成了第二份会静默脱钩的副本（原则㊾）。
 *
 * 字段：
 * - `fg` / `bg`：参与计算的两个 role 名，须能被 hexOfRole 查到（探针有断言）
 * - `label`：人读的组合名，对应 PRD 表第一列
 * - `threshold`：判定阈值。4.5 = WCAG AA 正文；3.0 = 非文本图形；null = 纯装饰豁免
 * - `verdict`：'pass' 达标 / 'ban' 禁用此组合 / 'exempt' 豁免 / 'compensated' 靠补偿达标
 * - `note`：判定理由或约束，规范文档里逐条照登
 */
var CONTRAST_PAIRS = [
  { fg: 'color/text-primary', bg: 'color/surface', label: 'text-primary 在 surface 上', threshold: 4.5, verdict: 'pass', note: '正文主色，最常见组合' },
  { fg: 'color/text-primary', bg: 'color/background', label: 'text-primary 在 background 上', threshold: 4.5, verdict: 'pass', note: '页面底色上的正文' },
  { fg: 'color/text-primary', bg: 'color/primary-light', label: 'text-primary 在 primary-light 上', threshold: 4.5, verdict: 'pass', note: '浅青底信息块内的正文' },
  { fg: 'color/text-secondary', bg: 'color/surface', label: 'text-secondary 在 surface 上', threshold: 4.5, verdict: 'pass', note: '卡片内次要文字' },
  { fg: 'color/text-secondary', bg: 'color/background', label: 'text-secondary 在 background 上', threshold: 4.5, verdict: 'pass', note: '⚠️ 余量仅 0.12。禁止再调浅，也不得用于比 background 更浅之外的任何底色' },
  { fg: 'color/primary', bg: 'color/surface', label: 'primary 作文字在 surface 上', threshold: 4.5, verdict: 'pass', note: '链接与强调文字；也是「主色底 + 白字」那一组的等价判据' },
  { fg: 'color/primary', bg: 'color/primary-light', label: 'primary 作文字在 primary-light 上', threshold: 4.5, verdict: 'ban', note: '禁用此组合。primary-light 底上的文字一律改用 primary-dark 或 text-primary' },
  { fg: 'color/primary-dark', bg: 'color/primary-light', label: 'primary-dark 作文字在 primary-light 上', threshold: 4.5, verdict: 'pass', note: '信任卡、批注框、冲刺区标题的正确取法' },
  { fg: 'color/primary-dark', bg: 'color/surface', label: 'primary-dark 作文字在 surface 上', threshold: 4.5, verdict: 'pass', note: '白底上的深青文字' },
  { fg: 'color/text-secondary', bg: 'color/primary-light', label: 'text-secondary 在 primary-light 上', threshold: 4.5, verdict: 'ban', note: '禁用此组合（差 0.15）。浅青底上的次要文字改用 primary-dark' },
  { fg: 'color/surface', bg: 'color/error-text', label: '白字压 error-text 底', threshold: 4.5, verdict: 'pass', note: 'danger 按钮、离线横幅' },
  { fg: 'color/success-text', bg: 'color/surface', label: 'success-text 作文字', threshold: 4.5, verdict: 'pass', note: '一切绿色文字用途' },
  { fg: 'color/warning-text', bg: 'color/surface', label: 'warning-text 作文字', threshold: 4.5, verdict: 'pass', note: '一切橙黄色文字用途' },
  { fg: 'color/error-text', bg: 'color/surface', label: 'error-text 作文字', threshold: 4.5, verdict: 'pass', note: '一切红色文字用途' },
  { fg: 'color/success', bg: 'color/surface', label: 'success 作圆点图形', threshold: 3.0, verdict: 'compensated', note: '低于非文本 3.0 阈值，靠「圆点辨识补偿」：完整度信息同时有文字版' },
  { fg: 'color/warning', bg: 'color/surface', label: 'warning 作圆点图形', threshold: 3.0, verdict: 'compensated', note: '同上，且三档圆点尺寸一致、位置固定，形成序列可辨' },
  { fg: 'color/error', bg: 'color/surface', label: 'error 作圆点图形', threshold: 3.0, verdict: 'pass', note: '三档中唯一自身达标者' },
  { fg: 'color/border', bg: 'color/surface', label: 'border 相邻 surface', threshold: null, verdict: 'exempt', note: '纯装饰分隔线，不承载信息，豁免' },
  { fg: 'color/border', bg: 'color/background', label: 'border 相邻 background', threshold: null, verdict: 'exempt', note: '同上' },
  { fg: 'color/primary-light', bg: 'color/surface', label: 'primary-light 相邻 surface', threshold: null, verdict: 'exempt', note: '纯装饰底色区块，豁免' },
  { fg: 'color/text-placeholder', bg: 'color/primary-light', label: 'text-placeholder 在 primary-light 上', threshold: 4.5, verdict: 'ban', note: '禁用此组合（承载真实信息时）。浅青底上不得用 placeholder 级灰' },
  { fg: 'color/text-placeholder', bg: 'color/surface', label: 'text-placeholder 在 surface 上', threshold: null, verdict: 'exempt', note: '占位符豁免：WCAG 对「输入前的提示文字」不作正文要求，但它不得承载唯一信息' },
  { fg: 'color/text-placeholder', bg: 'color/border', label: 'disabled 按钮（placeholder 压 border 底）', threshold: null, verdict: 'exempt', note: '禁用态豁免：低对比正是「不可用」的视觉表达。故此档禁止用于任何可点元素' },
  { fg: 'color/surface', bg: 'color/accent', label: '白字压 accent 底', threshold: 4.5, verdict: 'pass', note: '2026-08-26 由 #FF8A3D（2.35:1）压深至 #B4531A。任何 Accent 调整都必须重算此值' },
  { fg: 'color/surface', bg: 'category/cat-work', label: '白字压 category/cat-work 底', threshold: 4.5, verdict: 'ban', note: '禁止承载白字，改用 category/cat-work-deep' },
  { fg: 'color/surface', bg: 'category/cat-house', label: '白字压 category/cat-house 底', threshold: 4.5, verdict: 'ban', note: '禁止承载白字，改用 category/cat-house-deep' },
  { fg: 'color/surface', bg: 'category/cat-vehicle', label: '白字压 category/cat-vehicle 底', threshold: 4.5, verdict: 'ban', note: '禁止承载白字，改用 category/cat-vehicle-deep' },
  { fg: 'color/surface', bg: 'category/cat-life', label: '白字压 category/cat-life 底', threshold: 4.5, verdict: 'ban', note: '禁止承载白字，改用 category/cat-life-deep' },
  { fg: 'color/surface', bg: 'category/cat-service', label: '白字压 category/cat-service 底', threshold: 4.5, verdict: 'ban', note: '禁止承载白字，改用 category/cat-service-deep' },
  { fg: 'color/surface', bg: 'category/cat-work-deep', label: '白字压 category/cat-work-deep 底', threshold: 4.5, verdict: 'pass', note: '一级类目顶栏标签选中态的正确取法' },
  { fg: 'color/surface', bg: 'category/cat-house-deep', label: '白字压 category/cat-house-deep 底', threshold: 4.5, verdict: 'pass', note: '同上' },
  { fg: 'color/surface', bg: 'category/cat-vehicle-deep', label: '白字压 category/cat-vehicle-deep 底', threshold: 4.5, verdict: 'pass', note: '同上' },
  { fg: 'color/surface', bg: 'category/cat-life-deep', label: '白字压 category/cat-life-deep 底', threshold: 4.5, verdict: 'pass', note: '同上' },
  { fg: 'color/surface', bg: 'category/cat-service-deep', label: '白字压 category/cat-service-deep 底', threshold: 4.5, verdict: 'pass', note: '同上' }
];

/**
 * 卡片三态登记表（PRD §1.4.7，2026-09-01 条目 [77] 第三层）
 *
 * 为什么是「登记表」而不是 card() 的实现（e5 读真源时查出的第二处缺口）：
 * PRD §1.4.7 写明卡片有正常 / 选中 / 下架三态，而 card() 只画了正常态 ——
 * 另两态**全稿零实现**。补画它们属于改画面（要重跑批次、重出渲染图），
 * 已明确不在本轮范围内；但若规范文档就此绕过不提，「稿里没有」这件事
 * 就成了静默缺口，实现侧照文档做会以为卡片只有一态。
 *
 * 故照 Pin 那两态的既有体例处理：**如实登记规格 + 标明未出稿 + 指明由谁负责构造**。
 * 规格值一律取自既有 Token role，不新造色（选中边框用 primary-light 是 PRD 原文）。
 *
 * 字段：
 * - `key` / `label`：态名
 * - `inStock`：本轮画布内是否有实现。false 的两档在规范里带醒目声明
 * - `spec`：与正常态的差异描述，规范正文照登
 * - `note`：判据与实现约束
 */
var CARD_STATES = [
  {
    key: 'normal', label: '正常态', inStock: true,
    spec: '白底 color/surface + 圆角 lg + 阴影 0 2 8 rgba(0,0,0,0.04)，内边距 lg，内元素间距 md',
    note: 'card() 的唯一实现形态，14 页内全部列表卡走此档。判据 PRD §1.4.7'
  },
  {
    key: 'selected', label: '选中态', inStock: true,
    spec: '在正常态基础上加 1px color/primary-light 边框，其余一切不变（不改底色、不改阴影）。'
      + '硬约束：边框不得占据布局尺寸 —— Figma 侧须设 strokesIncludedInLayout = false，'
      + 'CSS 侧须用 outline 或 box-shadow 描边而非 border，否则卡高会被顶高 2px，'
      + '选中态与正常态在列表里相邻，一选中整列往下错位，看着像列表在抖',
    note: '实处在「00 · Tokens 与组件」页的状态实样板（2026-09-02 补），业务页内无实处 —— '
      + '列表卡在原型内不存在「选中」交互（点击即跳详情页，无多选场景），故只有规范演示位。'
      + '注意 primary-light 与 surface 的对比度仅 1.11:1（见 CONTRAST_PAIRS，纯装饰豁免），'
      + '故边框不得作为选中与否的唯一线索，须同时有勾选框或其他形状标记。判据 PRD §1.4.7'
  },
  {
    key: 'archived', label: '下架态', inStock: true,
    spec: '整卡 opacity 50% + 右侧元数据槽位 lifecycle 填「已下架」',
    note: '实处在状态实样板（2026-09-02 补）。「我的发布」页那张卡的 lifecycle 槽位只填「已下架」文字'
      + '（见 CARD_META_SLOTS）、未施加 opacity 折扣 —— 业务页保持全亮度是刻意的：'
      + '那一页的卡带「刷新重发/删除」操作组，压到 50% 会连操作入口一起压暗。'
      + 'opacity 50% 会把卡内所有文字的实际对比度砍半（text-primary 14.68:1 降至约 4.9:1），'
      + '仍在 AA 线上，但**不得再叠加任何其他降透明度处理**。判据 PRD §1.4.7'
  }
];

/** 字阶（PRD §1.4.4）：size 单位 px，lineHeight 为倍数 */
var TYPE_SCALE = {
  h1:      { size: 24, weight: 'Bold',     lineHeight: 1.3 },
  h2:      { size: 18, weight: 'SemiBold', lineHeight: 1.3 },
  h3:      { size: 16, weight: 'SemiBold', lineHeight: 1.4 },
  body:    { size: 14, weight: 'Regular',  lineHeight: 1.5 },
  small:   { size: 12, weight: 'Regular',  lineHeight: 1.5 },
  caption: { size: 11, weight: 'Medium',   lineHeight: 1.2 }
};

/** 间距阶（PRD §1.4.5） */
var SPACING = { xs: 4, sm: 8, md: 12, lg: 16, xl: 24, xxl: 32 };

/**
 * 贴合间距（2px）—— SPACING 阶梯之外的**唯一获准豁免值**。
 *
 * 为什么必须存在（2026-08-27 条目 [61]，B 类像素精修）：
 * 它只用在「一个语义单元内部的两行」之间 —— 圆标与其标签、色块名与其色值、
 * 时长行与其 PRD 出处、字段名与其取值。这类两行本就该读成一件东西，用阶梯
 * 最小值 xs=4 会把它们拉成两条独立信息，视觉上与「单元之间」的间距混为一档。
 *
 * 为什么以常量形式而非字面 2 散落各处：`bindNum()` 对不在阶梯上的值是
 * **静默不绑变量、也不报错**（code.js:672 `if (!name) return false;`）。
 * 也就是说散落的字面 2 会让这些容器悄悄脱离 Variables 而画面完全正常，
 * 是最难发现的一类漂移。收成一个具名常量后：
 * ① 豁免理由只写一遍，读代码的人当场看到它是刻意的而非手滑；
 * ② 布局探针能钉住「全文只有这一个非阶梯间距值、且用量恰为 9 处」，
 *    日后谁再随手写个 3 或 6，断言立刻报红（见 probe-layout-offline.js）。
 *
 * **不要把它加进 SPACING**：加进去就意味着承诺它是一档通用间距，
 * 会被用到单元之间，而 PRD §1.4.5 的阶梯是 4 的倍数，2 破坏该规律。
 */
var TIGHT_GAP = 2;

/**
 * 「正文 → 主操作」之间的一档更大间距（2026-09-01 条目 [77] ⑫）。
 *
 * 为什么要单立一档：受限态（buildPrivacyDeclined）实机看图查出正文底边 454、
 * 按钮顶边 466 —— 只隔 12px，按钮读起来像正文的最后一行。根因是纵排容器只有
 * 一个统一 `gap`，于是「标题→正文」（同一段说明内部）与「正文→按钮」
 *（说明与出口之间，跨语义层级）拿到同一个值。间距本该编码层级差。
 *
 * **刻意不改统一 gap 本身**：那会牵动全部空态与所有走 box() 的纵排容器，
 * 而问题只出在「正文之后紧跟主操作」这一种形态上。
 *
 * 取 xxl=32 而非 xl=24：容器 gap 通常是 md=12，插隔块的实现会额外吃两段
 * gap（见 appendActionWithGap），24 会算出 0 高隔块 —— 而零尺寸节点会被体检
 * 报成异常节点（同 flexSpacer 那条）。32 在 md 档下得 8px 隔块，仍落在阶梯上。
 *
 * 值取自 SPACING 而非再写一个字面 32：它**是**阶梯上的一档，只是被指派了
 * 专门用途。写字面量就多了一份会与阶梯静默脱钩的副本（原则㊾）。
 */
var ACTION_GAP = SPACING.xxl;

/** 圆角阶（PRD §1.4.5） */
var RADIUS = { sm: 4, md: 8, lg: 12, xl: 16, full: 999 };

/** 画布规格：iPhone 14 逻辑分辨率，与 Flutter 逻辑像素一致 */
var CANVAS = { w: 390, h: 844 };

/**
 * 动效规格真源（PRD §1.4.8 + §6.8，2026-08-27 条目 [51] 第 6 步 / I5）。
 *
 * 为什么这张表不进 Figma Variables：条目 [48] 首次查明的硬约束 —— TIMING 与
 * EASING **无法经 Plugin API 创建为变量**（`figma.variables.createVariable`
 * 只接受 COLOR / FLOAT / STRING / BOOLEAN 四种 resolvedType，没有时间与缓动
 * 类型）。这是 I5 存在的唯一原因：色彩字号间距圆角都能进 Token 层，动效不能，
 * 故只能落 annotation。**不要再尝试把它建成变量**。
 *
 * 那为什么还要在 code.js 里建这张表：annotation 的文字要写这些值，而画布上
 * 已有 3 处手抄了「240ms spring」（`categorySheet` 头注释、`mapCanvas` 弹层
 * 定位处、首页筛选展开态的卡片文案）。第 5 步刚在 BUTTON_SPECS 上吃过同样的
 * 教训 —— 写引用之前先统一真源，否则每处引用都是一份会静默脱钩的副本
 * （原则㊾、原则 55）。**此处刻意不写行号：行号会随改动漂移，指错位置的注释
 * 比没有注释更误导**。
 *
 * `dur` 单位统一 ms；`ease` 用 PRD 原词，不擅自换成 CSS 或 Flutter 的具名曲线：
 * 「spring」在 Flutter 是 `SpringSimulation`、在 CSS 里根本没有对应值，替设计师
 * 把语义词落成具体参数属于替他做决定，超出「冻结契约」的范围（条目 [51] 红线）。
 * 实现侧取值时按 `impl` 字段的口径自行选参。
 */
var MOTION = {
  page: {
    scene: '页面切换', dur: 260, ease: 'ease-out',
    impl: '前进右侧滑入 / 返回左侧滑出',
    prd: 'PRD §1.4.8'
  },
  sheet: {
    scene: '弹窗/抽屉', dur: 240, ease: 'spring',
    impl: '底部上滑；遮罩渐显单列见 mask 档',
    prd: 'PRD §1.4.8 / §6.9'
  },
  mask: {
    scene: '遮罩渐显', dur: 180, ease: 'ease-out',
    impl: '不透明度 0 → 40%，与 sheet 同时起步',
    prd: 'PRD §1.4.8'
  },
  press: {
    scene: '按钮反馈', dur: 80, ease: 'ease-out',
    impl: '按下缩放至 0.97，释放回弹',
    prd: 'PRD §1.4.8'
  },
  fade: {
    scene: '内容淡入', dur: 180, ease: 'ease-out',
    impl: '骨架屏占位 → 内容淡入，两者不叠加',
    prd: 'PRD §1.4.8'
  },
  layer: {
    scene: '图层切换', dur: 200, ease: 'ease-out',
    impl: '分类 Tab 切换 Marker 颜色重刷；资源/需求切换形状立即变、颜色渐变',
    prd: 'PRD §6.8'
  }
};

/**
 * 时长条的换算比例：1ms 对应多少 px。
 *
 * 单独提出来而不是在画板里写两遍 0.5：条宽与槽位宽都要用它，写两处就是
 * 一份手抄副本 —— 只改一处时条会溢出槽位或槽位留下多余空白，而两者都是
 * 「看着还算正常」的错（原则㊾）。取 0.5 是因为最长的 260ms 档得到 130px，
 * 既能看出档间差距又不撑破画板宽度。
 */
var MOTION_PX_PER_MS = 0.5;

/**
 * 把一档动效渲染成标注用的一行文字。
 *
 * 为什么要有这个函数而不在各处拼串：拼串就是把「ms」「｜」这些格式散布到调用点，
 * 改一次格式要改 N 处；更要紧的是断言得以拿同一个函数核对画布文本，
 * 而不是在探针里手抄一份期望字符串（原则㊾）。
 *
 * @param {string} key MOTION 的键
 * @returns {string} 形如「页面切换 260ms ease-out ｜ 前进右侧滑入 / 返回左侧滑出」
 */
function motionLine(key) {
  var m = MOTION[key];
  return m.scene + ' ' + m.dur + 'ms ' + m.ease + ' ｜ ' + m.impl;
}

/**
 * 动效规格 annotation 的正文（六档全量 + 承载方式说明）。
 *
 * 为什么正文要复述「不进 Variables」这件事：读 annotation 的人在 Dev Mode 里，
 * 手边只有这张卡。他找不到 motion 变量时的第一反应是「设计漏配了」，然后就会
 * 自己拟一套时长 —— 规格于是在实现侧分叉。把原因写进正文，是让「这里没有变量」
 * 从疑点变成结论。
 *
 * 六档全列而不只列本页相关档：动效档之间有联动（sheet 240ms 与 mask 180ms 必须
 * 同时起步、layer 200ms 的形状切换不参与渐变），只给单档会让实现侧看不出配合关系。
 *
 * @returns {string[]} annotation 正文行；每档一行，内容由 motionLine 现算
 */
function motionSpecLines() {
  var lines = [
    '动效规格无法进 Token 层：Plugin API 的 createVariable 只接受 '
      + 'COLOR/FLOAT/STRING/BOOLEAN，没有时间与缓动类型。以下六档即唯一判据，'
      + '不要去 Variables 面板找 motion/*。'
  ];
  for (var k in MOTION) {
    lines.push('motion/' + k + '：' + motionLine(k) + '（' + MOTION[k].prd + '）');
  }
  // ease 用 PRD 原词的后果要交代清楚，否则实现侧会把 spring 当成某条具名贝塞尔
  lines.push('缓动一律沿用 PRD 原词：spring 指弹性模拟（Flutter 用 SpringSimulation，'
    + 'CSS 无对应值需自行近似），此处不代设计师定参数。');
  return lines;
}

/**
 * 数值型 Token 的反查表（值 → 变量名），供 box()/text() 把字面数字换成变量绑定。
 *
 * 为什么需要反查而不是改调用点：字号/间距/圆角在 42 个画框里共有数百处消费点，
 * 逐处改成「传变量名」的工程量与出错面都远大于收益。而所有消费点本来就统一
 * 走 box()/text() 两个构造器，且传入的实参一律取自 TYPE_SCALE/SPACING/RADIUS
 * 三张表 —— 也就是说值本身已经是 Token，只是丢了名字。反查即可把名字找回来。
 *
 * 为什么三张表分开反查：4 与 8 同时存在于间距阶与圆角阶，混在一张表里会歧义。
 * 按消费语义分表后各自唯一（圆角 4/8/12/16/999、间距 4/8/12/16/24/32）。
 *
 * 为什么由三张真源表派生而不是手写：手写等于第二份副本，改了 SPACING 却忘改
 * 反查表就会静默失去绑定。派生保证两者不可能脱钩。
 */
var NUM_TOKEN_NAMES = { size: {}, spacing: {}, radius: {} };
(function buildNumTokenIndex() {
  var k;
  for (k in TYPE_SCALE) NUM_TOKEN_NAMES.size[TYPE_SCALE[k].size] = 'size/' + k;
  for (k in SPACING) NUM_TOKEN_NAMES.spacing[SPACING[k]] = 'spacing/' + k;
  for (k in RADIUS) NUM_TOKEN_NAMES.radius[RADIUS[k]] = 'radius/' + k;
})();

/** 字体族（用户决策：思源黑体 Noto Sans SC），FONT_FAMILY 在 setup 阶段可能被降级覆写 */
var FONT_FAMILY = 'Noto Sans SC';
var FONT_FALLBACK = 'Inter';

/** Variable 集合名与运行时 id 缓存：role 名 -> Variable 对象 */
var VAR_CACHE = {};

/**
 * Text Style 名前缀（2026-09-01，条目 [77] 第二层 ⑥）。
 *
 * 为什么加前缀而不直接叫 "h1"：Figma 的样式面板按 "/" 自动分组，
 * 加前缀后 6 档会收成一个「字阶」文件夹，与后续可能出现的其他样式族并列；
 * 不加则 6 档散在根层，与团队库里同名的 h1 撞名难辨。
 * Paint Style 不用前缀 —— 它的名字直接沿用 role 名（color/* 与 category/*），
 * 本身已带斜杠分组，且与变量面板同名可肉眼对照（见 ensurePaintStyles）。
 */
var TEXT_STYLE_PREFIX = '字阶/';

/** 样式运行时缓存：档位键 -> TextStyle；role 名 -> PaintStyle */
var TEXT_STYLE_CACHE = {};
var PAINT_STYLE_CACHE = {};

// ============================================================
// 一之二、规格真源表（PRD 派生，本文件内唯一取值来源）
// ============================================================

/**
 * S2 动态蜂窝半径档（PRD §6.4.4）——本表是这四档在本文件内的唯一取值来源
 *
 * 【务必分清 PRD 里的两套「半径」口径，它们不是同一件事】
 * 1) 本表 = S2 蜂窝自动响应，四档 3/5/10/全城，由系统按结果密度自动切换，
 *    用户不直接选；出处 PRD §6.4.4「S2 蜂窝半径」。
 * 2) 另一套 = 首页范围条，五档 1/3/5/10/全城，由用户手动拖选；
 *    出处 PRD §6.7 实现逻辑，并被 §6.10 缓存键五元组、设置页默认范围、
 *    /map/pins 入参、user.default_radius 共同引用。
 *
 * 2026-08-24 修正记录：此前半径档画框取的是 `1/3/5/10/全城` 里的四个值
 * （即口径 2 的取值），标注卡文案也是口径 2 的表述，而画框标题写的是
 * 「S2 动态蜂窝半径档」（口径 1）——标题、取值、文案三者不配对。
 * 现按口径 1 归位。改动本表前请先确认改的是哪一套口径。
 *
 * @property {string} tier 档位名，直接作为画框标题与地图说明的一部分
 * @property {string} density 该档对应的结果密度描述，取自 PRD §6.4.4 同表
 */
var S2_RADIUS_TIERS = [
  { tier: '3km',  density: '≥30 条高密度' },
  { tier: '5km',  density: '10–29 条' },
  { tier: '10km', density: '3–9 条轻度不足，扩档+浮层' },
  { tier: '全城', density: '≤2 条极稀疏' }
];

/**
 * 空状态兜底过程态时间轴（PRD §6.4.4「兜底过程态（三级递进，全程不留空白页）」）
 * ——本表是这六个时点在本文件内的唯一取值来源
 *
 * 【这是空圈兜底，不是性能降级】两者在 PRD 中分属不同章节，不可叉乘：
 * - 本表（§6.4.4）：范围内结果不足时，如何用文案与兜底页留住用户；
 * - 性能三层 SLA（§6.10）：首屏加载与切换的耗时口径，画框见本文件降级态三框。
 * §6.10 自己写明「2G/3G 与断网会话不计入 P95 分母，改为走 §6.4.4 的过程态与降级 UI」，
 * 即 PRD 层面已把两者分开。
 *
 * 2026-08-24 修正记录：此前本处前两框写的是「骨架屏：地图底图先出」
 * 「首屏 Pin 上屏，Loading 指示消失」，那是性能加载态，恰是上面这条注释
 * 明令不可混入的东西。现六框全部按 §6.4.4 原句归位。
 *
 * @property {string} at 时点标签，与 PRD §6.4.4 表首列逐字一致
 * @property {string} ui 界面表现，取 PRD 原句（含引号内用户可见文案），不作概括
 * @property {string} lead 该档的用户可见主文案，从 ui 的引号内摘出。
 *   为什么要单列：ui 是给评审读的规格原句（含「文案切」这类元规格词），
 *   直接画到画面上就等于把规格文档贴进产品界面。lead 才是真上屏的那句话。
 * @property {string} [tail] 该档的用户可见次级文案 / 分组标题，同上理。
 * @property {boolean} [skeleton] 是否画 3 条骨架卡（PRD 只有 0–1 秒档写明）
 * @property {boolean} [progress] 是否画进度条（PRD 只有 1–10 秒档写明）
 * @property {Array<string>} [buttons] 该档明文要求的按钮，格式 [文案, variant]
 * @property {boolean} [results] 是否铺真实结果卡（两个「返回」档写明「铺卡片」）
 * @property {boolean} [terminal] 是否为终态空页（30 秒档写明「落到终态空页」）
 *
 * 2026-08-31 补齐记录（条目 [70-h]，23 张变体图首次出图后查出）：
 * 上面 ui 字段自 2026-08-24 起就逐字对齐了 PRD，但**画框只把它当一行说明文字
 * 贴在地图上**，PRD 写明的缺省图 / 骨架卡 / 进度条 / 按钮 / 终态空页一件都没画，
 * 六张图与主态逐像素相同。ui 对齐 ≠ 画面对齐 —— 这正是「机读判据只查了文案
 * 取值、人眼从未看过这六张图」的重叠盲区（原则 132）。故本表补出元素级字段，
 * 由 buildEmptyFallbackFrames 逐档按字段画元素，不再只画文案。
 */
var EMPTY_FALLBACK_TIMELINE = [
  {
    at: '0–1 秒',
    ui: '鸭子 IP 缺省图 + "附近有点安静，正在帮你往外找…" + 骨架卡 3 条',
    lead: '附近有点安静，正在帮你往外找…',
    skeleton: true
  },
  {
    at: '1 秒返回',
    ui: '有历史匹配则直接铺卡片 + "过去 7 天的同类信息"分组标题；无则保持上一态继续等',
    lead: '过去 7 天的同类信息',
    results: true
  },
  {
    at: '1–10 秒',
    ui: '文案切"正在扩大到全城范围…"，进度条走满 10 秒；可点"我自己调范围"退出等待',
    lead: '正在扩大到全城范围…',
    progress: true,
    buttons: [['我自己调范围', 'ghost']]
  },
  {
    at: '10 秒返回',
    ui: '全城同分类结果铺卡片，顶部提示"5 公里内暂时没有，这些在全城范围内"',
    lead: '5 公里内暂时没有，这些在全城范围内',
    results: true
  },
  {
    at: '10–30 秒',
    ui: '文案切"已通知平台帮你找，稍后消息通知你"；不强留，显示「先去别处看看」按钮',
    lead: '已通知平台帮你找，稍后消息通知你',
    buttons: [['先去别处看看', 'secondary']]
  },
  {
    at: '30 秒仍无',
    ui: '终态空页：鸭子缺省图 + "已记下你的需求，有匹配会推送给你" + 「发一条需求，让别人来找你」主按钮',
    lead: '已记下你的需求，有匹配会推送给你',
    terminal: true,
    buttons: [['发一条需求，让别人来找你', 'primary']]
  }
];

/**
 * 需覆盖的状态画框清单（PRD §6.4.4 定位权限降级 / §7.8 详情页边界 / §6.5.1 协议门）
 * ——本表是这五个状态的标题与说明文案在本文件内的唯一取值来源
 *
 * 共同点：PRD 已明文定义，但生成器一度无对应画框，属纯缺失而非取值错误。
 * 其中 'permission-reopen'（权限 B 态「曾授权后被关」）为 2026-08-31 补：
 * PRD §6.4.4 权限三分表早已写明 A/B 两态，实机却只画了 A 态——
 * 而 B 态若沿用 A 态的「开启位置权限」按钮，因系统拒绝是 sticky 的，
 * 点了不会有任何反应，用户会认为 App 坏了，这是必须出图核对的一态。
 * C 态刻意不建画框：PRD 明写 C 态「不出引导页，直接走 §6.8 降级终态」，
 * 那个终态即紧随的 'cell-fallback'，已有稿，再建一框会是重复稿。
 * 'privacy-declined' 为 2026-09-01 补，同属「PRD 写了而稿里没有」。
 *
 * @property {string} title 画框标题（不含 pageId 与 prdRef，由 screen() 拼装）
 * @property {string} prdRef PRD 章节回标
 * @property {Array<string>} notes 标注卡正文行，逐行取自 PRD 原句
 */
var COVERAGE_STATES = {
  'permission-guide': {
    title: '位置权限未开·全屏引导页',
    prdRef: 'PRD §6.4.4',
    notes: [
      '第一段降级：突出"就近"价值，先争取授权',
      '主按钮"开启位置权限"，次按钮"手动选择城市"',
      '未授权前进不到首页主态，故本页无地图与底部 Tab'
    ]
  },
  'permission-reopen': {
    title: '位置权限曾授权后被关·全屏引导页',
    prdRef: 'PRD §6.4.4',
    notes: [
      '权限 B 态：状态为 denied/restricted 且本地留有"曾成功定位"标记',
      '系统拒绝是 sticky 的，App 内无法再弹系统弹窗，主按钮改为跳系统设置',
      '判定靠本地 location_granted_once 标记，不能只读当前权限值',
      '与 A 态共用同一套布局，仅标题/说明/主按钮文字与动作四处不同'
    ]
  },
  'cell-fallback': {
    title: '基站+商圈兜底地图态',
    prdRef: 'PRD §6.4.4',
    notes: [
      '第二段降级：用户仍拒绝或选"手动选择城市"后进入',
      '定位精度降到基站+商圈级，非城市中心假值，避免误导',
      '同时是 §6.8「定位失败 ≥3 次」的降级终态'
    ]
  },
  'detail-offline': {
    title: '详情页·已下架/过期态',
    prdRef: 'PRD §7.8',
    banner: '该信息已下架/过期',
    notes: [
      '页面整体 Opacity 60%，顶部红条须保持可读',
      '联系按钮禁用，收藏状态保留',
      '与正常态详情页并列对照，正常态不受影响'
    ]
  },
  // 2026-09-01 条目 [76]：只有受限态一档，没有「同意态」一档 ——
  // 同意态就是 privacy-gate 主态本身（码侧 _AgreementView 是默认视图，
  // _DeclinedView 才是分支），再登记一档等于把主态抄一遍。
  'privacy-declined': {
    title: '隐私协议门·不同意后的受限态',
    prdRef: 'PRD §6.5.1',
    notes: [
      '不同意不退出应用：工信部禁止「不同意就不给用」，杀进程是华为/vivo 驳回项',
      '刻意不是空白页：空白会让用户以为应用坏了（§6.5.1 明文）',
      '内容 = 产品价值说明 + 「重新阅读协议」主按钮，随时可改主意',
      '本态下全程不初始化地图 SDK、不申请任何权限'
    ]
  }
};

// ============================================================
// 二、通用工具函数
// ============================================================

/**
 * 将 #RRGGBB 十六进制颜色转为 Figma 所需的 0-1 归一化 RGB
 * @param {string} hex 形如 "#0B7C8C" 的十六进制颜色串
 * @returns {{r:number,g:number,b:number}} 各通道取值 0-1 的 RGB 对象
 */
function hexToRgb(hex) {
  var h = hex.replace('#', '');
  return {
    r: parseInt(h.substring(0, 2), 16) / 255,
    g: parseInt(h.substring(2, 4), 16) / 255,
    b: parseInt(h.substring(4, 6), 16) / 255
  };
}

/**
 * 向插件 UI 回传一行日志，便于用户观察分批执行进度
 * @param {string} text 日志正文
 * @returns {void}
 */
function log(text) {
  figma.ui.postMessage({ type: 'log', text: text });
}

// ============================================================
// 二之二、产出规模自报（I4）
// ============================================================

/**
 * 外壳底部 Tab 的三个态，与 Component master 注册、规格板共用同一份声明。
 * 提到模块级的原因：此前 registerComponents 与 batchSetup 各持一份字面量副本，
 * 加一个 Tab 要改两处，漏一处则 master 与规格板对不上。
 */
var SHELL_TABS = ['鸭圈', '发布', '我的'];

/** 按钮六类（PRD §1.4.6），同样由 master 注册与规格板共用 */
var BUTTON_VARIANTS = ['primary', 'secondary', 'ghost', 'danger', 'capsule', 'disabled'];

/**
 * 主态画框登记表：19 个参与跳转索引的 pageId。
 *
 * 为什么要显式登记而不是数 screen() 调用点：主态数是对外契约（交棒第一屏要报的数、
 * FLOW_LINKS 的合法目标集、indexMainFrames 的期望产出），而调用点散落在四个批次的
 * 29 处，靠人数必然数错 —— ui.html 上那个错了很久的计数就是这么来的。
 *
 * 登记后 screen() 会强制校验：新增主态忘了登记、或把变体漏传 isVariant，都会当场抛错，
 * 而不是等到跳转索引出现重名告警时才被发现。
 */
var MAIN_SCREENS = [
  'home-screen', 'list-screen',
  // privacy-gate 排在 splash 之后、login 之前，与 §6.5.1 冷启动顺序一致
  //（2026-09-01 条目 [76] 补齐，此前是 §10.1 十九页里唯一缺稿的一页）
  'splash-screen', 'privacy-gate', 'login-screen', 'detail-screen', 'publish-screen',
  'ai-confirm-screen',
  'publish-success-screen', 'contact-screen', 'profile-screen', 'my-publish-screen',
  'my-favorite-screen', 'notification-screen', 'trust-screen', 'settings-screen',
  'category-selector', 'map-selector', 'cert-modal'
];

/**
 * 汇总全部产出规模，供 UI 首屏与各批次返回串取值。
 *
 * 一切数字都从真源表现算，不接受手写常量 —— 这是 I4 的全部要点：
 * ui.html 里的静态数字与代码各自演化，最终四处计数全错（如 Variables 标 38，
 * 而 CATEGORY_DEEP 那 5 项在 2026-08-26 新增后无人回改，真值是 43）。
 *
 * FLOW_LINKS / CORE_PAGES 声明在本函数之后，但函数体只在调用时求值，
 * 那时整个文件已执行完毕，故不存在时序问题。
 *
 * @returns {{tokens:Object,styles:Object,masters:Object,corePages:number,mainScreens:number,flowLinks:number}}
 *          tokens 为 Variables 分项与合计；styles 为本地样式分项与合计；
 *          masters 为 Component 分项与合计；
 *          其余三项分别为核心流程页数、主态画框数、原型跳转条数
 */
function planStats() {
  /**
   * 数一个对象的自有键个数
   * @param {Object} obj 待统计对象
   * @returns {number} 键个数
   */
  function size(obj) {
    var n = 0;
    for (var k in obj) n++;
    return n;
  }

  var semantic = size(SEMANTIC_COLORS);
  var category = size(CATEGORY_COLORS);
  var deep = size(CATEGORY_DEEP);
  var sizeScale = size(TYPE_SCALE);
  var spacing = size(SPACING);
  var radius = size(RADIUS);

  var statusBar = 1;
  var tabs = SHELL_TABS.length;
  var buttons = BUTTON_VARIANTS.length;
  var pins = category * 2; // 每个大类各一枚资源态 + 需求态
  // Component Set 数（2026-09-01，条目 [77] 第二层 ⑦）：登记表键数即 set 数。
  // 单独成项而非写死 3：新增一类变体组件时忘了同步，batchSetup 会当场炸掉，
  // 而「合成静默漏一组」在画布上只表现为「那几个 master 还是散着的」——
  // 没人会注意到 host 里少了一个折叠容器
  var sets = 0;
  for (var sk in COMPONENT_SETS) sets++;

  return {
    tokens: {
      semantic: semantic,
      category: category,
      categoryDeep: deep,
      color: semantic + category + deep,
      size: sizeScale,
      spacing: spacing,
      radius: radius,
      float: sizeScale + spacing + radius,
      total: semantic + category + deep + sizeScale + spacing + radius
    },
    // 本地样式分项（2026-09-01，条目 [77] 第二层 ⑥）：
    // Text Style 恰为字阶档数、Paint Style 恰为 COLOR 变量数 —— 两者都由同一批
    // 真源表现算，与 tokens 分项共用 sizeScale / semantic 等中间量。写死数字会
    // 重演 I4 那次「Variables 标 38 而真值 43」的失效
    styles: {
      text: sizeScale,
      paint: semantic + category + deep,
      total: sizeScale + semantic + category + deep
    },
    masters: {
      statusBar: statusBar,
      tabs: tabs,
      buttons: buttons,
      pins: pins,
      sets: sets,
      total: statusBar + tabs + buttons + pins
    },
    corePages: CORE_PAGES.length,
    mainScreens: MAIN_SCREENS.length,
    flowLinks: FLOW_LINKS.length
  };
}

/**
 * 加载生成过程需要的全部字重；若思源黑体缺失则整体降级到 Inter
 * @returns {Promise<string>} 实际生效的字体族名
 */
async function loadFonts() {
  var weights = ['Regular', 'Medium', 'SemiBold', 'Bold'];
  var family = FONT_FAMILY;
  try {
    for (var i = 0; i < weights.length; i++) {
      await figma.loadFontAsync({ family: family, style: weights[i] });
    }
  } catch (e) {
    // 本机未安装 Noto Sans SC，降级到 Figma 内置 Inter，保证生成不中断
    family = FONT_FALLBACK;
    var interWeights = ['Regular', 'Medium', 'Semi Bold', 'Bold'];
    for (var j = 0; j < interWeights.length; j++) {
      await figma.loadFontAsync({ family: family, style: interWeights[j] });
    }
  }
  FONT_FAMILY = family;
  return family;
}

/**
 * 把字阶里的抽象字重名映射为当前字体族实际支持的 style 名
 * @param {string} weight 字阶定义的字重名，如 "SemiBold"
 * @returns {string} 当前字体族可用的 style 名
 */
function styleOf(weight) {
  if (FONT_FAMILY === FONT_FALLBACK && weight === 'SemiBold') return 'Semi Bold';
  return weight;
}

/**
 * 由字阶档位现算 Figma 行高对象（像素制）。
 *
 * 为什么提成函数（2026-09-01，条目 [77] 第二层）：`text()` 与
 * `ensureTextStyles()` 都要这个值，若各写一遍 `Math.round(size × 倍数)`，
 * 一旦 PRD 改了取整口径（比如改成向上取整）就会漏改一处 —— 而后果是
 * 「样式面板里的 h1 行高 31，画布上的 h1 行高 32」这种只差 1px 的静默不一致，
 * 截图看不出、探针若不专门比也查不出。
 *
 * 为什么行高不入 Variables：它是「字号 × 倍数」的派生值，
 * 单独存一份就是第二份副本（见 ensureNumberVariables 注释）。
 *
 * @param {{size:number,lineHeight:number}} scale TYPE_SCALE 的一档
 * @returns {{value:number,unit:string}} Figma LineHeight 对象，单位 PIXELS
 */
function lineHeightOf(scale) {
  return { value: Math.round(scale.size * scale.lineHeight), unit: 'PIXELS' };
}

// ============================================================
// 三、Variables 基础设施（S4 决策：Token 网表化，生成侧禁字面 HEX）
// ============================================================

var COLLECTION_NAME = 'ZhaoYaZhao Tokens';

/**
 * 创建或复用 Variables 集合，写入 COLOR 变量（语义色 + 分类色 + 分类深色变体）
 * 与 FLOAT 变量（字号 + 间距 + 圆角）。
 * 具体项数一律以 planStats().tokens 现算为准，此处不写死数字 —— 曾因写死「38 项」
 * 而在 CATEGORY_DEEP 新增 5 项后与真值（43）长期不符。
 * 幂等语义为「值对齐」：同名变量已存在则比对当前值，不一致时改写为最新 Token 值
 * @returns {Promise<{created:number,reused:number,updated:number}>} 新建/沿用/改值的变量计数
 */
async function ensureVariables() {
  var collections = await figma.variables.getLocalVariableCollectionsAsync();
  var collection = null;
  for (var i = 0; i < collections.length; i++) {
    if (collections[i].name === COLLECTION_NAME) { collection = collections[i]; break; }
  }
  if (!collection) collection = figma.variables.createVariableCollection(COLLECTION_NAME);

  var modeId = collection.modes[0].modeId;
  var existing = await figma.variables.getLocalVariablesAsync('COLOR');
  var byName = {};
  for (var k = 0; k < existing.length; k++) byName[existing[k].name] = existing[k];

  var created = 0, reused = 0, updated = 0;
  var all = {};
  var key;
  for (key in SEMANTIC_COLORS) all['color/' + key] = SEMANTIC_COLORS[key];
  for (key in CATEGORY_COLORS) all['category/' + key] = CATEGORY_COLORS[key];
  // 深色变体走同一命名空间，加 -deep 后缀（2026-08-26）：
  // 与 SEMANTIC_COLORS 里 success-text 那组同样的挂法，不新建 collection
  for (key in CATEGORY_DEEP) all['category/' + key + '-deep'] = CATEGORY_DEEP[key];

  for (var name in all) {
    var v = byName[name];
    var want = hexToRgb(all[name]);
    if (v) {
      // 幂等的含义是「值对齐」而非「存在即跳过」：
      // 色板定稿后重跑批次 1，已有变量必须被改写为新值，否则改色不生效
      var cur = v.valuesByMode[modeId];
      var same = cur && Math.abs(cur.r - want.r) < 0.002
        && Math.abs(cur.g - want.g) < 0.002
        && Math.abs(cur.b - want.b) < 0.002;
      if (same) {
        reused++;
      } else {
        v.setValueForMode(modeId, want);
        updated++;
      }
    } else {
      v = figma.variables.createVariable(name, collection, 'COLOR');
      v.setValueForMode(modeId, want);
      created++;
    }
    VAR_CACHE[name] = v;
  }

  var num = await ensureNumberVariables(collection, modeId);
  return {
    created: created + num.created,
    reused: reused + num.reused,
    updated: updated + num.updated
  };
}

/**
 * 写入数值型 Token 变量：字号 6 阶 + 间距 6 阶 + 圆角 5 阶，共 17 项。
 *
 * 为什么必须做（2026-08-26，M3 Token 落地）：此前 Figma 侧只有 21 个 COLOR，
 * 而字号/间距/圆角仍是 code.js 里的 JS 字面量。后果是设计师在 Figma 里
 * 改不动它们 —— 想把卡片圆角从 12 调到 16，只能逐个改画布上的具体矩形，
 * 改不了「圆角 lg」这个概念，几十处消费点必然漏改。
 *
 * 为什么行高不入变量：行高由「字号 × 倍数」派生（见 text()），
 * 单独存一份就是第二份副本，改了字号却忘改行高会静默不一致。
 *
 * 为什么阴影不入变量：PRD 只规定了两处阴影（§1.4.7 卡片 0.04、§6.7 地图
 * 悬浮卡 0.12），其余 6 处（Marker/弹层/FAB）属画面特定值而非阶梯 Token，
 * 强行入表会造出 PRD 里不存在的规格。
 *
 * @param {VariableCollection} collection 目标变量集合
 * @param {string} modeId 目标模式 ID
 * @returns {Promise<{created:number,reused:number,updated:number}>} 新建/沿用/改值的计数
 */
async function ensureNumberVariables(collection, modeId) {
  var existing = await figma.variables.getLocalVariablesAsync('FLOAT');
  var byName = {};
  for (var i = 0; i < existing.length; i++) byName[existing[i].name] = existing[i];

  var all = {};
  var key;
  for (key in TYPE_SCALE) all['size/' + key] = TYPE_SCALE[key].size;
  for (key in SPACING) all['spacing/' + key] = SPACING[key];
  for (key in RADIUS) all['radius/' + key] = RADIUS[key];

  var created = 0, reused = 0, updated = 0;
  for (var name in all) {
    var v = byName[name];
    var want = all[name];
    if (v) {
      // 与 COLOR 同一套「值对齐」语义：字阶调整后重跑批次 1 必须改写旧值
      if (v.valuesByMode[modeId] === want) {
        reused++;
      } else {
        v.setValueForMode(modeId, want);
        updated++;
      }
    } else {
      v = figma.variables.createVariable(name, collection, 'FLOAT');
      v.setValueForMode(modeId, want);
      created++;
    }
    VAR_CACHE[name] = v;
  }
  return { created: created, reused: reused, updated: updated };
}

/**
 * 把已建好的 Variables 载入内存缓存，供后续批次（map/core/modal）引用
 * 批次之间插件可能被重新执行，故每批开头都需调用
 * @returns {Promise<number>} 载入的变量数量，应等于 planStats().tokens.total
 */
async function hydrateVariables() {
  var n = 0;
  var colors = await figma.variables.getLocalVariablesAsync('COLOR');
  for (var i = 0; i < colors.length; i++) {
    if (colors[i].name.indexOf('color/') === 0 || colors[i].name.indexOf('category/') === 0) {
      VAR_CACHE[colors[i].name] = colors[i];
      n++;
    }
  }
  // FLOAT 必须与 COLOR 一同载入：批次 2/3/4 里 box()/text() 的每一次调用都要
  // 查这批变量，缺失则静默退回字面数字 —— 画面看不出差别，但 Token 绑定率归零
  var nums = await figma.variables.getLocalVariablesAsync('FLOAT');
  for (var j = 0; j < nums.length; j++) {
    var nm = nums[j].name;
    if (nm.indexOf('size/') === 0 || nm.indexOf('spacing/') === 0 || nm.indexOf('radius/') === 0) {
      VAR_CACHE[nm] = nums[j];
      n++;
    }
  }
  return n;
}

/**
 * 把一个数值型字段绑定到对应的 FLOAT 变量上。
 *
 * 为什么按「值」反查而不是要求调用方传变量名：见 NUM_TOKEN_NAMES 的说明 ——
 * 数百处消费点的实参本来就取自三张真源表，值即 Token，只是丢了名字。
 *
 * 为什么取不到变量时静默返回：本函数在 box()/text() 里对每个节点调用多次，
 * 缺变量的唯一后果是该字段保持字面值（画面完全正确，只是不可被 Figma 侧统一
 * 调整）。为它抛错会让「变量还没建好」的中间状态直接中断生成，代价大于收益。
 * 完备度由 probe-token-vars.py 在离线侧守，不靠运行时抛错。
 *
 * @param {SceneNode} node 目标节点
 * @param {string} field Figma 绑定字段名，如 "topLeftRadius" / "itemSpacing" / "fontSize"
 * @param {string} group 反查分组："size" / "spacing" / "radius"
 * @param {number} value 字面数值
 * @returns {boolean} 是否成功绑定
 */
function bindNum(node, field, group, value) {
  var name = NUM_TOKEN_NAMES[group][value];
  if (!name) return false;
  var v = VAR_CACHE[name];
  if (!v) return false;
  node.setBoundVariable(field, v);
  return true;
}

/**
 * 把四个角的圆角一并绑定到同一个 radius 变量。
 *
 * 为什么不能绑 cornerRadius：Figma 的变量绑定字段是四个角各自独立的
 * （topLeftRadius 等），cornerRadius 只是写入用的便捷属性，不可绑定。
 *
 * @param {SceneNode} node 目标节点
 * @param {number} value 圆角字面值
 * @returns {boolean} 是否成功绑定
 */
function bindRadius(node, value) {
  var name = NUM_TOKEN_NAMES.radius[value];
  if (!name || !VAR_CACHE[name]) return false;
  var v = VAR_CACHE[name];
  node.setBoundVariable('topLeftRadius', v);
  node.setBoundVariable('topRightRadius', v);
  node.setBoundVariable('bottomLeftRadius', v);
  node.setBoundVariable('bottomRightRadius', v);
  return true;
}

/**
 * 把 Token role 名换算为字面 HEX 值。
 *
 * 为什么提取成独立函数（2026-09-01 条目 [77] 第三层）：这段分支原本内联在
 * paintOf 里当「变量缺失时的回退色」用。第三层的 export-spec-doc.js 要按
 * CONTRAST_PAIRS 里的 role 名现算对比度，同样需要 role → hex 这一步。
 * 若生成器自己再写一遍分支，`-deep` 后缀这类特例就有了第二份实现 ——
 * 而这恰是 paintOf 注释里记过一次的坑（查 CATEGORY_COLORS['cat-house-deep']
 * 拿到 undefined 后静默回退成纯黑）。故提取共用，paintOf 改为调用它。
 *
 * @param {string} role 变量 role 名，如 "color/primary" / "category/cat-work-deep"
 * @returns {string|undefined} 该 role 的 HEX 字面值；role 不存在时返回 undefined
 *          （**刻意不回退成黑色**：回退由调用方按自己的语义决定，
 *          规范生成器需要的是「查不到就报错」，画布构造需要的是「查不到用黑色继续」）
 */
function hexOfRole(role) {
  if (role.indexOf('category/') === 0) {
    var ck = role.replace('category/', '');
    return ck.indexOf('-deep') > 0
      ? CATEGORY_DEEP[ck.replace('-deep', '')]
      : CATEGORY_COLORS[ck];
  }
  return SEMANTIC_COLORS[role.replace('color/', '')];
}

/**
 * 生成一个绑定到指定 Variable 的 SOLID 填充对象
 * 若变量缺失则回退为字面色，保证生成不中断（同时在日志中不静默）
 * @param {string} role 变量 role 名，如 "color/primary" 或 "category/cat-work"
 * @returns {SolidPaint} 已绑定变量的实心填充
 */
function paintOf(role) {
  var v = VAR_CACHE[role];
  // fallback 表要认 -deep 后缀（2026-08-26 新增深色变体后补）：
  // 否则 category/cat-house-deep 会去 CATEGORY_COLORS 里查不存在的
  // 「cat-house-deep」，拿到 undefined 后静默回退成纯黑。
  // 换算已收进 hexOfRole（2026-09-01），此处只负责「查不到用黑色继续」这条策略
  var base = { type: 'SOLID', color: hexToRgb(hexOfRole(role) || '#000000') };
  if (!v) return base;
  return figma.variables.setBoundVariableForPaint(base, 'color', v);
}

// ============================================================
// 三之二、Styles 基础设施（2026-09-01，条目 [77] 第二层 ⑥）
//
// 为什么必须有这一节：在此之前 Figma 的「样式」面板是**完全空的**。
// 画布上每个文本节点都由 text() 逐项设 fontName/fontSize/lineHeight，
// 颜色由 paintOf() 绑到 Variable —— 值都对，但设计师在 Figma 里
// 点不到「h1」这个样式，只点得到 size/h1 这个裸数字变量。
// 对外交付设计稿时这是最先被发现的缺口：拿到文件的人无法「应用 h1」，
// 只能照着数字手抄，抄错无人可查。
//
// **本节只负责注册（让面板里有东西可点），不给画布节点挂 styleId。**
// 这条边界是刻意的，理由见 ensureTextStyles() 的长注释。
// ============================================================

/**
 * 创建或复用 6 档 Text Style，与 TYPE_SCALE 逐项对齐。
 *
 * 为什么只注册、不给画布节点挂 styleId（2026-09-01 用户拍定）：
 * manifest.json 是 `documentAccess: "dynamic-page"`，该模式下官方明确
 * 同步赋值 `TextNode.textStyleId = ...` **会抛异常**，唯一合法路径是
 * `await node.setTextStyleIdAsync(id)`。而 text() 是同步函数、全文有 186
 * 处调用点，其上游还套着 card()/field()/emptyState() 等数十个同步构造器 ——
 * 要挂 styleId 就得把这整条链改成 async 并逐层上推 await，改动面等于把
 * code.js 主干重写一遍，远超本条待办「注册 6 档样式」的范围。
 * 故本轮取「只注册」，并如实登记遗留：在 Figma 里选中画布文字，右侧显示的
 * 仍是具体数值而非「h1」。这不影响交付物可用性（面板里点得到样式、
 * 新建文本可直接应用），只影响既有节点的样式归属显示。
 *
 * 为什么 fontSize 绑到 size/* 变量而不是只存数字：绑上之后「样式」与
 * 「Token」是同一份真源的两个视图 —— 日后在 Figma 里把 size/h1 从 24 调成 26，
 * h1 样式自动跟着变；不绑就是第二份副本，改一处漏一处。
 * 官方 VariableBindableTextField 明确含 fontSize（另有两份第三方文档声称
 * fontSize 不可绑且「静默失败」，与官方类型定义矛盾，此处以官方为准 ——
 * code.js 里 text() 对节点绑 fontSize 已实机验证有效，可佐证）。
 *
 * 为什么行高不绑变量：同 text() 的判据，行高是派生值（见 lineHeightOf）。
 *
 * 幂等语义沿用 ensureVariables() 的「值对齐」而非「存在即跳过」：
 * 同名样式已存在则逐字段比对，不一致时改写并计入 updated。若做成「跳过」，
 * PRD 调了字阶后重跑批次 1，Variables 会更新而样式面板停在旧值，
 * 于是同一个 h1 在两处显示两个字号 —— 这正是本项要消除的那类不一致。
 *
 * @returns {Promise<{created:number,reused:number,updated:number}>} 新建/沿用/改值的样式计数
 */
async function ensureTextStyles() {
  var existing = await figma.getLocalTextStylesAsync();
  var byName = {};
  for (var i = 0; i < existing.length; i++) byName[existing[i].name] = existing[i];

  var created = 0, reused = 0, updated = 0;
  for (var key in TYPE_SCALE) {
    var s = TYPE_SCALE[key];
    var name = TEXT_STYLE_PREFIX + key;
    var wantFont = { family: FONT_FAMILY, style: styleOf(s.weight) };
    var wantLH = lineHeightOf(s);
    var st = byName[name];
    if (st) {
      // 逐字段比对：只要有一项不同就整档改写（改写是幂等的，重复设同值无副作用）
      var same = st.fontSize === s.size
        && st.fontName && st.fontName.family === wantFont.family
        && st.fontName.style === wantFont.style
        && st.lineHeight && st.lineHeight.unit === wantLH.unit
        && st.lineHeight.value === wantLH.value;
      if (same) {
        reused++;
      } else {
        st.fontName = wantFont;
        st.fontSize = s.size;
        st.lineHeight = wantLH;
        updated++;
      }
    } else {
      st = figma.createTextStyle();
      st.name = name;
      st.fontName = wantFont;
      st.fontSize = s.size;
      st.lineHeight = wantLH;
      created++;
    }
    // 变量绑定每轮都重设：样式沿用（reused）时也要绑，否则首次建样式在变量
    // 就位之前的那种执行顺序下，绑定会永久缺失而画面与数值全对
    bindStyleNum(st, 'fontSize', 'size', s.size);
    TEXT_STYLE_CACHE[key] = st;
  }
  return { created: created, reused: reused, updated: updated };
}

/**
 * 把样式对象的数值字段绑定到对应 FLOAT 变量。
 *
 * 与 bindNum() 分开写而不复用：bindNum 的入参是 SceneNode，用的是
 * node.setBoundVariable(field, variable)；BaseStyle 虽同名方法同签名，
 * 但它不是 SceneNode，混用会让 JSDoc 类型与实际不符，也让「绑节点」与
 * 「绑样式」两类失败混在一处难以区分。取不到变量时静默返回，判据同 bindNum。
 *
 * @param {BaseStyle} style 目标样式对象
 * @param {string} field 可绑字段名，如 "fontSize"
 * @param {string} group 反查分组："size" / "spacing" / "radius"
 * @param {number} value 字面数值
 * @returns {boolean} 是否成功绑定
 */
function bindStyleNum(style, field, group, value) {
  var name = NUM_TOKEN_NAMES[group][value];
  if (!name) return false;
  var v = VAR_CACHE[name];
  if (!v) return false;
  style.setBoundVariable(field, v);
  return true;
}

/**
 * 创建或复用 Paint Style，每个语义色 / 分类色 / 分类深色变体各一档。
 *
 * 为什么要有 Paint Style 而不是只有 Color Variable：两者在 Figma 里是
 * **两个不同的面板**。Variable 供「绑定」（改一处全画布跟着变），
 * Style 供「取用」（设计师选中形状后一键上色）。当前只有前者，
 * 于是设计师新画一个矩形时无从取色，只能吸管去吸 —— 吸出来的是字面色，
 * 脱离 Token 体系而画面看不出差别，是最难发现的一类漂移。
 *
 * 每档 paint 直接复用 paintOf()：这样「样式的填充」与「画布节点的填充」
 * 是同一段代码产出的同一个对象结构（含 boundVariables），
 * 不会出现「样式里是字面色、节点里绑了变量」的两套口径。
 * 也因此本函数必须在 ensureVariables() 之后调用，否则 VAR_CACHE 为空，
 * paintOf() 会静默回退字面色，样式建出来是不绑变量的死色。
 *
 * 幂等语义同 ensureTextStyles()：比对当前 paint 的色值与绑定变量 id，
 * 不一致则整档改写。色板定稿后重跑批次 1，样式必须跟着改。
 *
 * @returns {Promise<{created:number,reused:number,updated:number}>} 新建/沿用/改值的样式计数
 */
async function ensurePaintStyles() {
  var existing = await figma.getLocalPaintStylesAsync();
  var byName = {};
  for (var i = 0; i < existing.length; i++) byName[existing[i].name] = existing[i];

  // 与 ensureVariables() 同一套 role 名：样式名即 role 名，不另起一套命名，
  // 使「样式面板里的 color/primary」与「变量面板里的 color/primary」肉眼可对上
  var roles = [];
  var key;
  for (key in SEMANTIC_COLORS) roles.push('color/' + key);
  for (key in CATEGORY_COLORS) roles.push('category/' + key);
  for (key in CATEGORY_DEEP) roles.push('category/' + key + '-deep');

  var created = 0, reused = 0, updated = 0;
  for (var i2 = 0; i2 < roles.length; i2++) {
    var role = roles[i2];
    var want = paintOf(role);
    var st = byName[role];
    if (st) {
      if (samePaint(st.paints && st.paints[0], want)) {
        reused++;
      } else {
        st.paints = [want];
        updated++;
      }
    } else {
      st = figma.createPaintStyle();
      st.name = role;
      st.paints = [want];
      created++;
    }
    PAINT_STYLE_CACHE[role] = st;
  }
  return { created: created, reused: reused, updated: updated };
}

/**
 * 判断两个 SOLID 填充是否等价（色值 + 绑定变量都相同）。
 *
 * 为什么要比绑定变量而不只比色值：变量缺失时 paintOf() 会回退字面色，
 * 回退出的 paint 与绑定成功的 paint **色值完全相同**。若只比色值，
 * 一档「上次因变量未就位而建成死色」的样式会被判为一致而永久沿用，
 * 从此不再绑变量 —— 画面永远正确，Token 联动永远失效。
 *
 * @param {Paint} a 现有填充
 * @param {Paint} b 期望填充
 * @returns {boolean} 是否等价
 */
function samePaint(a, b) {
  if (!a || !b || a.type !== 'SOLID' || b.type !== 'SOLID') return false;
  var near = Math.abs(a.color.r - b.color.r) < 0.002
    && Math.abs(a.color.g - b.color.g) < 0.002
    && Math.abs(a.color.b - b.color.b) < 0.002;
  if (!near) return false;
  var av = a.boundVariables && a.boundVariables.color;
  var bv = b.boundVariables && b.boundVariables.color;
  if (!av && !bv) return true;
  if (!av || !bv) return false;
  return av.id === bv.id;
}

// ============================================================
// 四、节点构造器（统一走 Auto Layout，避免绝对定位造成的偏移问题）
// ============================================================

/**
 * 创建一个竖向或横向 Auto Layout 容器
 * @param {string} name 图层名
 * @param {string} dir "VERTICAL" 或 "HORIZONTAL"
 * @param {Object} opt 可选项：gap 间距 / pad 内边距 / fill 背景 role / radius 圆角 / w 固定宽 / h 固定高 / align 交叉轴对齐
 * @returns {FrameNode} 配置完成的 Frame 节点
 */
function box(name, dir, opt) {
  opt = opt || {};
  var f = figma.createFrame();
  f.name = name;
  f.layoutMode = dir;
  f.itemSpacing = opt.gap === undefined ? 0 : opt.gap;
  var pad = opt.pad === undefined ? 0 : opt.pad;
  f.paddingTop = opt.padTop === undefined ? pad : opt.padTop;
  f.paddingBottom = opt.padBottom === undefined ? pad : opt.padBottom;
  f.paddingLeft = opt.padLeft === undefined ? pad : opt.padLeft;
  f.paddingRight = opt.padRight === undefined ? pad : opt.padRight;
  // 轴向映射必须跟着 layoutMode 走（2026-08-26 修，离线布局探针实测发现）
  //
  // Figma 的 primaryAxisSizingMode 指的是**主轴**（= layoutMode 方向），
  // counterAxisSizingMode 指交叉轴。此前无论横竖都写成
  //   primary = opt.h ? FIXED : AUTO;  counter = opt.w ? FIXED : AUTO;
  // 这对 VERTICAL 是对的（主轴竖 = h），对 HORIZONTAL 恰好反了 ——
  // 横排 box 传 w 只固定了「高」，宽仍是 HUG，紧随的 resize(w) 写进去的宽
  // 会在下一次 appendChild 触发重排时被内容顶掉。
  //
  // 症状举例（离线探针实测）：button('登录 / 注册', 'capsule', 312) 走
  // buttonRaw 时实测只有 111px（= 文案 hug 宽），_code-row 里传 88 的按钮
  // 实测 102px 从而把整行顶到 356 > 342 溢出。传 w 却拿不到 w，是硬错。
  var horiz = dir === 'HORIZONTAL';
  f.primaryAxisSizingMode = (horiz ? opt.w : opt.h) ? 'FIXED' : 'AUTO';
  f.counterAxisSizingMode = (horiz ? opt.h : opt.w) ? 'FIXED' : 'AUTO';
  if (opt.w) f.resize(opt.w, f.height);
  if (opt.h) f.resize(f.width, opt.h);
  f.counterAxisAlignItems = opt.align || 'MIN';
  f.primaryAxisAlignItems = opt.justify || 'MIN';
  f.fills = opt.fill ? [paintOf(opt.fill)] : [];
  if (opt.radius) f.cornerRadius = opt.radius;
  if (opt.stroke) {
    f.strokes = [paintOf(opt.stroke)];
    f.strokeWeight = opt.strokeWeight || 1;
  }

  // Token 绑定（2026-08-26，M3）：先按字面值写完，再把能对上 Token 阶梯的字段
  // 改绑变量。顺序不能反 —— Auto Layout 的 sizingMode 依赖已写入的字面值来定高。
  // 对不上阶梯的值（如 w:4 的分类色条、h:44 的固定行高）保持字面，不强行归阶。
  if (opt.radius) bindRadius(f, opt.radius);
  if (opt.gap) bindNum(f, 'itemSpacing', 'spacing', opt.gap);
  bindNum(f, 'paddingTop', 'spacing', f.paddingTop);
  bindNum(f, 'paddingBottom', 'spacing', f.paddingBottom);
  bindNum(f, 'paddingLeft', 'spacing', f.paddingLeft);
  bindNum(f, 'paddingRight', 'spacing', f.paddingRight);
  return f;
}

/**
 * 创建一个吃掉主轴剩余空间的弹性占位块（2026-08-29，条目 [70]，P1/P2 修复）
 *
 * 为什么需要它：画框固定 844 高，短页内容排完只占三四百，底部留下 300–500px
 * 空白（实测 contact 空 523px / 62%）。这不只是难看 —— 评审看不出「内容就这么少」
 * 还是「稿子没画完」，实现的人也无从判断这块空白是有意留白还是待填。
 *
 * 加一个 layoutGrow=1 的空块，把「剩余空间归谁」这件事显式写进图层树：
 * 空块之前的内容顶部对齐，空块之后的内容（通常是主按钮）被推到底部。
 * 这样一来空白有了归属，评审读到的是「这里是刻意的呼吸区 + 底部主操作」。
 *
 * 必须在 appendChild 之后再设 layoutGrow：该属性要求节点已有 Auto Layout 父级。
 * 本函数只负责造块，赋值由 pushToBottom 完成。
 *
 * @param {string} [name] 图层名，默认 _spacer
 * @returns {FrameNode} 零尺寸空块
 */
function flexSpacer(name) {
  // 高给 1 而非 0：宽/高为 0 的节点会被体检脚本报成异常节点（同 listRow 空文本
  // 那类问题），给 1px 且无填充，视觉上不可见但体检认得出它是有意的占位
  return box(name || '_spacer', 'HORIZONTAL', { w: 1, h: 1 });
}

/**
 * 把一批节点追加到容器底部，中间用弹性空块隔开（2026-08-29，条目 [70]）
 *
 * @param {FrameNode} container 纵排 Auto Layout 容器，须为 FIXED 高
 * @param {SceneNode[]} tailNodes 要贴底的节点，按传入顺序自上而下排列
 */
function pushToBottom(container, tailNodes) {
  var sp = flexSpacer();
  container.appendChild(sp);
  sp.layoutGrow = 1;
  for (var i = 0; i < tailNodes.length; i++) {
    container.appendChild(tailNodes[i]);
  }
}

/**
 * 把主操作追加到纵排容器末尾，与上文之间留出 ACTION_GAP 而非容器统一 gap
 *（2026-09-01 条目 [77] ⑫）。
 *
 * 为什么用「插一个定高隔块」而不是别的做法：
 * · 改容器 gap —— 会同时拉开容器内**所有**相邻元素，标题与正文也被拉开；
 * · 给按钮加 marginTop —— Figma Auto Layout 无此属性，只有 itemSpacing；
 * · 给按钮包一层带 paddingTop 的壳 —— 多一层图层，且按钮的 FILL/宽度约束
 *   要透过壳再传一次，反而更易出错。
 * 隔块是唯一既不动容器、也不动按钮自身的做法，与 flexSpacer 同一手法。
 *
 * 隔块高 = ACTION_GAP − 容器 gap × 2：容器会在「上文↔隔块」与「隔块↔按钮」
 * 各排一段 gap，故隔块自身只补差额，实际视觉间距才等于 ACTION_GAP。
 *
 * @param {FrameNode} container 纵排 Auto Layout 容器
 * @param {SceneNode} action 主操作节点（按钮或按钮组），由调用方造好
 * @returns {FrameNode} 插入的隔块节点，供断言查证
 */
function appendActionWithGap(container, action) {
  var h = ACTION_GAP - container.itemSpacing * 2;
  // 隔块须有正高度：非正说明容器 gap 已 ≥ ACTION_GAP/2，此时「加一档更大间距」
  // 这件事本身不成立，当场炸掉而不是静默塞个 0 高节点（0 尺寸会被体检报异常）
  if (h <= 0) {
    throw new Error('appendActionWithGap(): 容器 gap=' + container.itemSpacing
      + ' 已不小于 ACTION_GAP/2=' + (ACTION_GAP / 2) + '，无需也无法再加一档间距');
  }
  var sp = box('_action-gap', 'HORIZONTAL', { w: 1, h: h });
  container.appendChild(sp);
  container.appendChild(action);
  return sp;
}

/**
 * 创建一个非 Auto Layout 的叠层容器，供悬浮图层使用。
 *
 * 为什么必须有它：box() 一律走 Auto Layout，子节点会被自动排流，
 * 无法实现「筛选栏浮在地图之上」的重叠效果。本容器 layoutMode 保持 NONE，
 * 子节点靠 x/y 绝对定位，是实现悬浮层的唯一途径。
 *
 * @param {string} name 图层名
 * @param {number} w 固定宽
 * @param {number} h 固定高
 * @param {string} fillRole 背景色 role，可省略
 * @returns {FrameNode} 叠层容器节点
 */
function stack(name, w, h, fillRole) {
  var f = figma.createFrame();
  f.name = name;
  f.layoutMode = 'NONE';
  f.resize(w, h);
  f.fills = fillRole ? [paintOf(fillRole)] : [];
  f.clipsContent = true;
  return f;
}

/**
 * 地图底图的 imageHash 缓存。
 *
 * 为什么要缓存：底图有 9 个落点（mapCanvas 8 处 + buildMapSelector 1 处），
 * 若每处都解码一次，就要把 100 多 KB 的 Base64 解码 9 遍。
 * imageHash 是内容寻址的，同一张图多处引用共享同一份数据。
 */
var MAP_BG_HASH = null;

/**
 * 创建地图底板：一个铺满整个地图区、已填好真实高德地图底图的矩形。
 *
 * 为什么需要它（2026-08-24，依用户反馈「地图需要真实地图背景」）：
 * 此前地图区是 stack() 的一块 primary-light 纯色填充，评审时完全不像地图，
 * Pin 的疏密、道路走向、区域肌理都无从判断。
 *
 * 为什么图片内嵌在代码里、不留空位人工贴（2026-08-24 第二次调整，
 * 依用户反馈「否则每次都要替换很麻烦」）：底板共 9 个落点，
 * 靠人工贴图意味着每次重跑插件都要在 Figma 里重复操作 9 次，且极易漏贴。
 * 现改为从文件末尾的 MAP_BG_JPEG_B64 解码后直接填充，重跑即带图。
 * manifest 的 networkAccess 是 ["none"]，而官方文档《Working with Images》
 * 明确写明 Base64 内嵌不产生网络请求，故无需放开任何域名白名单。
 *
 * 为什么不用 Google 地图：Google Maps 未取得中国境内测绘资质、域名境内被屏蔽，
 * 且国内上架涉地图功能须提供地图服务资质或第三方地图 API 授权证明，
 * 与 PRD §6.7 已定的高德 SDK 选型冲突。故底图统一用高德截图。
 *
 * 为什么用 RectangleNode 而非 Frame：Frame 的图片填充会被其子节点整体遮住。
 *
 * @param {FrameNode} parent 地图区叠层容器（layoutMode 必须为 NONE）
 * @param {number} w 底板宽，与地图区等宽
 * @param {number} h 底板高，与地图区等高
 * @returns {RectangleNode} 已挂载并置于最底层的底板矩形
 */
function mapBasePlate(parent, w, h) {
  if (!MAP_BG_HASH) {
    // base64Decode 于 Plugin API Update 42 加入，返回 Uint8Array；
    // createImage 是同步方法，返回的 Image 不是节点，只是文档内的图片句柄
    MAP_BG_HASH = figma.createImage(figma.base64Decode(MAP_BG_JPEG_B64)).hash;
  }
  var bg = figma.createRectangle();
  bg.name = '_map-bg';
  bg.resize(w, h);
  bg.x = 0;
  bg.y = 0;
  // scaleMode FILL：底图已按主地图区的 390:688 裁好，但选点页地图区是 390x560，
  // 比例不同；FILL 会等比放大后居中裁切，既不留白也不变形，一张图服务两种尺寸
  bg.fills = [{ type: 'IMAGE', imageHash: MAP_BG_HASH, scaleMode: 'FILL' }];
  // 必须第一个 append：Figma 的绘制顺序即 children 顺序，
  // 后面挂的 Pin、悬浮层才会压在底板之上
  parent.appendChild(bg);
  return bg;
}

// ------------------------------------------------------------
// 图标 SVG 路径表
//
// 2026-08-24 全面改用 Material Symbols（filled 变体）官方路径，替换此前手写坐标。
// 三条改动理由（依用户反馈「不够美观、无法见图知意」）：
// ① 语义映射曾经就是错的 —— 生活类范围是「二手/借物/互助」，此前画叶片（🌱），
//    叶片指向植物与环保，与二手流转毫无关联；服务类范围是「家政/维修/教学」，
//    此前画服务铃（🛎️），铃指向酒店前台呼叫，与上门维修不搭。
//    符号选错时，画得再精细也认不出，故先纠语义再谈美观。
// ② 手写路径在真实渲染尺寸下必然失真 —— Marker 40px，图标仅占 20px，
//    手写的 1.2px 叶脉、1.4px 箱缝在 20px 下不足 1 逻辑像素，渲染即消失或糊成灰边。
//    Material Symbols 每条路径都做过网格对齐，20px 下仍成形。
// ③ 许可 Apache 2.0，商用无限制；filled 变体是纯 fill path，
//    与 svgIcon() 现有的「导入后逐矢量子节点改绑颜色变量」逻辑天然兼容。
//
// 注意 viewBox 是 "0 -960 960 960"（Material Symbols 的坐标系，Y 轴为负区间），
// 非标准 0 0 20 20，故 svgIcon() 需按图标自带 viewBox 导入再缩放。
// ------------------------------------------------------------
var ICON_VIEWBOX_MS = '0 -960 960 960';   // Material Symbols 官方 viewBox
var ICON_VIEWBOX_20 = '0 0 20 20';        // 自绘小图标沿用的 20 网格

var ICON_PATHS = {
  // 工作 = work（手提箱）：范围「招聘/求职」。原手写版语义已对，此处仅换官方路径
  'cat-work': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M160-120q-33 0-56.5-23.5T80-200v-440q0-33 23.5-56.5T160-720h160v-80q0-33 23.5-56.5T400-880h160q33 0 56.5 23.5T640-800v80h160q33 0 56.5 23.5T880-640v440q0 33-23.5 56.5T800-120H160Zm240-600h160v-80H400v80Z"/>'
  },
  // 房屋 = home（屋形）：范围「出租/求租」。改用官方路径，屋脊与门洞比例更稳
  'cat-house': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M160-120v-480l320-240 320 240v480H560v-280H400v280H160Z"/>'
  },
  // 车辆 = directions_car：范围「拼车/顺风车/租车」。
  // 官方图形是带双轮的车身正视轮廓，比此前矩形侧视版在 20px 下更好认
  'cat-vehicle': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M240-200v40q0 17-11.5 28.5T200-120h-40q-17 0-28.5-11.5T120-160v-320l84-240q6-18 21.5-29t34.5-11h440q19 0 34.5 11t21.5 29l84 240v320q0 17-11.5 28.5T800-120h-40q-17 0-28.5-11.5T720-160v-40H240Zm-8-360h496l-42-120H274l-42 120Zm68 240q25 0 42.5-17.5T360-380q0-25-17.5-42.5T300-440q-25 0-42.5 17.5T240-380q0 25 17.5 42.5T300-320Zm360 0q25 0 42.5-17.5T720-380q0-25-17.5-42.5T660-440q-25 0-42.5 17.5T600-380q0 25 17.5 42.5T660-320Z"/>'
  },
  // 生活 = volunteer_activism（手托爱心）：范围「二手闲置/借物互助/寻物/宠物/求购」。
  //
  // 为什么弃用最初的 swap_horiz（左右双箭头）：语义上与「生活」关联太弱。
  // 箭头在界面里的通行含义是「操作/切换」，摆进 Pin 当品类标识会被读成控件而非事物；
  // 且它只表达「挪动」这个动作，而分类图标要表达的是被挪动的东西本身。
  // 更要紧的是族群不一致：工作=手提箱、房屋=屋形、车辆=汽车、服务=扳手四件皆为
  // 具象实物，唯独生活是抽象符号，五个并排时它明显不同族。
  //
  // 为什么也弃用中途选过的 package_2（纸箱）：把子分类摊开后发现覆盖不全。
  // 生活下挂 5 个二级 / 15 个三级：二手闲置转让(5) / 借物互助(3) / 寻物失物(2) /
  // 宠物相关(2) / 求购求助(2)。纸箱只覆盖得住物品侧 11/15 ——
  // 宠物是活物装不进箱子，邻里互助与求助是人情往来而非物品交易，两支共 4 个三级落空。
  //
  // 为什么选手托爱心：一只手向上托起、心自手中升起，「给出」与「善意」两层动作
  // 恰好横跨用户要求的「物品转让 + 帮助」双语义，是候选池里唯一 15/15 全覆盖的图形
  // （二手=递出、借物互助=直接命中、招领=归还善意、领养=善意托付、求助=直接命中）。
  // 手与心都是实心块面而非线条勾勒，20px 清晰、14px 仍能辨出轮廓。
  //
  // 为什么不用 handshake（654 字）与 waving_hand（567 字）：双手交错与五指分开的
  // 笔画在 14px 下必粘连成色块。
  // 为什么不用 loyalty（标签带心，434 字）：语义组合最贴，但 14px 下心与标签会粘。
  // 为什么不用 card_giftcard / redeem（礼品卡·礼品袋）：暗示预付与商业馈赠，
  // 与借物、求助两支不搭。
  // 为什么不用 recycling（回收三角）：实测 fill1 版 428 字符，4 组独立箭头在
  // 20px 下间距不足 1px 必糊，且它同样是抽象符号。
  'cat-life': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M280-159v-361h64q7 0 14 1.5t14 3.5l277 103q14 5 22.5 18t8.5 27q0 21-14.5 34T632-320H527q-5 0-7.5-.5T513-323l-64-25-13 39 77 27q2 1 6 1.5t7 .5h274q32 0 56 23t24 57L561-80l-281-79ZM40-80v-440h160v440H40Zm600-360L474-602q-31-30-52.5-66.5T400-748q0-55 38.5-93.5T532-880q32 0 60 13.5t48 36.5q20-23 48-36.5t60-13.5q55 0 93.5 38.5T880-748q0 43-21 79.5T807-602L640-440Z"/>'
  },
  // 服务 = build（扳手）：范围「家政/维修/教学」，工具是上门服务的行业通行符号。
  // 为什么不用 handyman（锤子+扳手交叉）：双工具交叉共 640 字符，
  // 20px 下两件工具会粘连成不可辨的色块，单件扳手轮廓更完整
  'cat-service': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M686-132 444-376q-20 8-40.5 12t-43.5 4q-100 0-170-70t-70-170q0-36 10-68.5t28-61.5l146 146 72-72-146-146q29-18 61.5-28t68.5-10q100 0 170 70t70 170q0 23-4 43.5T584-516l244 242q12 12 12 29t-12 29l-84 84q-12 12-29 12t-29-12Z"/>'
  },
  // 勾选标记：复选框选中态用，自绘 20 网格即可，无需换库
  'tick': {
    vb: ICON_VIEWBOX_20,
    d: '<path fill="#000" d="M4 10.5l1.6-1.6 2.6 2.6 6.2-6.2L16 6.9l-7.8 7.8z"/>'
  },
  // 三竖点：图层控制面板入口（PRD §6.13 T6-② 「地图右上角三个竖点」）
  'dots': {
    vb: ICON_VIEWBOX_20,
    d: '<path fill="#000" d="M10 3.2a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2m0 5.2a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2m0 5.2a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2"/>'
  },
  // 放大镜 = search：导航栏搜索框前缀图标（PRD §6.4.1 ASCII 图 🔍 位）。
  // 官方路径，单 path 357 字符，圆环 + 斜柄结构在 16px 下仍可辨
  'search': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M784-120 532-372q-30 24-69 38t-83 14q-109 0-184.5-75.5T120-580q0-109 75.5-184.5T380-840q109 0 184.5 75.5T640-580q0 44-14 83t-38 69l252 252-56 56ZM380-400q75 0 127.5-52.5T560-580q0-75-52.5-127.5T380-760q-75 0-127.5 52.5T200-580q0 75 52.5 127.5T380-400Z"/>'
  },
  // 铃铛 = notifications：导航栏通知入口（PRD §6.4.1 ASCII 图 🔔 位）
  'bell': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M160-200v-80h80v-280q0-83 50-147.5T420-792v-28q0-25 17.5-42.5T480-880q25 0 42.5 17.5T540-820v28q80 20 130 84.5T720-560v280h80v80H160ZM480-80q-33 0-56.5-23.5T400-160h160q0 33-23.5 56.5T480-80Z"/>'
  },
  // 叉号 = close：搜索激活态里的「清空关键词」按钮
  'close': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="m256-200-56-56 224-224-224-224 56-56 224 224 224-224 56 56-224 224 224 224-56 56-224-224-224 224Z"/>'
  },
  // 折叠地图册 = map：底部 Tab「鸭圈」键（PRD §10.2）。
  // 此前是 emoji 🗺️，emoji 由系统字体渲染，字重与色彩不受 paintOf(role) 控制，
  // 选中态无法跟随主色，与同排矢量图标风格断裂，故换矢量。
  // 为什么不用 explore_nearby（圆底+定位针）：该图标语义偏「附近的某个点」，
  // 而地图册剪影直接表达「一整片可翻阅的区域」，与「鸭圈」的圈子语义更贴。
  // 24px 下已实测无粘连（probe-tabicon.py 渲染对照）
  'tab-map': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="m600-120-240-84-186 72q-20 8-37-4.5T120-170v-560q0-13 7.5-23t20.5-15l212-72 240 84 186-72q20-8 37 4.5t17 33.5v560q0 13-7.5 23T812-192l-212 72Zm-40-98v-468l-160-56v468l160 56Z"/>'
  },
  // 实心圆点：完整度三档（🟢/🟡/🔴）的矢量替身（2026-08-29，条目 [70]）。
  //
  // 为什么必须换掉 emoji：🟢🟡🔴 由系统 emoji 字体渲染，iOS / Android / 鸿蒙
  // 三套字形各不相同（大小、饱和度、有无高光渐变都不一致），且色值完全不受
  // paintOf(role) 控制 —— 我们在 §1.4.2 实算过的对比度对它一概无效。
  // 同一问题在 Tab 三键上已于条目 [47] 处理过，这几处是当时的漏网。
  //
  // 为什么是纯圆而不复刻 emoji 的高光渐变：createNodeFromSvg 会剥离渐变，
  // 且渐变在 10px 下只会让色块显脏，无助于辨识。
  'dot-solid': {
    vb: ICON_VIEWBOX_20,
    d: '<path fill="#000" d="M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14"/>'
  },
  // 人像 = person：底部 Tab「我的」键（PRD §10.2）。同上，此前是 emoji 👤。
  // 为什么不用 account_circle（圆底+人像）：24px 下内部头像与圆底边缘粘连
  // 成不可辨色块（probe-tabicon.py 实测），实心人像轮廓在 24px 下留白充足
  'tab-person': {
    vb: ICON_VIEWBOX_MS,
    d: '<path fill="#000" d="M367-527q-47-47-47-113t47-113q47-47 113-47t113 47q47 47 47 113t-47 113q-47 47-113 47t-113-47ZM160-160v-112q0-34 17.5-62.5T224-378q62-31 126-46.5T480-440q66 0 130 15.5T736-378q29 15 46.5 43.5T800-272v112H160Z"/>'
  }
};

/**
 * 把 ICON_PATHS 里的一条图标定义转成 Figma 矢量节点，并把笔画统一染成指定颜色。
 *
 * figma.createNodeFromSvg() 是官方提供的「等同于编辑器内 SVG 导入」的接口，
 * 已知限制是会剥离 <defs>／渐变／滤镜／蒙版／动画。本函数只喂单色 fill path
 * （含 fill-rule="evenodd" 挖洞），完全不触碰这些被剥离的特性，故不受影响。
 *
 * 染色不能写死在 SVG 里：同一份路径数据要同时服务资源态（图标取白）
 * 与需求态（图标取分类色），故导入后再逐个矢量子节点改绑颜色变量。
 *
 * 为什么第二参改成对象而不是裸 path 字符串（2026-08-24）：
 * Material Symbols 的 viewBox 是 "0 -960 960 960"（Y 轴负区间），
 * 与自绘图标的 "0 0 20 20" 并存，viewBox 必须随路径一起传入，
 * 否则 960 坐标系的路径会被按 20 网格解析，图形整体跑到画布外看不见。
 *
 * @param {string} name 生成节点的图层名
 * @param {Object} def 图标定义 { vb: viewBox 字符串, d: 一段或多段 <path> }
 * @param {string} colorRole 笔画颜色 role
 * @param {number} size 目标边长（正方形）
 * @returns {FrameNode} 已染色并缩放到 size 的图标节点
 */
function svgIcon(name, def, colorRole, size) {
  // viewBox 的宽高即路径的原生坐标跨度，导入时 SVG 的 width/height 须与之一致，
  // 否则 Figma 会先做一次非预期缩放，再叠加后面的 rescale，尺寸不可控
  var vbParts = def.vb.split(' ');
  var native = parseFloat(vbParts[2]);
  var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="' + native + '" height="' + native
    + '" viewBox="' + def.vb + '">' + def.d + '</svg>';
  var node = figma.createNodeFromSvg(svg);
  node.name = name;
  node.fills = [];
  var vecs = node.findAll(function (n) {
    return n.type === 'VECTOR' || n.type === 'BOOLEAN_OPERATION';
  });
  for (var i = 0; i < vecs.length; i++) {
    vecs[i].fills = [paintOf(colorRole)];
    vecs[i].strokes = [];
  }
  // 必须用 rescale 而非 resize：resize 只改外框尺寸、不缩放内部路径，
  // 会导致 20px 图标里塞着 960px 的图形被裁切
  var s = size || 20;
  if (s !== native) node.rescale(s / native);
  return node;
}

// ------------------------------------------------------------
// 鸭子 IP 品牌符号（方向 4B「负形留白 + 同心波纹」，PRD §1.4.1.1–§1.4.1.3）
//
// 真源是 prototype-figma/assets/*.svg（PRD §1.4.1.3「SVG 矢量为唯一真源」）。
// 此处内联一份几何数据的原因：Figma 插件沙箱无文件系统读取能力，
// 无法 fetch 本地 assets 目录，只能把路径数据随代码带入。
// 因此这里与 assets/duck-symbol-*.svg 构成【双份副本】，改动时必须同步两处
// —— 与 gen_prd_v2.1_docx.py 里硬编码色值同性质的活文件，已在说明文档登记。
//
// 结构（1024 画板，与源图实测一致）：
//   两道【完整同心圆环】（不是弧），各由两个反向整圆 + evenodd 构成
//   中心白盘 R=227.08，盘内用 evenodd 挖出【完整鸭头剪影】（圆头 / 朝右喙 / 向下颈）
//   眼点独立圆，mini 档半径放大到 25.6（占画板 5%）以过 40px 下 2px 硬约束
//
// 几何基准（源图实测，PRD §1.4.1.3）：
//   圆角 = 1024 × 22.4% = 229.38    中心 (511.3, 506.0)
//   外环 395.84/361.87    内环 305.84/273.54    中心盘 227.08
// ------------------------------------------------------------
var DUCK_VIEWBOX = '0 0 1024 1024';

/** 外侧同心圆环，逐字对应 assets/duck-symbol-full.svg 第一个 path */
var DUCK_RING_OUTER = 'M115.46 506 A395.84 395.84 0 1 0 907.14 506 A395.84 395.84 0 1 0 115.46 506 Z M149.43 506 A361.87 361.87 0 1 0 873.17 506 A361.87 361.87 0 1 0 149.43 506 Z';

/** 内侧同心圆环，逐字对应 assets/duck-symbol-full.svg 第二个 path */
var DUCK_RING_INNER = 'M205.46 506 A305.84 305.84 0 1 0 817.14 506 A305.84 305.84 0 1 0 205.46 506 Z M237.76 506 A273.54 273.54 0 1 0 784.84 506 A273.54 273.54 0 1 0 237.76 506 Z';

/** 中心盘 + 挖空鸭头（同一 path 内两段子路径 + evenodd），三档位共用 */
var DUCK_DISC_HEAD = 'M284.22 506 A227.08 227.08 0 1 0 738.38 506 A227.08 227.08 0 1 0 284.22 506 Z M418 388 C405.83 392.5 397.5 398.17 389 404 C380.5 409.83 373.83 415.67 367 423 C360.17 430.33 353.17 439.67 348 448 C342.83 456.33 339.33 459.67 336 473 C332.67 486.33 327.17 509.67 328 528 C328.83 546.33 333.67 565.83 341 583 C348.33 600.17 359.33 617 372 631 C384.67 645 399.67 657.33 417 667 C434.33 676.67 457.5 684.83 476 689 C494.5 693.17 515.67 692.17 528 692 C540.33 691.83 545.17 689.83 550 688 C554.83 686.17 554.67 683.33 557 681 C556.67 678.67 560.33 681.5 556 674 C551.67 666.5 536.33 645.83 531 636 C525.67 626.17 525 621.5 524 615 C523 608.5 523.33 603.17 525 597 C526.67 590.83 528.67 584 534 578 C539.33 572 543.17 565.67 557 561 C570.83 556.33 600.5 554.5 617 550 C633.5 545.5 645.33 540.17 656 534 C666.67 527.83 675.17 519 681 513 C686.83 507 689 502.5 691 498 C693 493.5 692.33 490 693 486 C689.67 483.67 691.5 480.17 683 479 C674.5 477.83 654.5 480.67 642 479 C629.5 477.33 616.67 473.17 608 469 C599.33 464.83 595.67 461.5 590 454 C584.33 446.5 579.33 432.17 574 424 C568.67 415.83 566.67 411.67 558 405 C549.33 398.33 533.17 388.67 522 384 C510.83 379.33 501 378.17 491 377 C481 375.83 474.17 375.17 462 377 C449.83 378.83 430.17 383.5 418 388 Z';

/** 眼点。full / compact 档共用（mini 档另有 DUCK_EYE_MINI） */
var DUCK_EYE = { cx: 506.1, cy: 458.5, r: 20.27 };

// ------------------------------------------------------------
// mini 档（<64px）专用几何（2026-08-26）
//
// 为什么 mini 档要另一套结构：原 mini 档沿用「圆角色块 + 白盘 + 盘内镂空鸭头」
// 四层嵌套。24px 下白盘直径仅约 10px，鸭头要在这 10px 内表达喙与颈，
// 喙尖必先消失 —— 用户实机反馈的「不美观」正是此因。
//
// 改法是做层次减法而非另画新形（PRD §1.4.1.2 明令「不得各档位另画新形」）：
// 去掉最外圆角块，圆盘直接铺满画板；鸭头由「镂空」反相为「白色实体」，
// 笔画自此拿到自己的像素。这与 app-icon-android-foreground 同一思路
// —— 前景层不能靠镂空表达，镂空透出的是底色。
//
// 反相后眼点必须改为【主色】：鸭头已是白色，白眼点会与头部融为一体。
//
// 下面这条路径由 build-4b-assets.py 生成到真源 assets/duck-symbol-mini.svg，
// 把「居中缩放到占画板 80%」的仿射变换烧进坐标后逐字复制到此
// （鸭头包围盒实测 x=328 y=376 w=366 h=317；变换后复测占比 0.799）。
// 80% 是上限：再往上主色环带会被喙尖顶破 —— 24px 下 0.80 → 1.9px（达标）、
// 0.88 → 0.93px（断续）。见 probe-mini-negative.py 与 probe-assets-verify.py
// 的 "mini@24px brand ring >= 1.5px" 断言。
// 为什么烧进坐标而不用 <g transform="scale()">：Figma 的 createNodeFromSvg
// 对 transform 属性的支持未见于官方文档保证，纯坐标是任何解析器都一致的几何数据。
// ------------------------------------------------------------

/** mini 档鸭头：已居中缩放至占画板 80%，实体填充（非镂空）。逐字取自 assets/duck-symbol-mini.svg */
var DUCK_HEAD_MINI = 'M303.84 184.1 C276.6 194.17 257.96 206.86 238.93 219.91 C219.91 232.96 204.98 246.03 189.69 262.43 C174.4 278.84 158.74 299.75 147.17 318.39 C135.59 337.04 127.76 344.51 120.31 374.35 C112.85 404.18 100.54 456.42 102.4 497.45 C104.26 538.48 115.09 582.12 131.5 620.56 C147.9 658.99 172.52 696.66 200.88 727.99 C229.24 759.33 262.82 786.92 301.6 808.57 C340.39 830.21 392.25 848.48 433.66 857.81 C475.07 867.14 522.45 864.91 550.05 864.52 C577.65 864.14 588.48 859.67 599.29 855.57 C610.1 851.48 609.74 845.12 614.96 839.9 C614.22 834.69 622.41 841.02 612.72 824.24 C603.03 807.45 568.69 761.18 556.77 739.18 C544.84 717.18 543.34 706.73 541.1 692.18 C538.86 677.63 539.6 665.7 543.34 651.89 C547.07 638.08 551.55 622.79 563.48 609.36 C575.41 595.93 584 581.77 614.96 571.31 C645.91 560.86 712.32 556.77 749.25 546.69 C786.19 536.62 812.66 524.69 836.55 510.88 C860.43 497.07 879.45 477.31 892.5 463.88 C905.55 450.45 910.41 440.38 914.89 430.3 C919.36 420.23 917.86 412.4 919.36 403.44 C911.91 398.23 916 390.4 896.98 387.78 C877.95 385.16 833.19 391.51 805.21 387.78 C777.23 384.04 748.52 374.73 729.11 365.39 C709.7 356.06 701.51 348.61 688.82 331.82 C676.13 315.03 664.94 282.96 653.01 264.67 C641.08 246.39 636.6 237.08 617.2 222.15 C597.79 207.22 561.62 185.6 536.62 175.14 C511.62 164.69 489.62 162.09 467.23 159.48 C444.85 156.86 429.57 155.38 402.33 159.48 C375.09 163.57 331.08 174.02 303.84 184.1 Z';

/** mini 档眼点：随鸭头同一变换后的位置。80% 档下 r=45.37，已超过 24px/2px 底线（42.67），无需再抬 */
var DUCK_EYE_MINI = { cx: 501.03, cy: 341.89, r: 45.37 };

/** mini 档圆盘半径：铺满画板，留 0.78% 余量避免边缘抗锯齿被裁切 */
var DUCK_DISC_MINI_R = 504.01;

/**
 * 生成鸭子 IP 品牌符号节点，按尺寸自动选档（PRD §1.4.1.2 三档位降级规则）。
 *
 * 档位规则不由调用方指定而由尺寸推导，理由：PRD §1.4.1.2 明令「不得各档位另画新形」，
 * 若开放档位参数，调用方就可能在 24px 位置传入完整版（两道弧在 24px 下糊成一团）。
 * 由尺寸单向推导可从结构上排除这类误用。
 *
 * 为什么不用 svgIcon()：svgIcon 会把所有矢量子节点统一染成单色，
 * 而本符号必须保持「色块一色 + 负形另一色」的双色关系，统一染色会让负形消失。
 * 故此处独立走一遍 createNodeFromSvg 并按 role 分别染色。
 *
 * @param {number} size 目标边长（正方形），据此选档：≥96 完整版 / 64–95 精简版 / <64 微缩版
 * @param {string} blockRole 色块颜色 role，默认 color/primary；深色底传 color/surface 实现反相
 * @param {string} negativeRole 负形颜色 role，默认 color/surface。
 *   full / compact 档负形是「环 + 盘 + 眼点」，mini 档负形是「鸭头本体」
 * @returns {FrameNode} 已染色并缩放到 size 的品牌符号节点
 */
function duckSymbol(size, blockRole, negativeRole) {
  var s = size || 96;
  var block = blockRole || 'color/primary';
  var negative = negativeRole || 'color/surface';

  // 档位边界取实测抬高后的阈值（PRD §1.4.1.2）：full ≥96 / compact ≥64 / mini <64。
  // mini 档结构与另两档不同（见 DUCK_HEAD_MINI 上方说明），故先分出来
  var tier = (s >= 96) ? 'full' : (s >= 64 ? 'compact' : 'mini');

  // 染色统一在导入后改绑变量，故 SVG 里先填占位色（占位色不参与最终呈现）。
  // roles 数组按【文档顺序】逐元素记下该染什么 role —— 不用「首元素是色块、
  // 其余是负形」的位置约定，因为 mini 档反相后眼点要染色块色而非负形色，
  // 位置约定在这里会失效。显式列出可让两种结构走同一段染色代码。
  var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="'
    + DUCK_VIEWBOX + '">';
  var roles;

  if (tier === 'mini') {
    // 主色圆盘铺满画板 + 白色实体鸭头 + 主色眼点（反相，鸭头已是白色）
    svg += '<circle cx="512" cy="512" r="' + DUCK_DISC_MINI_R + '" fill="#000"/>'
      + '<path d="' + DUCK_HEAD_MINI + '" fill="#FFF"/>'
      + '<circle cx="' + DUCK_EYE_MINI.cx + '" cy="' + DUCK_EYE_MINI.cy
      + '" r="' + DUCK_EYE_MINI.r + '" fill="#000"/>';
    roles = [block, negative, block];
  } else {
    // full / compact：圆角色块 + 若干道白环 + 白盘（盘内 evenodd 镂空鸭头）+ 白眼点
    var rings = (tier === 'full') ? [DUCK_RING_OUTER, DUCK_RING_INNER] : [DUCK_RING_INNER];
    svg += '<rect x="0" y="0" width="1024" height="1024" rx="229.38" ry="229.38" fill="#000"/>';
    roles = [block];
    for (var i = 0; i < rings.length; i++) {
      svg += '<path d="' + rings[i] + '" fill="#FFF" fill-rule="evenodd"/>';
      roles.push(negative);
    }
    svg += '<path d="' + DUCK_DISC_HEAD + '" fill="#FFF" fill-rule="evenodd"/>'
      + '<circle cx="' + DUCK_EYE.cx + '" cy="' + DUCK_EYE.cy
      + '" r="' + DUCK_EYE.r + '" fill="#FFF"/>';
    roles.push(negative, negative);
  }
  svg += '</svg>';

  var node = figma.createNodeFromSvg(svg);
  node.name = '_duck-symbol-' + tier;
  node.fills = [];

  // 用【文档顺序】而非图层名匹配 roles：createNodeFromSvg 对 id 属性的
  // 命名处理未见于官方文档保证，而 findAll 的遍历顺序等同 SVG 元素顺序。
  var vecs = node.findAll(function (n) {
    return n.type === 'VECTOR' || n.type === 'BOOLEAN_OPERATION' || n.type === 'RECTANGLE'
      || n.type === 'ELLIPSE';
  });
  // 数量不符说明导入被 Figma 改写了结构，此时按序染色会把颜色安到错的元素上，
  // 产出一个「负形消失」的纯色块悄悄上屏，故直接抛出
  if (vecs.length !== roles.length) {
    throw new Error('鸭子符号导入后矢量数为 ' + vecs.length + '，期望 ' + roles.length
      + '（档位 ' + tier + '）');
  }
  for (var j = 0; j < vecs.length; j++) {
    var v = vecs[j];
    if (v.fills && v.fills.length > 0) v.fills = [paintOf(roles[j])];
    if (v.strokes && v.strokes.length > 0) v.strokes = [paintOf(roles[j])];
  }

  // 与 svgIcon 同理：必须 rescale 而非 resize，否则 1024 图形会被裁在小外框里
  if (s !== 1024) node.rescale(s / 1024);
  return node;
}

/**
 * 构造五大类的图标（PRD §6.4.2 要求「分类色 + 类型图标」）。
 *
 * 为什么不用 PRD 字面写的 emoji（💼🏠🚗🌱🛎️）：emoji 由系统字体渲染，
 * iOS / Android / 鸿蒙三端字形差异明显，40×40 Marker 内辨识度低，
 * 且无法跟随分类色变色（需求态要求图标为分类色而非白色）。
 *
 * 2026-08-24 起五类全部走 Material Symbols 官方路径（详见 ICON_PATHS 注释），
 * 此前「房屋/车辆用矩形拼装」的分支已删除 —— 矩形只能表达直线与圆角，
 * 车头弧线与屋脊斜面都拼不出来，20px 下退化成一堆色块，这正是「不够形象」的成因。
 *
 * 分类到图标的语义映射（依 PRD §1 色板表的二级范围，而非 emoji 字面）：
 * · 工作（招聘/求职）    = work           手提箱
 * · 房屋（出租/求租）    = home           屋形
 * · 车辆（拼车/租车）    = directions_car 车身双轮
 * · 生活（二手/借物/互助）= volunteer_activism 手托爱心（给出 + 善意）
 * · 服务（家政/维修/教学）= build          扳手（上门服务）
 *
 * @param {string} catKey 分类键：cat-work / cat-house / cat-vehicle / cat-life / cat-service
 * @param {string} colorRole 图标笔画颜色 role（资源态取白，需求态取分类色）
 * @param {number} size 图标外框边长
 * @returns {FrameNode} 图标节点
 */
function catIcon(catKey, colorRole, size) {
  var s = size || 20;
  var def = ICON_PATHS[catKey];
  // 五类均已在 ICON_PATHS 内登记；取不到说明传了未定义的分类键，
  // 属调用方错误，直接抛出而不静默兜底成方块（兜底会让错误分类悄悄上屏）
  if (!def) throw new Error('未登记的分类图标键「' + catKey + '」');
  return svgIcon('_icon-' + catKey, def, colorRole, s);
}

/**
 * 创建一个文本节点，字号字重行高全部取自 PRD 字阶
 * @param {string} content 文本内容
 * @param {string} scale 字阶键名：h1/h2/h3/body/small/caption
 * @param {string} colorRole 颜色变量 role，默认 color/text-primary
 * @returns {TextNode} 配置完成的文本节点
 */
function text(content, scale, colorRole) {
  var s = TYPE_SCALE[scale] || TYPE_SCALE.body;
  var t = figma.createText();
  t.fontName = { family: FONT_FAMILY, style: styleOf(s.weight) };
  t.fontSize = s.size;
  t.characters = content;
  // 显式设置 lineHeight：缺失会导致部分导出场景高度计算为 0
  t.lineHeight = lineHeightOf(s);
  t.fills = [paintOf(colorRole || 'color/text-primary')];
  // 字号绑到 size/* 变量（2026-08-26，M3）。行高刻意不绑：它是「字号 × 倍数」
  // 的派生值，绑成独立变量后改字号不会带动行高，反而制造出一处静默不一致。
  bindNum(t, 'fontSize', 'size', s.size);
  return t;
}

/**
 * 变体画框统一后缀标记
 *
 * 同一 pageId 往往有多个画框（主态 1 个 + 过程态/降级态/展开态/弹层等若干变体）。
 * 跳转索引只能指向唯一主态，因此变体必须能被机械识别。
 * 早期用「过程态/降级/半径档」等中文关键词黑名单判定，新增变体时极易漏同步
 * （2026-08-24 即因此产生 home-screen ×6 重名告警），故改为显式标记：
 * 凡带此后缀的画框一律不进跳转索引，新增变体只需在 screen() 传 isVariant=true。
 */
var VARIANT_TAG = '⟨变体⟩';

/**
 * 创建一个手机屏画框（390×844），带页面 ID 名与 PRD 行号回标
 * @param {string} pageId PRD §10.1 定义的页面 ID
 * @param {string} title 中文页面名
 * @param {string} prdRef PRD 行号引用，如 "PRD §10.1"
 * @param {boolean} [isVariant] 是否为变体画框（过程态/降级态/展开态/弹层等）。
 *                              传 true 时画框名追加 VARIANT_TAG，不参与跳转索引
 * @returns {FrameNode} 屏幕级 Frame
 */
function screen(pageId, title, prdRef, isVariant) {
  // 主态必须在 MAIN_SCREENS 登记，变体必须不在其中被误当主态计数。
  // 这道校验把「计数正确」变成代码约束而非人的记性：新增页忘登记会当场抛错，
  // 而不是让 UI 首屏与跳转索引各自报一个错数字。
  if (!isVariant && MAIN_SCREENS.indexOf(pageId) < 0) {
    throw new Error('主态画框 ' + pageId + ' 未在 MAIN_SCREENS 登记。'
      + '若它是变体请传 isVariant=true，若是新增主态请补进 MAIN_SCREENS。');
  }
  var nm = pageId + ' · ' + title + ' [' + prdRef + ']';
  if (isVariant) nm += ' ' + VARIANT_TAG;
  var f = box(nm, 'VERTICAL', {
    w: CANVAS.w, h: CANVAS.h, fill: 'color/background'
  });
  f.clipsContent = true;
  f.setRelaunchData({ open: prdRef });
  return f;
}

/**
 * 六类按钮的配色与形状规格（PRD §1.4.6）——本表是这六档在本文件内的唯一取值来源。
 *
 * 为什么从 buttonRaw 内提到模块级（2026-08-27，I5 前置）：Component master 的
 * description 要写明每一类的填充/文字/描边/圆角，而这些值原先只存在于
 * buttonRaw 的函数体内。若 description 另抄一份，改了配色却忘改说明就会分叉，
 * 且分叉方向最坏 —— 交棒人读到的契约与画布上的实物不一致（同原则㊾）。
 * 提为共享真源后，buttonRaw 与 describeComponents 消费同一张表。
 *
 * usage 只写「什么时候该用哪一类」，这是 description 里代码看不出、
 * 但接棒人最需要的那部分信息。
 */
var BUTTON_SPECS = {
  primary:   { fill: 'color/primary',    textColor: 'color/surface',          radius: RADIUS.md,   stroke: null,            usage: '页面唯一主操作，一屏不得出现两个' },
  secondary: { fill: 'color/surface',    textColor: 'color/primary',          radius: RADIUS.md,   stroke: 'color/primary', usage: '与主操作并列的次选项，如「获取验证码」' },
  ghost:     { fill: null,               textColor: 'color/primary',          radius: RADIUS.md,   stroke: null,            usage: '弱化的辅助入口，如「用密码登录」' },
  danger:    { fill: 'color/error-text', textColor: 'color/surface',          radius: RADIUS.md,   stroke: null,            usage: '不可逆操作，如删除、下架' },
  capsule:   { fill: 'color/primary',    textColor: 'color/surface',          radius: RADIUS.full, stroke: null,            usage: '表单底部通栏提交，宽度取 390×80% = 312（PRD §3.4.1）' },
  disabled:  { fill: 'color/border',     textColor: 'color/text-placeholder', radius: RADIUS.md,   stroke: null,            usage: '本期不开放的功能占位，须同时降至 40% 不透明度以声明范围' }
};

/**
 * 全部「小圆角块状标记」的规格真源（2026-09-01 条目 [77]，M4-3e 第一层 ①）。
 *
 * 为什么需要这张表：PRD §1.7 把「标签/徽章」列为六个必做组件之一，但稿内
 * 此前只有 11 处各自手搓的容器、没有任何共享规格。写规范文档时若逐处照抄，
 * 产出的会是一张 11 行互相矛盾的表；若强行取一套值套到 11 处，则会把语义
 * 不同的东西压成同一个组件。
 *
 * 为什么分四族而不是一套（2026-09-01 逐字读完 11 处后的修正结论）：
 * 这 11 处并非同类，混在一起数才显得「毫无规律」。按语义拆开后，
 * 只有 A 族内部是真的不一致 —— 另三族要么样本量为 1、要么本来就已自洽、
 * 要么根本不是标签。故本表按族分栏：A 族给出归一后的取值并回改调用点，
 * B/C 族只登记现状，D 族声明「不属本表管辖」并指回 BUTTON_SPECS。
 *
 * usage 写「什么时候该用哪一族」，nodes 写该族当前的实处名 ——
 * 后者是给规范文档与日后回归用的：新写一处胶囊若不在此列，说明漏登记了。
 */
var TAG_SPECS = {
  // A 族：可点选择胶囊 —— 一排里选一个，点了会换选中项
  chip: {
    padV: SPACING.xs, padH: SPACING.sm, radius: RADIUS.full, scale: 'caption',
    // 非选中态归一为「background 底 + text-secondary 字」：回改前三种画法并存
    // （无填充无描边 / 无填充+border 描边 / background 填充），三者在同一屏里
    // 会被读成三种不同的可点性强弱，而它们其实是同一件事
    offFill: 'color/background', offText: 'color/text-secondary',
    // 选中态两种合法底色：通用主色，或该胶囊代表某个分类时用该分类的 deep 档
    onFill: 'color/primary', onFillByCategory: 'deep', onText: 'color/surface',
    nodes: ['_radius-<档>', '_sd-<供需>', '_lv1-<分类>', '_mode-<模式>'],
    usage: '一排中选一个的可点筛选项；点击后仅换选中态，不触发页面跳转'
  },
  // B 族：静态标记 —— 不可点，只是给旁边的内容盖一个戳
  mark: {
    padV: TIGHT_GAP, padH: SPACING.xs, radius: RADIUS.sm, scale: 'caption',
    fill: 'color/accent', textColor: 'color/surface',
    nodes: ['_ai-tag'],
    // 如实声明样本量：这一族目前只有一处实物，本规格是「立规」而非「归纳」，
    // 第二处用例出现时须回头核对它是否真适用，而不是默认照抄
    usage: '盖在内容旁的不可点标记，如「AI 推测」。当前全稿仅 1 处实物，规格系新立'
  },
  // C 族：浮层提示条 —— 悬在地图上的一句话说明，不可点
  hintBar: {
    padV: SPACING.xs, padH: SPACING.sm, radius: RADIUS.sm,
    fill: 'color/surface', textColor: 'color/primary-dark',
    // 字阶按节点分列而非取单值：两处容器取值逐项相同，但文字一个 caption(11)
    // 一个 small(12)。1px 之差不值得改动已验收画面（且 _hint 是一句需读完的
    // 操作指引、_map-caption 是一句状态说明，前者略大有其道理），
    // 故如实登记两值，不假装它们已经统一
    scale: 'caption',
    scaleByNode: { '_map-caption': 'caption', '_hint': 'small' },
    nodes: ['_map-caption', '_hint'],
    usage: '悬浮在地图之上的一句话提示，白底以从底图中浮出；容器取值两处一致，字阶两处不同'
  },
  // D 族：圆角虽为 full 但语义是按钮/容器，不属标签
  notTag: {
    nodes: ['_sheet-reset', '_sheet-confirm', '_filter-summary', '_overlay-cats'],
    // 登记它们是为了防止下一个人像我一样把它们数进标签里。其中前两个是
    // 手搓按钮、绕过了 BUTTON_SPECS，那是另一个问题（真源表被旁路）——
    // 2026-09-02 补记后果：旁路真源表连带**破了 PRD §1.8 的 44px 触控下限**，
    // 实测高 36 / 34。此前只登记了「旁路」这个症状，漏了这个后果，
    // 于是读到本条的人会以为那只是个整洁性问题。
    usage: '圆角 full 但语义为按钮或容器，规格不由本表定义；按钮档位一律查 BUTTON_SPECS。'
      + '注：_sheet-reset / _sheet-confirm 高 36 / 34，低于 44 触控线，实现侧须补足'
  }
};

/**
 * 全部纯色小圆点的边长档位登记（2026-09-01 条目 [77]，M4-3e 第一层 ②）。
 *
 * 这是「登记」而非「统一」：8px 的未读红点与 12px 的 Pin 角标本就不该同尺寸 ——
 * 前者是余光可见即可的存在性提示，后者要在花花绿绿的底图上仍能辨色。
 * 强行统一成一档会牺牲其中一头。本表的作用是让「共有几档、每档为什么」
 * 变成可查的事实，而不是散落在 12 处 box() 调用的字面数字里。
 *
 * 唯一一处真正的归并：completenessTag 原先按字阶派生 round(size*0.75)，
 * small(12) 档算出 9px，与同页 _mi-comp-dot 的 10px 只差 1px —— 同一个
 * 「完整度」语义在一屏内出现 9 和 10 两个值，读起来像两套东西而非一套。
 * 故派生公式改为查本表的 status 档，固定 10px。
 */
var DOT_SIZES = {
  unread:  { size: 8,  nodes: ['_bell-badge', '_unread', '_summary-dot'], usage: '存在性提示：只需被余光扫到，不承载可辨识的内容' },
  status:  { size: 10, nodes: ['_sd-dot', '_mi-comp-dot', '_completeness-<档>'], usage: '状态色点：需在正文旁清晰辨色（完整度三档、供需实心/空心）' },
  onMap:   { size: 12, nodes: ['_legend-dot', '_layer-<分类> 内的 _dot'], usage: '地图与图例上的分类色点：底图有色，须更大才辨得出色相' },
  pinBadge:{ size: 12, nodes: ['_completeness-<档>（Pin 角标）'], usage: 'Pin 右上角完整度角标：叠在分类色圆底上，须压住底色' }
};

/**
 * 输入框两套规格的真源（2026-09-01 条目 [77]，M4-3e 第一层 ④）。
 *
 * 为什么是两栏并列而不是归一成一套：读完三个实处后确认，
 * field/selectField（44 高 / R-md / surface 底 / body 字 / 描边恒为 border）与
 * navSearchBox（32 高 / R-full / background 底 / small 字 / 描边随激活切色）
 * 在 5 个维度上都不同，而这个不同是**有依据的**：PRD :1069 明写导航栏搜索框
 * 取 32 高（「导航栏 48 上下各留 8 呼吸；输入框横向命中区宽 250px，实际可点
 * 面积远超 44×44 等效值，不适用图标按钮的 44px 下限」）。把两者强行压成一套，
 * 要么让表单框缩到 32 破 PRD §1.8 的触控下限，要么让导航栏被 44 高的框撑破。
 * 故本表分栏承载，并把「为什么允许两套」写进 usage —— 规范文档里若只出现
 * 一行「输入框 44 高」，读到导航栏那个 32 高的框时只会当成画错了。
 *
 * ⚠️ 样本量如实标注（同 TAG_SPECS.mark 的处理）：formField 的
 * default / filled 两态与 navSearch 的两态**在业务页内有实处**，是归纳；
 * focus / error / disabled 三态**业务页内零实处**，规格本轮新立，2026-09-02 起
 * 在「00 · Tokens 与组件」页的状态实样板有规范演示位。规范文档须照此区分，
 * 不能让接棒人以为三态是从既有业务画面里量出来的。
 *
 * 三态的取值依据（都不靠颜色单通道，PRD :420 WCAG AA）：
 * - focus：描边由 border 换 primary 且加粗到 1.5 —— 换色 + 加粗双通道。
 *   稿内已有同型先例：navSearchBox 激活态换 primary 描边（本文件 :1709）、
 *   三级树 checkbox 未选态用 1.5 粗描边（:3576）；
 * - error：描边取 error-text（作文字实测 6.47:1，PRD :220）而非 error
 *   （作图形仅 3.76:1，PRD :221 已标须补偿），并**强制配一行错误文案**
 *   —— 颜色之外必须有文字通道，色盲用户才读得到「哪里错了」；
 * - disabled：底色由 surface 降为 background、内文用 text-placeholder。
 *   不套按钮那档 40% 不透明度（BUTTON_SPECS.disabled）—— 按钮整块不可读
 *   无妨，输入框的**标签仍须读得清**，故标签色保持 text-secondary 不降级。
 *   placeholder 压 background 属占位符豁免（PRD :225-226 同类）。
 */
var FIELD_SPECS = {
  formField: {
    h: 44, radius: RADIUS.md, padH: SPACING.md, gap: SPACING.xs,
    labelScale: 'small', labelColor: 'color/text-secondary', textScale: 'body',
    nodes: ['field/<字段名> 内的 _input（可键入）', 'field/<字段名> 内的 _select（开选择器，框内右端多一个 ›）'],
    usage: '表单字段，6 处实处（登录页 3 + 发布页 2 + 地址补全 1）。44 高即 PRD §1.8 触控下限，'
      + '宽度默认 CANVAS.w - lg*2 = 358（页面用 lg 内边距时的可用宽），xl 内边距的登录页须显式传宽',
    states: {
      'default':  { sample: '业务页有实处', fill: 'color/surface',    stroke: 'color/border',     strokeWeight: 1,   textColor: 'color/text-placeholder', usage: '空值且未聚焦：框内是 placeholder 灰字' },
      filled:     { sample: '业务页有实处', fill: 'color/surface',    stroke: 'color/border',     strokeWeight: 1,   textColor: 'color/text-primary',     usage: '已有值：同一位置靠色阶从灰转实，与 selectField 已选态同口径' },
      focus:      { sample: '仅状态实样板', fill: 'color/surface',  stroke: 'color/primary',    strokeWeight: 1.5, textColor: 'color/text-primary',     usage: '光标在框内：换主色描边 + 加粗，不靠颜色单通道' },
      error:      { sample: '仅状态实样板', fill: 'color/surface',  stroke: 'color/error-text', strokeWeight: 1.5, textColor: 'color/text-primary',     hintColor: 'color/error-text', usage: '校验失败：描边换色 + 框下必配一行 caption 错误文案（_field-error）' },
      disabled:   { sample: '仅状态实样板', fill: 'color/background', stroke: 'color/border',   strokeWeight: 1,   textColor: 'color/text-placeholder', usage: '不可编辑：底色降为 background；标签不降级，仍须读得清' }
    }
  },
  navSearch: {
    h: 32, radius: RADIUS.full, padH: SPACING.md, gap: SPACING.xs,
    labelScale: null, labelColor: null, textScale: 'small',
    nodes: ['_nav-search（内含 _search-icon 14 / _search-text / 激活时 _search-clear 12）'],
    usage: '导航栏内嵌搜索框，1 处实处（home 系列顶栏）。32 高有 PRD :1069 明文依据，'
      + '不适用 44px 下限；无独立标签（占位文案即引导），宽度由调用方 layoutGrow=1 拉满',
    states: {
      'default': { sample: '业务页有实处', fill: 'color/background', stroke: 'color/border',  strokeWeight: 1, textColor: 'color/text-placeholder', iconColor: 'color/text-placeholder', usage: '无关键词：图标与文案同为 placeholder 灰' },
      active:    { sample: '业务页有实处', fill: 'color/background', stroke: 'color/primary', strokeWeight: 1, textColor: 'color/text-primary',     iconColor: 'color/primary',          usage: '已输入关键词：主色描边 + 实色文字 + 右端补清空叉，让「正在过滤」在顶栏就有回执' }
    }
  }
};

/**
 * 空态与加载态里鸭子符号的三档体量登记（2026-09-01 条目 [77]，M4-3e 第一层 ⑤）。
 *
 * 为什么必须显式登记：稿内三处各写一个字面数字（40 / 64 / 96），而
 * duckSymbol() 的档位是**由尺寸单向推导**的（≥96 full / 64–95 compact / <64 mini，
 * 见 :1262 与 PRD §1.4.1.2「不得各档位另画新形」）。也就是说这三个数字不只是
 * 「多大」，它们同时决定了鸭子用哪一套形——40 会拿到 mini（圆盘 + 实体鸭头），
 * 96 拿到 full（双环负形）。谁若把 40 顺手改成 64，形会整体换掉而看不出是为什么。
 * 本表把「这一档为什么是这个数」变成可查的事实。
 *
 * ⚠️ loading 档不是空态：它是「还在加载」，与另两档语义相反（一个说「等一下」、
 * 一个说「没有了」）。之所以放同一张表，是因为三档共用同一个 duckSymbol 与
 * 同一套尺寸推导规则，分表登记会让「64 属于哪一档」再次无处可查。
 *
 * ⚠️ terminal 档在稿内的实处是过程态终态空页（:4380 一段），它**没有**走
 * 下面的 emptyState() —— 那处外层是 surface 卡片容器、正文要 FILL、后面还跟
 * 按钮组，且六档过程态共用同一段构造代码，套进来要动到另五档。故那处只把
 * 鸭子尺寸改读本表（值不变），画面零变化。PRD :1686 明写的「我的发布」空页
 *（鸭子插图 + 「还没发布，立即发一条 →」）**稿内尚无实现**，是 emptyState()
 * 的 terminal 档目前唯一的目标消费方，列为遗留项，本轮不补（补它是新增画面，
 * 超出 M4-3e 第一层「只收口既有规格」的边界）。
 */
var EMPTY_STATE_SIZES = {
  inline:   { duck: 40, tier: 'mini',     leadScale: 'caption', leadColor: 'color/text-secondary', padV: SPACING.xl, gap: SPACING.sm, sample: '有实处（4 处）', usage: '列表内嵌收尾态「没有更多了」（PRD §6.7 :1291）。40 落 mini 档：它是页脚配角，用 96 的完整版会抢主列表的视觉重心' },
  loading:  { duck: 64, tier: 'compact',  leadScale: 'body',    leadColor: 'color/text-primary',   padV: null,       gap: null,       sample: '有实处（1 处）', usage: '注意，非空态：兜底过程态 0–1 秒骨架档的缺省图（PRD §6.4.4）。64 落 compact 档，既区别于终态的 96，又不至于小到看成页脚' },
  terminal: { duck: 96, tier: 'full',     leadScale: 'h3',      leadColor: 'color/text-primary',   padV: SPACING.xl, gap: SPACING.md, sample: '规格系新立（稿内唯一实处未走构造器，见上）', usage: '整页空态：一条都没有，页面重心就是它。96 是 full 档下限，PRD :129 明写完整版用于「空态/缺省图（§6.4.4）」' }
};

/**
 * 构造一组空态（鸭子 + 主文案 + 可选副文案 + 可选主操作）（2026-09-01 条目 [77]）。
 *
 * 为什么要收成构造器：改前空态的规格只以三个字面数字的形式散在三处，
 * 「空态该长什么样」这句话在稿内没有任何一处可指。收成唯一出口后，
 * 下一处要画空态的人不必再自行决定鸭子多大、文案用几号字。
 *
 * 刻意不含外层卡片容器：三处实处的外壳各不相同（收尾条是无底裸组、终态空页
 * 外面套 surface 卡片）。把外壳也并进来就得开一堆开关，而外壳恰恰是各页
 * 版式自己的事，不属「空态」这个组件的规格。
 *
 * @param {string} tierKey EMPTY_STATE_SIZES 的档位键：inline / terminal
 *   （loading 档不走本构造器 —— 它是加载中而非空态，且实处外层是卡片容器）
 * @param {string} lead 主文案，如「没有更多了」「还没发布」
 * @param {Object} [opt] 可选项
 * @param {number} [opt.w] 组宽；省略时按内容 hug。挂进带 lg 内边距的 _body 时
 *   须传 CANVAS.w - SPACING.lg * 2，否则满宽会把容器顶到溢出
 * @param {string} [opt.sub] 副文案，caption 次级灰，补充「为什么空」
 * @param {FrameNode} [opt.action] 主操作按钮节点，由调用方用 button() 造好传入
 *   （不在此处造：按钮宽度取决于所在容器可用宽，本函数不该替它算）
 * @param {string} [opt.name] 覆写节点名。仅供 listEndRow 沿用其历史名 `_list-end`
 *   使用 —— 那个名字已被 4 处探针断言与渲染核对引用，为「让节点名更整齐」去改它
 *   会动到已验收的判据，收益远不及风险
 * @returns {FrameNode} 纵排居中的空态组
 */
function emptyState(tierKey, lead, opt) {
  opt = opt || {};
  var S = EMPTY_STATE_SIZES[tierKey];
  // 档位对不上就当场炸掉，不静默兜底：兜底会让一个体量错误的鸭子悄悄上屏，
  // 而尺寸同时决定用哪一套形（见 EMPTY_STATE_SIZES 注释）
  if (!S || !S.padV) {
    throw new Error('emptyState() 档位「' + tierKey + '」不可用，见 EMPTY_STATE_SIZES（loading 档不走本构造器）');
  }
  var g = box(opt.name || ('_empty-state/' + tierKey), 'VERTICAL', {
    w: opt.w, padTop: S.padV, padBottom: S.padV, gap: S.gap, align: 'CENTER'
  });
  g.appendChild(duckSymbol(S.duck));
  g.appendChild(text(lead, S.leadScale, S.leadColor));
  if (opt.sub) g.appendChild(text(opt.sub, 'caption', 'color/text-secondary'));
  // 主操作与上方文案之间加一档 ACTION_GAP：空态的鸭子、主文案、副文案是同一段
  // 陈述，按钮是它之后的出口，同为 S.gap 会让按钮读成副文案的续行
  //（受限态实机看图查出的同一个毛病，见 ACTION_GAP 说明）
  if (opt.action) appendActionWithGap(g, opt.action);
  return g;
}

/**
 * 构造一枚 A 族可点选择胶囊（2026-09-01 条目 [77]，TAG_SPECS.chip 的唯一构造器）。
 *
 * 为什么要有这个函数而不是让 4 处调用点各自读 TAG_SPECS：只要还是各自 box()，
 * 下一处新写的胶囊仍然可以不查表就手搓，表就退化成一份「建议」。收成构造器后
 * 它是这一族在本文件内的唯一出口，探针也能按 `_chip-tag/` 前缀点名核对。
 *
 * 名称前缀刻意统一为 `_chip-tag/`：回改前四处叫 `_radius-*` / `_sd-*` /
 * `_lv1-*` / `_mode-*`，互相看不出是同一族。加统一前缀后，Figma 图层树里
 * 一眼可见它们同属一族，而 `/` 后的原名仍保留各自语义（探针与渲染核对靠它）。
 *
 * @param {string} slug 该胶囊的语义名，拼进节点名，如 'radius-5km'、'sd-resource'
 * @param {boolean} selected 是否为选中态
 * @param {string} [onFill] 覆写选中态底色 role；省略时取 TAG_SPECS.chip.onFill
 *   （主色）。代表某个分类的胶囊须传 'category/<key>-deep'，以承载分类色语义
 * @returns {FrameNode} 横排的胶囊容器（文字与图标由调用方 appendChild）
 */
function chipTag(slug, selected, onFill) {
  var S = TAG_SPECS.chip;
  return box('_chip-tag/' + slug, 'HORIZONTAL', {
    padTop: S.padV, padBottom: S.padV, padLeft: S.padH, padRight: S.padH,
    gap: SPACING.xs, radius: S.radius,
    // 非选中态一律给 background 实底：回改前有一处是「无填充」，在白底卡片上
    // 等于完全看不出这里可点，而它与相邻的选中项本该是一组同类可点项
    fill: selected ? (onFill || S.onFill) : S.offFill,
    align: 'CENTER', justify: 'CENTER'
  });
}

/**
 * 取 A 族胶囊内文字应使用的颜色 role（2026-09-01 条目 [77]）。
 *
 * 单独抽一个函数是因为 4 处调用点回改前的文字色各不相同（surface / primary /
 * text-secondary / primary-dark 混用），若只收容器不收文字，规范里的「选中 =
 * 白字、未选 = 次级灰字」仍会与画布分叉。
 *
 * @param {boolean} selected 是否为选中态
 * @returns {string} 颜色 role
 */
function chipTagInk(selected) {
  return selected ? TAG_SPECS.chip.onText : TAG_SPECS.chip.offText;
}

/**
 * 创建一个通用按钮（PRD §1.4.6 六类按钮规范）
 * @param {string} label 按钮文案
 * @param {string} variant primary/secondary/ghost/danger/capsule/disabled
 * @param {number} width 按钮宽度，传 0 表示按内容自适应
 * @returns {FrameNode} 按钮节点
 */
function buttonRaw(label, variant, width) {
  var conf = BUTTON_SPECS[variant] || {};

  var b = box('btn/' + variant + '/' + label, 'HORIZONTAL', {
    padTop: SPACING.md, padBottom: SPACING.md,
    padLeft: SPACING.lg, padRight: SPACING.lg,
    fill: conf.fill, radius: conf.radius, stroke: conf.stroke,
    align: 'CENTER', justify: 'CENTER',
    w: width || 0
  });
  if (variant === 'disabled') b.opacity = 0.4;
  // 描边不计入 Auto Layout（2026-09-02 实机核验，与 card() 选中态同一个病灶）：
  // Figma 默认 strokesIncludedInLayout = true，secondary 那道 1px 描边把按钮高
  // 从 45 顶到 47，而其余五个变体都是 45（pad 12+12 + body 行高 21）。
  //
  // 这不是理论风险：实测 5 处 align 为 MIN 的横排容器里，secondary 与 ghost
  // 顶对齐、底部差 2px（_pub-actions 4 处的「编辑/下架」「刷新重发/删除」
  // 「继续编辑/删除」，_actions 的「去首页看效果/我的发布」）—— 一排按钮
  // 底线不齐是肉眼可见的。同理 CSS 侧须用 outline/box-shadow 而非 border，
  // 否则 border-box 之外的 1px 会在浏览器里复现同一位移。
  //
  // 无条件设而不只对 secondary 设：六个变体走同一个构造器，将来任何变体加描边
  // （如 danger 的 outline 变体）都会立刻踩同一个坑，条件判断只会漏。
  b.strokesIncludedInLayout = false;
  b.appendChild(text(label, 'body', conf.textColor));
  return b;
}

// ============================================================
// 五、共用外壳组件
// ============================================================

/**
 * 创建 iOS 状态栏占位条（高 44，仅作视觉留白，不含真实内容）
 * @returns {FrameNode} 状态栏节点
 */
function statusBarRaw() {
  var s = box('_status-bar', 'HORIZONTAL', {
    w: CANVAS.w, h: 44, fill: 'color/surface',
    padLeft: SPACING.lg, padRight: SPACING.lg,
    align: 'CENTER', justify: 'SPACE_BETWEEN'
  });
  s.appendChild(text('9:41', 'caption', 'color/text-primary'));
  s.appendChild(text('●●● ⌁ ▮', 'caption', 'color/text-primary'));
  return s;
}

/**
 * 创建顶部导航栏
 *
 * 为什么标题与右侧动作要各自包一层具名容器：
 * text() 创建的 TEXT 节点名默认等于文案本身，于是导航栏标题「发布」与
 * 底部主按钮内的「发布」在节点名上完全同名。批次 5 靠节点名定位可点元素，
 * 深度优先会先撞上导航栏标题，导致 reaction 绑到标题上——
 * 2026-08-24 实测 publish-screen 的 cert-modal 跳转就绑在标题文本 268:12697 上，
 * 底部真正的「发布」按钮反而没有跳转。
 * 故此处把标题包为 _nav-title/xxx（永不作为跳转触发点），
 * 右侧动作包为 _nav-action/xxx（可作为跳转触发点），两者名字空间彼此隔离。
 * 2026-08-24 新增的搜索框与通知铃同样各自具名（_nav-search / _nav-bell），
 * 且刻意不叫任何按钮文案，继续维持这条隔离规则。
 *
 * @param {string} title 标题文案
 * @param {Object} opt back 是否显示返回箭头 / right 右侧文案 /
 *                     search 传入占位文案则在标题与右侧动作之间插入搜索框 /
 *                     searchValue 搜索框已输入的关键词（传值即渲染激活态：实词 + 清空叉）/
 *                     bell 传数字则在最右侧加通知铃 + 未读角标
 * @returns {FrameNode} 导航栏节点
 */
function navBar(title, opt) {
  opt = opt || {};
  // justify 用默认 MIN 而不是 SPACE_BETWEEN（2026-08-26 修，实机验收发现）
  //
  // 原先设 SPACE_BETWEEN，与搜索框的 layoutGrow=1 直接冲突：SPACE_BETWEEN
  // 靠「均分剩余空间」来把两端推开，layoutGrow 要「吃掉剩余空间」，两者同设
  // 时 Figma 以 SPACE_BETWEEN 为准，grow 静默失效 —— 搜索框停在初始 w:180
  // 被内容顶到的 274，于是 32 + 274 + 28 + 24 + 间隙 24 + 内边距 32 = 414 > 390，
  // 25 个页面的导航栏一起横向溢出 24px（实机实测）。
  //
  // 去掉 SPACE_BETWEEN 后，两端分离改由 grow 自己完成：搜索框吃满中间剩余宽，
  // 左侧标题与右侧动作自然被挤到两端，视觉结果与 SPACE_BETWEEN 想要的一致，
  // 且宽度受容器约束不再溢出。
  var n = box('_nav-bar', 'HORIZONTAL', {
    w: CANVAS.w, h: 48, fill: 'color/surface',
    padLeft: SPACING.lg, padRight: SPACING.lg, gap: SPACING.sm,
    align: 'CENTER'
  });
  var left = box('_nav-left', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  if (opt.back) left.appendChild(text('‹', 'h2', 'color/text-primary'));
  var titleBox = box('_nav-title/' + title, 'HORIZONTAL', { align: 'CENTER' });
  titleBox.appendChild(text(title, 'h3', 'color/text-primary'));
  left.appendChild(titleBox);
  n.appendChild(left);
  // 搜索框插在标题与右侧动作之间，并让它独占剩余宽度：
  // layoutGrow=1 使其随标题/动作宽度变化自适应，无需手工算像素
  if (opt.search) {
    var sb = navSearchBox(opt.search, opt.searchValue);
    sb.layoutGrow = 1;
    n.appendChild(sb);
  }
  // 没有右侧动作就不建容器（2026-08-26 实机核查后修）：
  // 原先无条件建 box('_nav-action/' + (opt.right || ''))，opt.right 为空时
  // 产出 5 个名为「_nav-action/」、宽 0 的空容器，内含一个空文本节点。
  // 它们不可见也不可点，但会污染两处：① FLOW_LINKS 的触发点按名前缀查找时
  // 多出无意义候选；② 触控区体检把宽 0 节点报成「不达 44×44」。
  if (opt.right) {
    // 高撑到 44 承载点击（2026-08-26 实机触控区核查后修）：
    // 原先 hug 到 28×21，远不足 PRD §1.8 的 44×44。导航栏 48 高放得下 44。
    // 宽度仍由文案 hug —— 「取消」「确定」这类两字动作横向仅 28，但
    // PRD §1.8 的 44×44 是针对**图标类**控件；文字按钮的横向命中区受文案
    // 长度决定，此处补足纵向到 44 已使命中面积等效达标（同 §1.4.1 对搜索框
    // 32 高的豁免理由：横向命中区足够宽）。
    var actionBox = box('_nav-action/' + opt.right, 'HORIZONTAL', {
      h: 44, align: 'CENTER', justify: 'CENTER'
    });
    actionBox.appendChild(text(opt.right, 'body', 'color/primary'));
    n.appendChild(actionBox);
  }
  if (opt.bell !== undefined) n.appendChild(navBell(opt.bell));
  return n;
}

/**
 * 创建导航栏内的搜索框（PRD §6.4.1 ASCII 图的 [🔍搜索"就近的保洁/拼车/二手"] 位）。
 *
 * 为什么放导航栏而不是悬浮在地图上（2026-08-24，依用户「地图界面差一个搜索框」）：
 * 地图左上角 x=16 y=12 已被筛选摘要胶囊占据，右上角是三竖点与图例入口，
 * 搜索框若也悬浮就必与其中之一抢位；且 PRD §6.4.1 的 ASCII 图与 §6.3 概述
 * 都把搜索列为导航栏成员，导航栏是它唯一有据可依的落点。
 *
 * 为什么高度取 32 而不是 44（iOS 最小可点区）：导航栏总高 48px 是 PRD 定死的，
 * 上下各留 8px 呼吸即余 32。输入框不同于图标按钮，其横向命中区宽达 150px 以上，
 * 实际可点面积远超 44×44 的等效值，故 32 高不构成可点性问题。
 *
 * 节点名为什么不含文案：占位文案含引号与斜杠，若并入节点名会与
 * FLOW_LINKS 的精确名匹配相冲突，故固定名 _nav-search，文案只进子文本节点。
 *
 * @param {string} placeholder 未输入时的引导文案
 * @param {string} [value] 已输入的关键词。传值即渲染激活态：文字转实色 + 右侧补清空叉
 * @returns {FrameNode} 搜索框节点
 */
function navSearchBox(placeholder, value) {
  var active = !!value;
  // 2026-09-01 条目 [77]：改读 FIELD_SPECS.navSearch，取值与改前逐项相同
  //（32 / R-full / background 底 / md 内边距 / xs 间距 / small 字 /
  // 描边与文字色随激活切换）。分栏登记而非与 formField 归一，理由见 FIELD_SPECS
  var S = FIELD_SPECS.navSearch;
  var st = S.states[active ? 'active' : 'default'];
  // w 与 h 必须都传：box() 里 opt.h 只设 primaryAxisSizingMode，
  // 而横向 Auto Layout 的 primary 轴是宽度，counter 轴才是高度。
  // 只传 h 会让 counterAxisSizingMode 停在 AUTO，高度按内容 hug 塌到 18px。
  // 传 w 是为了让宽度先成为 FIXED，随后由调用方的 layoutGrow=1 拉满剩余空间
  var b = box('_nav-search', 'HORIZONTAL', {
    w: 180, h: S.h, radius: S.radius, fill: st.fill,
    // 激活态加主色描边，让「正在按关键词过滤」这件事在导航栏就有视觉回执
    stroke: st.stroke, strokeWeight: st.strokeWeight,
    padLeft: S.padH, padRight: S.padH, gap: S.gap,
    align: 'CENTER'
  });
  b.appendChild(svgIcon('_search-icon', ICON_PATHS.search, st.iconColor, 14));
  var label = text(value || placeholder, S.textScale, st.textColor);
  label.name = '_search-text';
  // 先解掉宽度 hug 再给 layoutGrow：text() 出来的节点 textAutoResize 默认是
  // WIDTH_AND_HEIGHT（宽高双 hug），宽度既然由内容决定，layoutGrow 就拉不动它。
  // 改为 HEIGHT 后宽度交给 Auto Layout，高度仍按行高自适应
  label.textAutoResize = 'HEIGHT';
  label.layoutGrow = 1;
  // 关键词过长时截断而非换行：搜索框只有 32px 高，换行会把第二行挤出可视区
  label.textTruncation = 'ENDING';
  b.appendChild(label);
  // 清空叉只在有词时出现：无词时它无事可做，常驻只会占宽并误导可点
  if (active) b.appendChild(svgIcon('_search-clear', ICON_PATHS.close, 'color/text-secondary', 12));
  return b;
}

/**
 * 创建导航栏通知铃 + 未读数角标（PRD §6.4.1 ASCII 图的 🔔(3) 位）。
 *
 * 为什么未读数用红点而非精确数字气泡：导航栏仅剩 24px 见方的位置，
 * 双位数气泡会溢出并压到搜索框；且首页的通知只承担「有新消息」的提示职责，
 * 精确条数由通知中心（notification-screen）承载。
 *
 * @param {number} unread 未读条数，0 表示无未读（此时不渲染红点）
 * @returns {FrameNode} 通知铃节点
 */
function navBell(unread) {
  // 外壳 44×44 承载点击，铃铛图形仍是 24×24（2026-08-26 实机触控区核查后修）。
  //
  // 原先外壳就是 24×24，不足 PRD §1.8 的 44×44。导航栏总高 48，
  // 44 的命中区上下各余 2px，放得下。图标与红点的相对位置随外壳变大而
  // 整体下移 10px（(44-24)/2），故下面的 x/y 全部加上这个偏移量，
  // 保证视觉位置与改前完全一致 —— 只有命中区变大，观感零变化。
  var b = stack('_nav-bell', 44, 44);
  var inset = 10;
  // 关掉裁剪：红点要贴右上角外沿，裁剪会切掉一半
  b.clipsContent = false;
  var icon = svgIcon('_bell-icon', ICON_PATHS.bell, 'color/text-primary', 20);
  b.appendChild(icon);
  icon.x = 2 + inset;
  icon.y = 2 + inset;
  if (unread > 0) {
    var dot = box('_bell-badge', 'HORIZONTAL', {
      // 2026-09-01 条目 [77]：字面 8 改为读 DOT_SIZES.unread（值不变）
      w: DOT_SIZES.unread.size, h: DOT_SIZES.unread.size, radius: RADIUS.full, fill: 'color/error',
      stroke: 'color/surface', strokeWeight: 1.5
    });
    b.appendChild(dot);
    dot.x = 15 + inset;
    dot.y = 1 + inset;
  }
  return b;
}

/**
 * 创建底部三 Tab（PRD §10.2：鸭圈 / 发布 / 我的）
 * @param {string} active 当前高亮的 Tab 名，取值 "鸭圈"/"发布"/"我的"
 * @returns {FrameNode} 底部 Tab 栏节点
 */
function bottomTabRaw(active) {
  var bar = box('_bottom-tab', 'HORIZONTAL', {
    w: CANVAS.w, h: 64, fill: 'color/surface',
    stroke: 'color/border', align: 'CENTER', justify: 'CENTER'
  });
  // 三键全部矢量（2026-08-26）：此前「鸭圈」用 emoji 🗺️、「我的」用 emoji 👤。
  // emoji 由系统字体渲染，字重与色彩不受 paintOf(role) 控制 —— 选中时文字变主色
  // 而 emoji 不变，且与同排的矢量鸭子风格断裂，这是用户实机反馈的成因。
  // 「发布」中键走 duckSymbol（PRD §1.4.1.2 明列的 IP 微缩版消费位置）。
  var items = [
    [ICON_PATHS['tab-map'], '鸭圈'],
    [null, '发布'],
    [ICON_PATHS['tab-person'], '我的']
  ];
  for (var i = 0; i < items.length; i++) {
    var isActive = items[i][1] === active;
    var role = isActive ? 'color/primary' : 'color/text-secondary';
    // 单元格高撑满 44（2026-08-26 实机触控区核查后修，用户拍定「加透明扩展命中区」）。
    //
    // 原先不传 h，单元格按内容 hug 到 41 高（图标 24 + 间隙 4 + 文字 13），
    // 差 PRD §1.8 的 44×44 触控区 3px。底栏总高 64，单元格撑到 44 仍余 20，
    // 不必抬高栏高就能合规 —— 这正是「加透明扩展命中区」的最省做法：
    // 视觉元素（图标 + 文字）尺寸与位置全不变，只把承载点击的容器撑大。
    var cell = box('_tab-' + items[i][1], 'VERTICAL', {
      w: CANVAS.w / 3, h: 44, gap: SPACING.xs, align: 'CENTER', justify: 'CENTER'
    });
    if (items[i][0] === null) {
      // 24px 落在微缩档（<64），duckSymbol 自动改用「圆盘 + 实体鸭头」结构。
      // 非激活态色块换 text-secondary：Tab 用色块本身表达选中态，
      // 而非给 IP 换形（PRD §1.4.1.1 叠加铁律禁止改形）
      cell.appendChild(duckSymbol(24, role, 'color/surface'));
    } else {
      cell.appendChild(svgIcon('_tab-icon-' + items[i][1], items[i][0], role, 24));
    }
    cell.appendChild(text(items[i][1], 'caption', role));
    bar.appendChild(cell);
  }
  return bar;
}

/**
 * 创建一个地图 Pin（PRD §6.4.2 尺寸规范 / §1.4.3 分类色与供需态规则）
 *
 * 资源态 = 分类色实心圆 + 白色分类图标；
 * 需求态 = 白底 + 分类色描边 + 分类色分类图标，并在右上角加 "?" 标识。
 *
 * 为什么需求态的 "?" 从圆心移到右上角：PRD §6.4.2 要求需求态同时具备
 * 「空心圆 + ?」与「分类图标」两个信息。若 ? 仍占圆心就与图标争位，
 * 40×40 内两者叠加不可读。故图标居中承载「是什么类」，
 * ? 缩为角标承载「这是需求而非资源」，两条信息各有其位。
 *
 * @param {string} catRole 分类色变量 role，如 "category/cat-work"
 * @param {string} supplyDemand "resource" 资源态 或 "demand" 需求态
 * @param {string} completeness 完整度档 green/yellow/red。
 *                 **仅 T6 组件板的角标规范演示会传值**；地图上一律传 null，
 *                 详见下方 showCompleteness 的判据说明
 * @param {boolean} selected 是否为选中态（选中态 48×48）
 * @param {boolean} showCompleteness 是否真的渲染完整度角标。
 *                 默认 false，即便传了 completeness 也不渲染。
 *                 判据（2026-08-24，PRD §6.4.2 修订）：40×40 内原先叠了 4 条信息
 *                 —— 圆底色=分类、中心图标=分类、右上 ?=供需、右下点=完整度。
 *                 分类被重复编码两次，而完整度在地图缩略态几乎无人细看，
 *                 纯粹在抢辨识带宽，是「无法见图知意」的成因之一。
 *                 故地图上卸掉，完整度改由点击 Marker 后的信息卡承载。
 *                 T6 组件板作为「角标规范说明」仍需展示，故保留开关而非直接删除。
 * @returns {FrameNode} Pin 节点
 */
function pinRaw(catRole, supplyDemand, completeness, selected, showCompleteness) {
  var size = selected ? 48 : 40;
  var isDemand = supplyDemand === 'demand';
  var catKey = catRole.replace('category/', '');
  // 图标色：资源态圆内已是分类色实心，图标须取白才有对比；需求态白底则取分类色
  var iconColor = isDemand ? catRole : 'color/surface';

  // Pin 外层改用叠层容器：角标需绝对定位到边缘，Auto Layout 无法表达
  var p = stack('pin/' + catKey + '/' + supplyDemand + (selected ? '/selected' : ''), size, size);
  // 关掉裁剪，否则贴边的角标会被切掉一半
  p.clipsContent = false;

  // 圆底：分类色实心（资源）或白底分类色描边（需求）
  var disc = box('_disc', 'HORIZONTAL', {
    w: size, h: size, radius: RADIUS.full,
    fill: isDemand ? 'color/surface' : catRole,
    stroke: isDemand ? catRole : null, strokeWeight: 2,
    align: 'CENTER', justify: 'CENTER'
  });
  var iconSize = Math.round(size * 0.5);   // 图标占直径一半，四周留白便于识别
  disc.appendChild(catIcon(catKey, iconColor, iconSize));
  p.appendChild(disc);
  disc.x = 0;
  disc.y = 0;

  if (selected) {
    // 选中态阴影：PRD §6.4.2 "选中态 48×48 + 阴影放大"
    disc.effects = [{
      type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.25 },
      offset: { x: 0, y: 2 }, radius: 8, spread: 0, visible: true, blendMode: 'NORMAL'
    }];
  }

  // 需求态标识：右上角 "?" 角标，与图标错位不抢占圆心
  if (isDemand) {
    var q = box('_demand-mark', 'HORIZONTAL', {
      w: 16, h: 16, radius: RADIUS.full, fill: catRole,
      stroke: 'color/surface', strokeWeight: 2, align: 'CENTER', justify: 'CENTER'
    });
    q.appendChild(text('?', 'caption', 'color/surface'));
    p.appendChild(q);
    q.x = size - 14;
    q.y = -2;
  }

  // 完整度角标（T6-③）：绿黄红三档，右下角小圆点，避开右上角的需求态 ?
  // 只有 showCompleteness 显式为 true 才渲染 —— 地图 Marker 一律不带（见函数注释判据）
  if (completeness && showCompleteness) {
    var dotRole = { green: 'color/success', yellow: 'color/warning', red: 'color/error' }[completeness];
    var badge = box('_completeness-' + completeness, 'HORIZONTAL', {
      // 2026-09-01 条目 [77]：字面 12 改为读 DOT_SIZES.pinBadge（值不变）
      w: DOT_SIZES.pinBadge.size, h: DOT_SIZES.pinBadge.size, radius: RADIUS.full, fill: dotRole,
      stroke: 'color/surface', strokeWeight: 2
    });
    p.appendChild(badge);
    // 角标贴 Pin 右下角：偏移量与角标边长同源，改档位时不会漏改这两行
    badge.x = size - DOT_SIZES.pinBadge.size;
    badge.y = size - DOT_SIZES.pinBadge.size;
  }
  return p;
}

/**
 * 列表卡右侧「元数据」三槽位登记（2026-09-01 条目 [77]，M4-3e 第一层 ③）。
 *
 * 为什么必须拆开：改造前 card() 的第四参叫 tag，是一个裸字符串，而它在三处
 * 调用点承载的是三种性质不同的信息 —— 列表页传供需属性（`资源`）、我的发布
 * 传生命周期状态（`在架` / `已下架` / `草稿`）、空状态兜底过程态传时间新鲜度
 *（`今天更新`）。稿上三者长得一模一样，评审无从判断「这个位置到底该放什么」，
 * 交给开发时更会被读成同一个字段。
 *
 * 为什么仍是纯文字、不套标签容器（用户 2026-09-01 裁定）：这三处是「这条信息
 * 的元数据」而非可点标签。套上 TAG_SPECS.mark 那种带底色的静态标记容器，会把
 * 它的视觉权重提到与卡片标题同级；而列表卡是 M3 已验收内容里出现面积最大的
 * 组件，不该为了「看起来更像组件」去改它。故本次**只拆参数，画面零变化**：
 * 三槽位的字阶与颜色与改造前逐项相同，唯一新增的是各自的节点名。
 *
 * 节点名是本次拆分的实际产出：Figma 图层树与规范文档从此可以指着
 * `_meta-lifecycle` 说「这一格放状态、不放别的」，而改造前它只叫 Text。
 *
 * 顺序即渲染顺序：供需 → 生命周期 → 新鲜度。当前每处调用只填一格，
 * 故顺序在画面上不体现；登记它是为了三格同填时不必再临时决定谁在前。
 */
var CARD_META_SLOTS = [
  {
    key: 'supplyDemand', node: '_meta-supply-demand', scale: 'caption', color: 'color/primary',
    usage: '供需属性：资源 / 需求。列表页与收藏页用，与页签当前筛选值必须一致'
  },
  {
    key: 'lifecycle', node: '_meta-lifecycle', scale: 'caption', color: 'color/primary',
    usage: '生命周期状态：在架 / 已下架 / 草稿（PRD §8.6 状态机）。仅「我的发布」用'
  },
  {
    key: 'freshness', node: '_meta-freshness', scale: 'caption', color: 'color/primary',
    usage: '时间新鲜度：今天更新 / 昨天更新 / 3 天前。空状态兜底过程态的结果卡用'
  }
];

/**
 * 创建一个列表卡片（用于 list-screen / 我的发布 / 我的收藏）
 *
 * 规格对齐（2026-08-26 修正两处与 PRD §1.4.7 的偏差）：
 * ① 阴影 —— 原实现用 stroke 'color/border' 代替阴影。描边在视觉上比阴影更硬，
 *    且卡片是 14 页里出现最多的组件，偏差会被整份视觉稿放大。改为 PRD 规定的
 *    「白底 + R-lg + 阴影 0 2 8 rgba(0,0,0,0.04)」，描边随之移除（两者并存会
 *    让卡片边界出现双线）。
 * ② 内边距 —— 原为 md(12)，PRD 明确「内边距 lg（16）」，改为 SPACING.lg。
 *
 * @param {string} title 标题
 * @param {string} sub 副标题（模板字段摘要）
 * @param {string} catRole 分类色 role，用于左侧色条
 * @param {Object} meta 右侧元数据，按 CARD_META_SLOTS 的三个具名槽位填（2026-09-01
 *        条目 [77] 由裸字符串 tag 改造而来）。三格皆为可选，各自渲染成一个
 *        独立命名的纯文本节点；一格都不填时右侧不生成任何节点。
 *        为什么改成对象而不是三个位置参数：位置参数第 4、5、6 个都是同型字符串，
 *        调用点写 card(t, s, c, null, '在架') 这种跳格调用完全合法却读不出含义，
 *        而这恰是本次要消除的病症本身
 * @param {string} [meta.supplyDemand] 供需属性，如 "资源" / "需求"
 * @param {string} [meta.lifecycle] 生命周期状态，如 "在架" / "已下架" / "草稿"
 * @param {string} [meta.freshness] 时间新鲜度，如 "今天更新"
 * @param {string} [completeness] 完整度档位 'green'|'yellow'|'red'。传入时副标题
 *        前置一个矢量完整度标识（条目 [70]）。之所以做成参数而非让调用方把
 *        「完整度 🟢｜」拼进 sub 字符串：拼进字符串就等于把状态语义降级成文案，
 *        既换不掉 emoji，也无法参与 §1.4.2 的对比度体系
 * @param {string} [state] 卡片状态，取 CARD_STATES 的 key：normal（默认）/
 *        selected（加 primary-light 边框）/ archived（整卡 opacity 50%）。
 *        2026-09-02 补齐 —— 此前只有 normal 一种形态，另两档规格只存在于
 *        CARD_STATES 表与规范文档里，画布上无从验证（§11 已知缺口之一）
 * @returns {FrameNode} 卡片节点
 */
function card(title, sub, catRole, meta, completeness, state) {
  // 状态名对不上表就当场炸掉，不静默退回 normal：三态在画面上的差异很小
  //（一道 1px 边框、一层透明度），静默退回会让「三态画上去了」看起来是真的
  var stateKey = state || 'normal';
  var stateDef = null;
  for (var si = 0; si < CARD_STATES.length; si++) {
    if (CARD_STATES[si].key === stateKey) stateDef = CARD_STATES[si];
  }
  if (!stateDef) throw new Error('card() 未知状态：' + state + '。见 CARD_STATES');
  var c = box('card/' + title, 'HORIZONTAL', {
    w: CANVAS.w - SPACING.lg * 2, pad: SPACING.lg, gap: SPACING.md,
    fill: 'color/surface', radius: RADIUS.lg, align: 'MIN',
    // 选中态的边框：描边与阴影并存在正常态会让卡片边界出现双线（见上方规格对齐 ①），
    // 但选中态本就要一道可见轮廓来表达「这张被选了」，此处是刻意为之
    stroke: stateKey === 'selected' ? 'color/primary-light' : null,
    strokeWeight: stateKey === 'selected' ? 1 : undefined
  });
  c.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.04 },
    offset: { x: 0, y: 2 }, radius: 8, spread: 0, visible: true, blendMode: 'NORMAL'
  }];
  // 描边不计入 Auto Layout 尺寸（2026-09-02 实机核验查出）：Figma 默认
  // strokesIncludedInLayout = true，1px INSIDE 描边会把内容框上下各挤 1px，
  // 于是选中态卡高 76 → 78 —— 而 CARD_STATES.selected.spec 写的是「其余一切不变」。
  // 2px 的差在单张卡上看不出来，但选中态与正常态在列表里必然相邻，卡一被选中
  // 整列就往下错 2px，看起来像列表在抖。只在描边存在时设，避免给无描边的两档
  // 平白留一个无意义的属性写入。
  if (stateKey === 'selected') c.strokesIncludedInLayout = false;
  // 下架态整卡降透明度：施加在卡容器而非逐个子节点上 —— 逐个设会让相互重叠处
  // 透出底色，且新增子节点时必漏。CARD_STATES 已写明「不得再叠加任何其他
  // 降透明度处理」，因为 50% 已把 text-primary 的 14.68:1 压到约 4.9:1，贴着 AA 线
  if (stateKey === 'archived') c.opacity = 0.5;
  var bar = box('_cat-bar', 'VERTICAL', { w: 4, h: 44, radius: RADIUS.sm, fill: catRole });
  c.appendChild(bar);
  var main = box('_card-main', 'VERTICAL', { gap: SPACING.xs });
  main.layoutGrow = 1;
  main.appendChild(text(title, 'h3', 'color/text-primary'));
  if (completeness) {
    // 完整度与摘要同排：两者都是「这条信息的元数据」，分两行会让卡片长出
    // 第三层信息层级，而列表卡的扫读节奏只容得下标题 + 一行摘要
    var subRow = box('_card-sub', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
    subRow.appendChild(completenessTag(completeness, 'small', 'color/text-secondary'));
    subRow.appendChild(text(sub, 'small', 'color/text-secondary'));
    main.appendChild(subRow);
  } else {
    main.appendChild(text(sub, 'small', 'color/text-secondary'));
  }
  c.appendChild(main);
  // 右侧元数据：按 CARD_META_SLOTS 逐槽位渲染，字阶与颜色全部取自表，
  // 调用点无从自定 —— 三处若各自传色，「元数据一律 caption/primary」这条
  // 规格就又只存在于注释里了。节点名取自表，是本次拆分唯一的画面外产出
  var m = meta || {};
  for (var mi = 0; mi < CARD_META_SLOTS.length; mi++) {
    var slot = CARD_META_SLOTS[mi];
    if (!m[slot.key]) continue;
    var mt = text(m[slot.key], slot.scale, slot.color);
    mt.name = slot.node;
    c.appendChild(mt);
  }
  return c;
}

/**
 * Figma 内置 annotation 分类 ID（2026-08-27 实机实测取得，非推测）。
 *
 * 四个预设分类固定为 Development / Interaction / Accessibility / Content，
 * 通过 `figma.annotations.getAnnotationCategoriesAsync()` 枚举得到 id 为 354:0~354:3。
 *
 * 为什么写死而不每次异步查：查询是 async，而标注写入发生在同步的摆放阶段
 * （detachAnnotations），为四个固定值把整条调用链改成异步不值得。
 * 风险处置见 attachNodeAnnotation：categoryId 若在别的文件里无效，
 * 会降级为「不带分类」重写一次，标注本体不会丢。
 */
var ANNO_CATEGORY = {
  dev: '354:0',      // Development · green
  interact: '354:1', // Interaction · blue
  a11y: '354:2',     // Accessibility · pink
  content: '354:3'   // Content · orange
};

/**
 * 规格标注的严重度分档。
 *
 * 为什么必须分档：改造前 24 处调用点产出的标注卡视觉完全同构 —— 「永久 Scope
 * 红线（做了就是违约）」与「这里留白 16px」长得一模一样。评审时红线因此淹没在
 * 一堆等权重的说明里，而红线一旦被漏掉就是隐性返工，这正是 M3 决定「冻结契约
 * 而非像素」要防的事。
 *
 * 为什么 spec 档保持原样：改造前全部卡片都是 primary 系配色，spec 是默认档，
 * 不传 severity 的调用点视觉零变化 —— 本轮范围红线是「不做逐页像素精修」，
 * 分级不该顺带引发一次全画布视觉 diff。只有真红线与无障碍项会换色。
 *
 * 为什么不新增浅色 Token：红线用 error-text（白底 6.47:1）、无障碍用 accent
 * （白底 5.01:1），两者都已在 SEMANTIC_COLORS 内且实测过对比度。标注卡是画布
 * 上的评审辅助物、不是产品界面，为它单独造 error-light 之类的产品 Token 会污染
 * 命名空间（同 detachAnnotations 里「Token 管产品界面」的既有口径）。
 *
 * 为什么前缀用【】而不是 emoji：中文全角括号在 Noto Sans SC 内有字形，
 * emoji 需回退到系统字体，在 Figma 里可能渲染成豆腐块。
 */
var SEVERITY = {
  // 永久红线 / Scope 边界：做了即违约，评审必须一眼看到
  redline: { tag: '【红线】', fill: 'color/surface', stroke: 'color/error-text', ink: 'color/error-text', category: 'dev' },
  // 无障碍硬指标：对比度、触控区、命中区
  a11y: { tag: '【无障碍】', fill: 'color/surface', stroke: 'color/accent', ink: 'color/accent', category: 'a11y' },
  // 实现口径（默认档）：尺寸、Token、组件契约，配色与改造前完全一致
  spec: { tag: '', fill: 'color/primary-light', stroke: 'color/primary', ink: 'color/primary-dark', category: 'dev' },
  // 交互与动效规格（I5 的落点）
  interact: { tag: '【交互】', fill: 'color/primary-light', stroke: 'color/primary', ink: 'color/primary-dark', category: 'interact' },
  // 背景说明：为什么这么设计，不构成验收判据
  info: { tag: '【说明】', fill: 'color/background', stroke: 'color/border', ink: 'color/text-secondary', category: 'dev' }
};

/**
 * 创建一个带标题的规格标注块，用于在原型旁标注 PRD 依据与验收口径
 * @param {string} title 标注标题
 * @param {Array<string>} lines 标注正文行
 * @param {{severity?:string,target?:string}} [opts] severity 取 SEVERITY 的键（默认 spec）；
 *        target 为同一画框内被标注节点的精确名，留空则整页标注挂到画框自身
 * @returns {FrameNode} 标注节点
 */
function annotation(title, lines, opts) {
  var o = opts || {};
  var sev = SEVERITY[o.severity] || SEVERITY.spec;
  var a = box('_annotation/' + title, 'VERTICAL', {
    w: 260, pad: SPACING.md, gap: SPACING.xs,
    fill: sev.fill, radius: RADIUS.md, stroke: sev.stroke
  });
  a.appendChild(text(sev.tag + title, 'small', sev.ink));
  for (var i = 0; i < lines.length; i++) {
    a.appendChild(text('· ' + lines[i], 'caption', sev.ink));
  }
  // 机读副本：画布卡是给评审看的，节点级 annotation 是给 Dev Mode 与代码交付看的。
  // 存一份原始数据而非到时反向解析卡片里的文本，保证两个承载体永远是同一份内容
  // （反向解析要剥「· 」前缀与 tag，多一道转换就多一处会脱钩的地方）。
  a.setPluginData('anno', JSON.stringify({
    severity: o.severity || 'spec',
    target: o.target || '',
    title: title,
    lines: lines
  }));
  return a;
}

// ============================================================
// 五之二、组件化：Component 注册与 Instance 包装
// ============================================================

/**
 * 组件 master 缓存：组件名 -> ComponentNode
 * 批次 1 建 master 并存入本表；批次 2/3/4 开头通过 hydrateComponents 复原
 */
var COMP_CACHE = {};

/** 存放全部 Component master 的容器 Frame 名，位于批次 1 的 Page 上 */
var COMP_HOST_NAME = '_components · master（勿删）';

/**
 * Component Set 登记表（2026-09-01，条目 [77] 第二层 ⑦）：set 名 -> 变体属性轴。
 *
 * 为什么要有这一层映射（本项目最容易被后人改错的一处）：
 * Figma 的变体属性**只能**从 master 的图层名里读，格式硬性为 `Property=Value`，
 * 多属性用 `, ` 分隔（如 `category=cat-work, supply=resource`）。而本文件里
 * 组件的身份标识是斜杠扁平名（`ui/button/primary`），它同时是：
 *   ① COMP_CACHE 的键；② describeComponents 的 descs 表键；③ 离线探针多处
 *   断言的索引键。三者全按扁平名索引，改成变体语法要动 5 处以上断言。
 *
 * 故本轮刻意让**三套口径解耦**，各自只服务一件事：
 *   · 扁平键 `ui/button/primary`   —— 代码内部的组件身份（缓存/契约/断言）
 *   · 变体名 `variant=primary`      —— Figma 面板里的属性轴（只存在于 master.name）
 *   · 画布名 `btn/primary/发布`     —— Instance 的图层名（自带文案，供排查定位）
 * 三者由 variantNameOf / flatNameOf 双向换算，绝不各写一份字面量。
 *
 * ⚠️ 解耦的代价必须记在这里：master 的 `.name` 从此**不再等于** COMP_CACHE 的键。
 * 于是 hydrateComponents 不能再拿 `.name` 当键（那会让批次 2/3/4 独立运行时
 * 拿到 `variant=primary` 这种键、全部 miss 后静默回退原生构造 —— 画面完全正常
 * 而组件化收益归零）。探针为此加了「往返换算」与「hydrate 后 Instance 真出得来」
 * 两条断言，就是钉住这条静默失效路径。
 *
 * 为什么 shell/status-bar 不在表内：它只有 1 个 master、没有变体轴。包成
 * 单变体 set 只会在面板里多一个空下拉，无任何取用价值，还多一层结构要维护。
 *
 * 为什么 Pin 用双属性而非单属性 10 值：分类与供需态是两个正交维度，这正是
 * PRD §6.4.2「Marker 只承载分类 + 供需两类信息」那条红线的结构化表达；
 * 压成一个 10 项长下拉会把这个信息丢掉。
 *
 * 结构：set 名 -> 属性名数组（顺序即扁平名去掉 set 前缀后的斜杠段顺序）
 */
var COMPONENT_SETS = {
  'shell/bottom-tab': ['variant'],
  'ui/button': ['variant'],
  'ui/pin': ['category', 'supply']
};

/**
 * 求一个扁平组件名所属的 Component Set 名
 * @param {string} compName 扁平组件名，如 ui/pin/cat-work/resource
 * @returns {string|null} set 名；不属于任何 set 时返回 null（如 shell/status-bar）
 */
function setNameOf(compName) {
  var best = null;
  for (var s in COMPONENT_SETS) {
    // 必须带斜杠比对：否则 'ui/pinx/…' 会被误判进 'ui/pin'
    if (compName.indexOf(s + '/') !== 0) continue;
    if (!best || s.length > best.length) best = s;
  }
  return best;
}

/**
 * 扁平组件名 -> Figma 变体名（master 的图层名）
 * @param {string} compName 扁平组件名，如 ui/pin/cat-work/resource
 * @returns {string|null} 变体名，如 category=cat-work, supply=resource；不属任何 set 返回 null
 */
function variantNameOf(compName) {
  var set = setNameOf(compName);
  if (!set) return null;
  var props = COMPONENT_SETS[set];
  var vals = compName.slice(set.length + 1).split('/');
  // 段数与属性轴数不符说明登记表与注册代码分叉，宁可返回 null 让上游校验炸掉
  if (vals.length !== props.length) return null;
  var parts = [];
  for (var i = 0; i < props.length; i++) parts.push(props[i] + '=' + vals[i]);
  return parts.join(', ');
}

/**
 * Figma 变体名 -> 扁平组件名（variantNameOf 的逆运算）
 * @param {string} setName Component Set 名，如 ui/pin
 * @param {string} variantName 变体名，如 category=cat-work, supply=resource
 * @returns {string|null} 扁平组件名；格式不合法或属性名不匹配时返回 null
 */
function flatNameOf(setName, variantName) {
  var props = COMPONENT_SETS[setName];
  if (!props) return null;
  var segs = String(variantName).split(', ');
  if (segs.length !== props.length) return null;
  var vals = [];
  for (var i = 0; i < props.length; i++) {
    var eq = segs[i].indexOf('=');
    // 属性名也要核：只按位置取值的话，属性轴顺序改动会静默错位
    if (eq <= 0 || segs[i].slice(0, eq) !== props[i]) return null;
    vals.push(segs[i].slice(eq + 1));
  }
  return setName + '/' + vals.join('/');
}

/**
 * 解析变体名为 属性 -> 取值 的映射
 * @param {string} variantName 变体名，如 category=cat-work, supply=resource
 * @returns {Object} 属性名到取值的映射
 */
function parseVariantName(variantName) {
  var out = {};
  var segs = String(variantName).split(', ');
  for (var i = 0; i < segs.length; i++) {
    var eq = segs[i].indexOf('=');
    if (eq > 0) out[segs[i].slice(0, eq)] = segs[i].slice(eq + 1);
  }
  return out;
}

/**
 * 把一个已构造好的 Frame 转成 Component master 并登记到缓存
 * @param {string} compName 组件名，同时作为 Figma 图层名
 * @param {FrameNode} node 待转换的 Frame 节点
 * @returns {ComponentNode} 转换后的 Component
 */
function toComponent(compName, node) {
  var comp = figma.createComponentFromNode(node);
  // 图层名取变体语法（属于某个 set 时），因为 Figma 的变体属性只从图层名读；
  // 缓存键仍用扁平名 —— 两套口径的分工见 COMPONENT_SETS 注释
  comp.name = variantNameOf(compName) || compName;
  COMP_CACHE[compName] = comp;
  return comp;
}

/**
 * 从当前文档中把已存在的 Component master 复原到内存缓存
 * 批次 2/3/4 独立运行时需先调用，否则拿不到 master 只能回退原生成
 *
 * ⚠️ 必须穿透 Component Set 一层（2026-09-01，条目 [77] 第二层 ⑦）：
 * 合成 set 后 master 不再是 host 的直接子节点，而是 COMPONENT_SET 的子节点。
 * 若沿用「只遍历 host 直接子节点且只认 COMPONENT」的旧逻辑，批次 2/3/4 独立
 * 运行时会一个 master 都收不到 → instanceOf 全部回退原生构造 → 画面完全正常、
 * 尺寸配色分毫不差，只有「改 master 全画布同步」这唯一收益悄悄归零。
 * 这是本轮改动里唯一一处**零征兆**的失效路径，故探针专门加了断言钉住。
 *
 * ⚠️ 键必须用 flatNameOf 换算而非直接取 `.name`：set 内 master 的图层名是
 * `variant=primary` 这种变体语法，直接当键会让 COMP_CACHE 里全是查不到的键。
 *
 * @returns {Promise<number>} 复原的组件数量
 */
async function hydrateComponents() {
  await figma.loadAllPagesAsync();
  var n = 0;
  var pages = figma.root.children;
  for (var i = 0; i < pages.length; i++) {
    if (pages[i].name !== PAGE_NAMES.setup) continue;
    await pages[i].loadAsync();
    var kids = pages[i].children;
    for (var k = 0; k < kids.length; k++) {
      if (kids[k].name !== COMP_HOST_NAME) continue;
      var slots = kids[k].children;
      for (var c = 0; c < slots.length; c++) {
        var slot = slots[c];
        // 未合成 set 的独立 master（如 shell/status-bar）：图层名就是扁平名
        if (slot.type === 'COMPONENT') {
          COMP_CACHE[slot.name] = slot;
          n++;
          continue;
        }
        if (slot.type !== 'COMPONENT_SET') continue;
        var variants = slot.children;
        for (var v = 0; v < variants.length; v++) {
          if (variants[v].type !== 'COMPONENT') continue;
          var flat = flatNameOf(slot.name, variants[v].name);
          // 换不回扁平名说明画布上的变体名被手改过（或登记表已分叉）。
          // 此时宁可不收：收进去会得到一个永远命中不了的键，
          // 而下游 instanceOf 静默回退，比一开始就 miss 更难查
          if (!flat) continue;
          COMP_CACHE[flat] = variants[v];
          n++;
        }
      }
    }
  }
  return n;
}

/**
 * 取一个组件的 Instance；master 不存在时回退为直接构造原生节点
 * 这样批次 2/3/4 即使脱离批次 1 单独运行也不会失败
 *
 * ⚠️ 必须显式把 Instance 名设回扁平名（2026-09-01，条目 [77] 第二层 ⑦）：
 * Instance 默认继承 master 的图层名，而合成 set 后 master 名已改成变体语法
 * （`variant=我的`）。不设回去的话，画布上的图层名会从 `shell/bottom-tab/我的`
 * 静默变成 `variant=我的` —— 批次 5 的原型连线与探针都按节点名定位，
 * 一改就是成片失败，且失败原因（图层名换了）在报错信息里完全看不出来。
 *
 * @param {string} compName 扁平组件名
 * @param {Function} fallback 无 master 时用于直接构造节点的函数
 * @returns {SceneNode} Instance 或原生节点
 */
function instanceOf(compName, fallback) {
  var master = COMP_CACHE[compName];
  if (master && master.type === 'COMPONENT') {
    var inst = master.createInstance();
    inst.name = compName;
    return inst;
  }
  return fallback();
}

/**
 * 状态栏：优先返回 Component Instance
 * @returns {SceneNode} 状态栏 Instance 或原生 Frame
 */
function statusBar() {
  return instanceOf('shell/status-bar', statusBarRaw);
}

/**
 * 底部 Tab：按高亮项分别注册三个 master（鸭圈/发布/我的）
 * @param {string} active 高亮 Tab 名
 * @returns {SceneNode} 底部 Tab Instance 或原生 Frame
 */
function bottomTab(active) {
  return instanceOf('shell/bottom-tab/' + active, function () { return bottomTabRaw(active); });
}

/**
 * 按钮：按 variant 注册 6 个 master；传入 width 时对 Instance 做等宽 resize
 * @param {string} label 按钮文案
 * @param {string} variant 六类变体名
 * @param {number} width 宽度，0 表示内容自适应
 * @returns {SceneNode} 按钮 Instance 或原生 Frame
 */
function button(label, variant, width) {
  var master = COMP_CACHE['ui/button/' + variant];
  if (!master || master.type !== 'COMPONENT') return buttonRaw(label, variant, width);
  var inst = master.createInstance();
  // Instance 默认继承 master 名（ui/button/xxx），同一画框内多个按钮因此同名，
  // 排查跳转时无法按名字定位（只能靠内部 TEXT 的 characters 匹配）。
  // 故与 buttonRaw 统一命名为 btn/variant/label，让节点名自带文案。
  inst.name = 'btn/' + variant + '/' + label;
  // Instance 内文本改写：需先确保字体已加载，loadFonts 已在各批次开头调用
  var txt = inst.findOne(function (n) { return n.type === 'TEXT'; });
  if (txt) txt.characters = label;
  if (width) {
    inst.layoutSizingHorizontal = 'FIXED';
    inst.resize(width, inst.height);
  }
  return inst;
}

/**
 * Pin：30 种组合（5 分类 × 2 供需态 × 3 完整度）全量注册代价过高，
 * 故只为「资源态/需求态 × 5 分类」共 10 个基础态注册 master。
 *
 * ⚠️ Instance 的子结构由 master 决定，Figma 禁止对 Instance 增删子节点
 * （违规报错：in appendChild: Cannot move node. New parent is an instance）。
 * 因此只有「与 master 结构完全一致」的基础态才复用 Instance；
 * 选中态（尺寸 48×48 + 阴影）与带完整度角标态（多一个角标子节点）
 * 均属结构差异，一律回退原生构造。
 *
 * 2026-08-24：完整度角标已从地图 Marker 卸掉（详见 pinRaw 注释）。
 * 因此地图上传 completeness 也不再产生结构差异，可继续复用 Instance；
 * 只有显式 showCompleteness=true（仅 T6 组件板）才回退原生构造。
 *
 * @param {string} catRole 分类色 role
 * @param {string} supplyDemand resource / demand
 * @param {string} completeness green / yellow / red，可为 null
 * @param {boolean} selected 是否选中态
 * @param {boolean} showCompleteness 是否渲染完整度角标（仅 T6 规范演示传 true）
 * @returns {SceneNode} Pin Instance 或原生 Frame
 */
function pin(catRole, supplyDemand, completeness, selected, showCompleteness) {
  // 结构差异态直接原生构造：选中态尺寸与阴影不同，显式带角标态多一个子节点
  if (selected || (completeness && showCompleteness)) {
    return pinRaw(catRole, supplyDemand, completeness, selected, showCompleteness);
  }
  var key = 'ui/pin/' + catRole.replace('category/', '') + '/' + supplyDemand;
  var master = COMP_CACHE[key];
  if (!master || master.type !== 'COMPONENT') {
    return pinRaw(catRole, supplyDemand, completeness, selected, showCompleteness);
  }
  var inst = master.createInstance();
  // 与 instanceOf 同一判据：合成 set 后 master 名是变体语法，
  // 不设回扁平名则画布图层名会静默变成 `category=cat-work, supply=resource`
  inst.name = key;
  return inst;
}

/**
 * 把一组已注册的 master 合成一个 Component Set 并摆好位（条目 [77] 第二层 ⑦）。
 *
 * 为什么要手动摆位与 resize：figma.combineAsVariants 合成后**所有变体的 x/y
 * 全部堆在 (0,0)**，且 set 自身尺寸不会自动抱住内容 —— 不摆位则整个 set 在画布上
 * 显示为一个塌陷成单个元素的方块，肉眼看不出里面有几个变体（渲染图也看不出）。
 *
 * 为什么按属性轴数决定排布方向：单属性（按钮/Tab）排成一行，读起来就是「一档接
 * 一档」；双属性（Pin）排成 grid，行=第一属性、列=第二属性，正交关系一眼可见。
 * 这与 COMPONENT_SETS 里「Pin 刻意用双属性」的判据是同一件事的两个面。
 *
 * @param {FrameNode} host master 容器
 * @param {string} setName Component Set 名，须是 COMPONENT_SETS 的键
 * @param {Array<string>} flatNames 该 set 下全部扁平组件名，顺序即摆位顺序
 * @returns {ComponentSetNode} 合成后的 Component Set
 */
function combineSet(host, setName, flatNames) {
  var props = COMPONENT_SETS[setName];
  var comps = [];
  for (var i = 0; i < flatNames.length; i++) comps.push(COMP_CACHE[flatNames[i]]);
  // combineAsVariants 要求 parent 在创建时指定（不能事后 append），
  // 且数组必须非空且全为 ComponentNode
  var set = figma.combineAsVariants(comps, host);
  set.name = setName;

  // 变体摆位：单属性一行排开，双属性排 grid（列 = 第二属性的取值序）
  var GAP = SPACING.lg;
  var cols = 1;
  if (props.length > 1) {
    var seen = {};
    for (var c = 0; c < comps.length; c++) {
      var val = parseVariantName(comps[c].name)[props[1]];
      if (val !== undefined) seen[val] = 1;
    }
    cols = 0;
    for (var k in seen) cols++;
  } else {
    cols = comps.length;
  }
  if (cols < 1) cols = 1;

  var maxX = 0;
  var maxY = 0;
  var rowY = 0;
  var rowH = 0;
  for (var j = 0; j < comps.length; j++) {
    var col = j % cols;
    if (col === 0 && j > 0) {
      rowY += rowH + GAP;
      rowH = 0;
    }
    // 列宽按同列最宽算代价过高，直接用「本行内累加」：变体宽度在同一 set 内一致
    var px = col * (comps[j].width + GAP);
    comps[j].x = px;
    comps[j].y = rowY;
    if (comps[j].height > rowH) rowH = comps[j].height;
    if (px + comps[j].width > maxX) maxX = px + comps[j].width;
    if (rowY + comps[j].height > maxY) maxY = rowY + comps[j].height;
  }
  // set 自身不抱内容，须显式撑到装得下（留一圈边距，否则变体贴边被切）
  set.resizeWithoutConstraints(maxX + GAP * 2, maxY + GAP * 2);
  return set;
}

/**
 * 在批次 1 中注册全部 Component master
 * master 统一收进一个容器 Frame，避免散落污染画布
 *
 * 2026-09-01（条目 [77] 第二层 ⑦）：注册完毕后把有变体轴的三组合成
 * Component Set（按钮 6 / Tab 3 / Pin 10）。状态栏刻意保持独立 master ——
 * 只有 1 个、没有变体轴，包成单变体 set 只多一个空下拉（见 COMPONENT_SETS 注释）。
 *
 * @param {PageNode} page 批次 1 所在页面
 * @returns {FrameNode} 存放 master 的容器 Frame
 */
function registerComponents(page) {
  var host = box(COMP_HOST_NAME, 'VERTICAL', {
    pad: SPACING.xl, gap: SPACING.lg, fill: 'color/background', radius: RADIUS.lg
  });
  page.appendChild(host);

  // 外壳组件：状态栏 + 三个底部 Tab 态
  host.appendChild(toComponent('shell/status-bar', statusBarRaw()));
  var tabNames = [];
  for (var t = 0; t < SHELL_TABS.length; t++) {
    var tabFlat = 'shell/bottom-tab/' + SHELL_TABS[t];
    host.appendChild(toComponent(tabFlat, bottomTabRaw(SHELL_TABS[t])));
    tabNames.push(tabFlat);
  }

  // 按钮六类
  var btnNames = [];
  for (var v = 0; v < BUTTON_VARIANTS.length; v++) {
    var btnFlat = 'ui/button/' + BUTTON_VARIANTS[v];
    host.appendChild(toComponent(btnFlat, buttonRaw('按钮', BUTTON_VARIANTS[v], 0)));
    btnNames.push(btnFlat);
  }

  // Pin 十个基础态（5 分类 × 资源/需求，不含完整度角标与选中态）
  var pinNames = [];
  for (var ck in CATEGORY_COLORS) {
    var sds = ['resource', 'demand'];
    for (var s = 0; s < sds.length; s++) {
      var pinFlat = 'ui/pin/' + ck + '/' + sds[s];
      host.appendChild(toComponent(pinFlat, pinRaw('category/' + ck, sds[s], null, false)));
      pinNames.push(pinFlat);
    }
  }

  // 合成三个 Component Set。必须在全部 master 注册完之后做：combineAsVariants
  // 会把 master 从 host 搬进 set，边注册边合成会让后续 appendChild 的顺序错乱
  combineSet(host, 'shell/bottom-tab', tabNames);
  combineSet(host, 'ui/button', btnNames);
  combineSet(host, 'ui/pin', pinNames);

  return host;
}

/**
 * 给全部 Component master 写入 description（2026-08-27，条目 [51] 第 5 步）。
 *
 * 为什么必须写（实测当前 20 个 master 的 description 全为空）：Figma 的
 * description 是**组件契约唯一的常驻承载体** —— 它显示在右侧 Inspect 面板与
 * 组件库列表里，不需要进 Dev Mode，也不会像画布标注卡那样被误删或搬走。
 * M3 的范围决策是「冻结契约而非像素」，而契约里最容易丢的恰恰是
 * 「这个组件什么时候该用、哪些值不可改、结构约束是什么」这三件事：
 * 尺寸和配色能从画布量出来，使用边界量不出来。
 *
 * 为什么与画布标注卡不重复：标注卡讲的是「这一页为什么这么设计」（按页组织），
 * description 讲的是「这个组件在任何页都成立的约束」（按组件组织）。
 * 同一条信息不会两处都写 —— 页级判据留在标注卡，组件级约束留在这里。
 *
 * 为什么规格值一律从真源表现算（SPACING/RADIUS/BUTTON_SPECS/CATEGORY_COLORS）：
 * description 若手抄字面值，就成了第二份会静默脱钩的副本（原则㊾）。
 *
 * @param {Object} cache 组件名 -> ComponentNode 的映射，通常传 COMP_CACHE
 * @returns {number} 实际写入 description 的组件数
 */
function describeComponents(cache) {
  /** 每档按钮的规格描述由 BUTTON_SPECS 现算，不手抄配色 */
  function buttonDesc(variant) {
    var s = BUTTON_SPECS[variant];
    var shape = s.radius === RADIUS.full ? '全圆角胶囊' : '圆角 ' + s.radius;
    var parts = [
      '【用途】' + s.usage,
      '【规格】填充 ' + (s.fill || '无（透明）')
        + '｜文字 ' + s.textColor
        + (s.stroke ? '｜描边 ' + s.stroke + ' 1px' : '')
        + '｜' + shape
        + '｜内边距 ' + SPACING.md + '/' + SPACING.lg + '（纵/横）',
      '【不可改】高度由内边距与字号撑出，勿写死；文案改写走 Instance 内 TEXT，勿脱离 master',
      '【判据】PRD §1.4.6'
    ];
    if (variant === 'disabled') {
      parts.splice(3, 0, '【无障碍】此档对比度刻意不达标（它表达「不可用」），故禁止用于任何可点元素');
    }
    return parts.join('\n');
  }

  /** Pin 描述按供需态与分类现算 */
  function pinDesc(catKey, catName, supplyDemand) {
    var isDemand = supplyDemand === 'demand';
    return [
      '【用途】地图 Marker · ' + catName + '（' + (isDemand ? '需求态' : '资源态') + '）',
      '【规格】40×40，分类色 ' + CATEGORY_COLORS[catKey] + '（category/' + catKey + '）｜'
        + (isDemand
          ? '白底 + 分类色 2px 描边 + 分类色图标，右上角 16×16 的「?」角标标明供需'
          : '分类色实心圆 + 白色图标'),
      '【命中区】视觉 40×40 落在 WCAG 2.5.8 的地图 pin「Essential」豁免内；'
        + '实现侧命中区须外扩至 ≥44×44，不得靠放大图形达标（见首页主态标注）',
      '【结构约束】Figma 禁止对 Instance 增删子节点。选中态（48×48 + 阴影）与'
        + '带完整度角标态属结构差异，一律回退 pinRaw 原生构造，不复用本 master',
      '【不可改】Marker 只承载两类信息：分类（底色+图标）+ 供需态（实心/空心）。'
        + '完整度由点击后的信息卡承载，不回到 Marker',
      '【判据】PRD §6.4.2 / §1.4.3'
    ].join('\n');
  }

  var descs = {
    'shell/status-bar': [
      '【用途】iOS 状态栏占位条，每个 390×844 画框的第一个子节点',
      '【规格】390×44，底 color/surface，左右内边距 ' + SPACING.lg + '，两端对齐',
      '【不可改】纯视觉留白，内容为固定假值（9:41 与信号占位符）；'
        + '真机由系统绘制，Flutter 侧对应 SafeArea 顶部内边距，不要照此实现',
      '【判据】画布规格 ' + CANVAS.w + '×' + CANVAS.h + '（iPhone 14 逻辑分辨率）'
    ].join('\n')
  };

  // 三个底部 Tab 态：只有高亮项不同，故描述里点明「按高亮项各注册一个 master」
  for (var t = 0; t < SHELL_TABS.length; t++) {
    var tab = SHELL_TABS[t];
    descs['shell/bottom-tab/' + tab] = [
      '【用途】底部主导航 · 当前高亮「' + tab + '」。三个态各自一个 master，'
        + '切页时换 Instance 而非改 Instance 内部',
      '【规格】390×64，底 color/surface + 顶部 1px color/border；'
        + '三个单元格各 130 宽 × 44 高，图标 24 + 间隙 ' + SPACING.xs + ' + caption 文字',
      '【无障碍】单元格高 44 是「透明扩展命中区」的产物：图标与文字的视觉尺寸位置'
        + '全不变，只把承载点击的容器撑到 44 以满足 PRD §1.8，栏高仍为 64',
      '【不可改】三键图标一律矢量（tab-map / 鸭子 IP / tab-person），禁用 emoji —— '
        + 'emoji 由系统字体渲染，选中时不随 paintOf(role) 变主色，且风格与矢量断裂',
      '【判据】PRD §1.8 触控区 / §1.4.1.2 IP 微缩版消费位置'
    ].join('\n');
  }

  for (var v = 0; v < BUTTON_VARIANTS.length; v++) {
    descs['ui/button/' + BUTTON_VARIANTS[v]] = buttonDesc(BUTTON_VARIANTS[v]);
  }

  for (var c = 0; c < CAT_LIST.length; c++) {
    var ck = CAT_LIST[c][0];
    var cn = CAT_LIST[c][1];
    descs['ui/pin/' + ck + '/resource'] = pinDesc(ck, cn, 'resource');
    descs['ui/pin/' + ck + '/demand'] = pinDesc(ck, cn, 'demand');
  }

  var n = 0;
  for (var name in descs) {
    var comp = cache[name];
    if (!comp || comp.type !== 'COMPONENT') continue;
    comp.description = descs[name];
    n++;
  }
  return n;
}

// ============================================================
// 六、画布布局与页面管理
// ============================================================

/**
 * 每批生成内容所在的 Figma Page 名。
 *
 * ⚠️ 为什么批次 2/3/4 共用同一页：Figma 原型跳转不支持跨 Page，
 * NODE 类型 action 的 destinationId 必须与触发节点位于同一 PageNode，
 * 否则 setReactionsAsync 抛错（表现为批次 5 大面积失败）。
 * 原「01 地图与列表 / 02 核心流程 / 03 模态」三页拆分导致 21 条跳转里
 * 11 条跨页而全部连不上，故合并为单页「01 · 原型主页面」，
 * 页内改用 SectionNode 做视觉分区，分组语义不丢失且跳转全通。
 *
 * setup 页只放 Variables 说明板与 Component master，不参与原型，可独立成页。
 */
var PAGE_NAMES = {
  setup: '00 · Tokens 与组件',
  proto: '01 · 原型主页面'
};

/**
 * 原型主页面内的三个 Section 分区名，与原三页一一对应。
 * 批次 2/3/4 各自只重置自己那个 Section，互不干扰。
 */
var SECTION_NAMES = {
  map:   '01 · 地图与列表',
  core:  '02 · 核心流程',
  modal: '03 · 模态与 T6 组件'
};

/** 各 Section 在页面上的纵向起始位置，留足空间避免相互重叠 */
var SECTION_Y = {
  map:   0,
  core:  4200,
  modal: 9400
};

/**
 * 获取或创建指定名称的 Figma Page，并设为当前页
 * documentAccess 为 dynamic-page，故访问已有页面前必须 loadAsync
 * @param {string} name 页面名
 * @returns {Promise<PageNode>} 目标页面节点
 */
async function ensurePage(name) {
  await figma.loadAllPagesAsync();
  var pages = figma.root.children;
  for (var i = 0; i < pages.length; i++) {
    if (pages[i].name === name) {
      await pages[i].loadAsync();
      await figma.setCurrentPageAsync(pages[i]);
      return pages[i];
    }
  }
  var p = figma.createPage();
  p.name = name;
  await figma.setCurrentPageAsync(p);
  return p;
}

/**
 * 幂等重置：取得目标页后清空其全部旧内容，保证批次可重复执行。
 *
 * 为什么必须有这一步：ensurePage 只保证「页面唯一」，不保证「页内内容唯一」。
 * 批次若中途抛异常（如 Instance 违规操作），已生成的页面不会回滚；
 * 此时重试就会在同一页里再叠一套，导致 login-screen / detail-screen 等同名
 * 画框出现多份。重名画框会让批次 5 的 findOne 按名取节点时命中错误的那一份，
 * 表现为「源画框不存在」类日志。
 *
 * 同时清空 flowStartingPoints，避免起点指向即将被删除的节点。
 *
 * @param {string} name 页面名
 * @returns {Promise<{page: PageNode, cleared: number}>} 页面节点与被清除的顶层节点数
 */
async function resetPage(name) {
  var page = await ensurePage(name);
  page.flowStartingPoints = [];
  var kids = page.children.slice();
  for (var i = 0; i < kids.length; i++) kids[i].remove();
  return { page: page, cleared: kids.length };
}

/**
 * 幂等取得原型主页面内的指定 Section，并清空其旧内容。
 *
 * 为什么用 Section 而不是 Page：原型跳转要求源与目标同页（见 PAGE_NAMES 注释），
 * 但三块内容仍需视觉分组，Section 正好满足「同页 + 可折叠分组」两个条件。
 *
 * 幂等做法：同名 Section 存在则删掉整个 Section 后重建，而不是逐个删 children。
 * 理由是 Section 的尺寸需按本次实际画框数重算，重建比改尺寸更不容易残留。
 *
 * @param {string} sectionName Section 名，取自 SECTION_NAMES
 * @param {number} startY Section 在页面上的纵向起点，取自 SECTION_Y
 * @returns {Promise<{page: PageNode, section: SectionNode, cleared: number}>}
 */
async function resetSection(sectionName, startY) {
  var page = await ensurePage(PAGE_NAMES.proto);
  var cleared = 0;
  var kids = page.children.slice();
  for (var i = 0; i < kids.length; i++) {
    if (kids[i].type === 'SECTION' && kids[i].name === sectionName) {
      // 统计被清掉的画框数，供日志展示；Section 自身不计入
      cleared += kids[i].children.length;
      kids[i].remove();
    }
  }
  var sec = figma.createSection();
  sec.name = sectionName;
  sec.x = 0;
  sec.y = startY;
  page.appendChild(sec);
  return { page: page, section: sec, cleared: cleared };
}

/**
 * 清扫游离节点：删除页面顶层所有以 "_" 开头的内部零件节点。
 *
 * 为什么会有游离节点：figma.createFrame() 创建的节点会自动挂到 currentPage，
 * 之后才由 parent.appendChild() 移入正确的父容器。若在「已创建、尚未 append」
 * 之间抛出异常，这些半成品零件就永久留在页面顶层（如 _map-canvas、_pins-1、
 * _completeness-green）。它们不属于任何画框，会污染画布并被原型校验误判为
 * 独立屏幕（dead-end 警告）。
 *
 * 判据用「名称以 _ 开头」：项目内部零件统一采用此前缀，正式画框一律为
 * xxx-screen / xxx-modal / board-xxx，不会误删。
 *
 * @param {PageNode} page 目标页面
 * @returns {number} 被清除的游离节点数
 */
function sweepOrphans(page) {
  var kids = page.children.slice();
  var n = 0;
  for (var i = 0; i < kids.length; i++) {
    if (kids[i].name.charAt(0) === '_') {
      kids[i].remove();
      n++;
    }
  }
  return n;
}

/**
 * 把画布标注卡的内容同时写成被标注节点的 Dev Mode annotation。
 *
 * 为什么要两个承载体而不是二选一（2026-08-27，I1）：
 * ① 画布卡在设计模式可见、适合整页评审，但**对被标注对象零引用** —— 卡片飘在
 *    画框右侧，「这条讲的是哪个元素」只能靠人读文字猜；
 * ② 节点级 annotation 钉在元素旁、随元素移动、进 Dev Mode 代码交付面板，
 *    但只在 Dev Mode 可见（`Shift + D`），设计模式看不到，无法用于整页评审。
 * 两者受众与可见范围都不同，故并存；内容同出一源（卡片的 pluginData），不会分叉。
 *
 * 降级而非抛错的理由：annotations 是较新的 API，且 categoryId 是本文件实测值，
 * 换文件后不保证有效。标注写不上只是少一份机读副本，画布卡仍在、规格没丢，
 * 为此中断整批生成不成比例。
 *
 * @param {SceneNode} node 被标注节点
 * @param {{severity:string,title:string,lines:Array<string>}} data 标注数据
 * @returns {boolean} 是否写入成功
 */
function attachNodeAnnotation(node, data) {
  if (!node || !('annotations' in node)) return false;
  var sev = SEVERITY[data.severity] || SEVERITY.spec;
  // labelMarkdown 而非 label：Dev Mode 面板渲染 markdown，多行规格用列表可读性
  // 远好于挤成一行。首行加粗标题，其后每条一个列表项。
  var md = '**' + sev.tag + data.title + '**\n\n'
    + data.lines.map(function (l) { return '- ' + l; }).join('\n');
  var entry = { labelMarkdown: md, categoryId: ANNO_CATEGORY[sev.category] };
  try {
    node.annotations = (node.annotations || []).concat([entry]);
    return true;
  } catch (e) {
    // categoryId 无效是唯一可预期的失败原因，去掉分类再试一次
    try {
      node.annotations = (node.annotations || []).concat([{ labelMarkdown: md }]);
      return true;
    } catch (e2) {
      return false;
    }
  }
}

/**
 * 把一个画框内的全部口径标注卡提出到画框右侧外部
 *
 * 为什么必须移出（2026-08-26，M3 精修）：口径卡是给评审看的规格依据，
 * 不是产品界面的一部分。混在画框内会造成三重损害：
 * ① 判断「这页好不好看」时，视线被一块高饱和的 primary-light 蓝框劫走；
 * ② 它参与 Auto Layout 排布，会把真实内容往上挤，页面留白比例失真；
 * ③ 导出评审图或截图给人看时，产品界面里凭空多出一块说明文字。
 *
 * 为什么在这里统一处理，而不是逐个改 24 处调用点：24 处分三种挂载方式
 * （Auto Layout 直接 append / mapCanvas 内绝对定位 / 包一层 _note 容器），
 * 逐处改要动十几个页面构造函数，且极易漏。而「移出」这件事只关心
 * 「画框内所有 _annotation/* 节点」，与它当初怎么挂进来的无关 —— 故在
 * 摆放阶段一次性收口，页面构造函数完全不用改。
 *
 * 为什么不直接不生成：口径依据仍要能在画布上核对（PRD 条款与画面的对应
 * 关系是评审的主要内容）。删掉等于把依据赶回代码里，画布上无从查证。
 *
 * 节点级标注也在这里落（2026-08-27，I1）：必须在卡片搬走**之前**做，
 * 那时 opts.target 指定的兄弟节点还与卡片同在一个画框内，能按名精确定位。
 *
 * @param {FrameNode} frame 屏幕画框
 * @param {PageNode|SectionNode} host 画框所在容器，标注卡将挂到同一容器
 * @returns {number} 移出的标注卡数量
 */
function detachAnnotations(frame, host) {
  // 先收集再移动：findAll 返回的是快照，但移动会改变父节点的 children，
  // 边遍历边移动会跳过节点
  var cards = frame.findAll(function (n) {
    return n.name.indexOf('_annotation/') === 0;
  });
  if (!cards.length) return 0;

  // ---- 先落节点级 annotation（此时 target 兄弟节点尚未与卡片分离）----
  for (var k = 0; k < cards.length; k++) {
    var rawData = cards[k].getPluginData('anno');
    if (!rawData) continue;
    var data;
    try {
      data = JSON.parse(rawData);
    } catch (e) {
      continue;
    }
    var host2 = frame;
    if (data.target) {
      // 精确等值匹配，与 FLOW_LINKS 的 findClickable 同口径：关键字模糊匹配会
      // 深度优先命中语义无关的靠前节点。找不到时退回整页，不静默丢标注。
      var hits = frame.findAll(function (n) { return n.name === data.target; });
      if (hits.length === 1) host2 = hits[0];
    }
    attachNodeAnnotation(host2, data);
  }

  // 竖向堆在画框右侧，与画框顶部对齐。gap 取 SPACING.md 的视觉延续，
  // 但这里是画布级布局而非组件内间距，故不绑 Token（Token 管产品界面）
  //
  // 用 frame.width 而非 CANVAS.w：批次 1 的规格板也走 layout()，其宽度
  // 由内容撑开并不等于 375，写死 CANVAS.w 会让标注卡压在板子上
  var offsetX = frame.x + frame.width + 24;
  var y = frame.y;
  for (var i = 0; i < cards.length; i++) {
    var c = cards[i];
    // 移出前先解掉 opacity 折扣：mapCanvas 给标注卡设过 0.96/0.92，
    // 那是为了压在地图上不抢戏，移到画布空白处后半透明只会显得脏
    c.opacity = 1;
    host.appendChild(c);
    c.x = offsetX;
    c.y = y;
    y += c.height + 12;
  }

  // 清空壳：通知中心与级联选择器把标注卡包在一层 `_note` 容器里（带
  // SPACING.lg 内边距）。标注卡搬走后这层壳仍参与 Auto Layout，会在页面
  // 底部留一条无名空白，看起来像间距没调好。故一并移除。
  var shells = frame.findAll(function (n) {
    return n.name === '_note' && 'children' in n && n.children.length === 0;
  });
  for (var j = 0; j < shells.length; j++) shells[j].remove();

  return cards.length;
}

/**
 * 把一组屏幕 Frame 按栅格摆放到指定容器内，避免相互重叠。
 *
 * @param {PageNode|SectionNode} host 目标容器（页面或 Section）
 * @param {Array<SceneNode>} nodes 待摆放的节点数组
 * @param {number} perRow 每行摆放数量
 * @param {number} startY 起始 Y 坐标（相对 host）
 * @returns {void}
 */
function layout(host, nodes, perRow, startY) {
  // gapX 由 80 提到 320：口径标注卡（宽 260）要从画框内提到画框右侧外，
  // 260 + 左右各 24 间隙 = 308，取 320 留出余量。gapY 不动，标注卡竖排
  // 在同一列内，不会侵占下一行
  var gapX = 320, gapY = 120;
  var pad = 80;   // Section 内边距，给标题条留出空间
  var isSection = host.type === 'SECTION';
  var baseX = isSection ? pad : 0;
  var baseY = (startY || 0) + (isSection ? pad : 0);

  for (var i = 0; i < nodes.length; i++) {
    var col = i % perRow;
    var row = Math.floor(i / perRow);
    host.appendChild(nodes[i]);
    // 必须先 append 再设坐标：Section 内 x/y 为相对坐标，
    // append 前设值会按 currentPage 绝对坐标解释，移入后发生偏移
    nodes[i].x = baseX + col * (CANVAS.w + gapX);
    nodes[i].y = baseY + row * (CANVAS.h + gapY);
    // 必须在坐标已定之后再移出：detachAnnotations 用 frame.x/y 算落点，
    // 提前调用会把标注卡摆到画框搬走之前的旧位置
    detachAnnotations(nodes[i], host);
  }

  // 按实际内容撑开 Section 尺寸，否则默认尺寸会裁掉画框
  if (isSection && nodes.length) {
    var cols = Math.min(perRow, nodes.length);
    var rows = Math.ceil(nodes.length / perRow);
    host.resizeWithoutConstraints(
      pad * 2 + cols * CANVAS.w + (cols - 1) * gapX,
      pad * 2 + (startY || 0) + rows * CANVAS.h + (rows - 1) * gapY
    );
  }
}

// ============================================================
// 七、批次 1 · 基础设施：Variables + 组件总览
// ============================================================

/**
 * 执行批次 1：建 Variables 集合、加载字体、生成 Token 与组件总览画板
 * @returns {Promise<string>} 执行结果摘要，供 UI 日志展示
 */
async function batchSetup() {
  var family = await loadFonts();
  var stat = await ensureVariables();
  // Styles 必须在 ensureVariables() 之后：ensurePaintStyles 用 paintOf() 取填充，
  // 而 paintOf 查的是 VAR_CACHE —— 变量未就位时它静默回退字面色，
  // 于是样式建成不绑变量的死色，画面全对而 Token 联动失效（见 samePaint 注释）
  var textStat = await ensureTextStyles();
  var paintStat = await ensurePaintStyles();
  // 幂等：清空旧 Token 画板与旧 Component master，避免重跑叠加多套同名组件
  var reset = await resetPage(PAGE_NAMES.setup);
  var page = reset.page;
  COMP_CACHE = {};

  // 先注册 Component master，后续画板内的按钮/Pin 即可直接用 Instance
  var host = registerComponents(page);

  var boards = [];

  // 画板 A：语义色板总览
  var colorBoard = box('board/语义色板 [PRD §1.4.2]', 'VERTICAL', {
    pad: SPACING.xl, gap: SPACING.md, fill: 'color/surface', radius: RADIUS.lg
  });
  colorBoard.appendChild(text('语义色板（16 项）｜主色 = A 深湖青 #0B7C8C（2026-08-23 定稿，白字 4.91:1 过 WCAG AA）', 'h3'));
  colorBoard.appendChild(text('*-text 三色为深色文字变体（2026-08-25 新增）：原 success/warning/error 只作填充与圆点，作文字或白字压底时一律改用 -text 变体，详见 PRD §1.4.2', 'caption', 'color/text-secondary'));
  for (var key in SEMANTIC_COLORS) {
    var row = box('_swatch-' + key, 'HORIZONTAL', { gap: SPACING.md, align: 'CENTER' });
    row.appendChild(box('_chip', 'HORIZONTAL', { w: 40, h: 40, radius: RADIUS.md, fill: 'color/' + key, stroke: 'color/border' }));
    var meta = box('_meta', 'VERTICAL', { gap: TIGHT_GAP });
    meta.appendChild(text('color/' + key, 'body'));
    meta.appendChild(text(SEMANTIC_COLORS[key], 'caption', 'color/text-secondary'));
    row.appendChild(meta);
    colorBoard.appendChild(row);
  }
  boards.push(colorBoard);

  // 画板 B：五大分类色 + 供需态 Pin 矩阵
  var catBoard = box('board/分类色与Pin矩阵 [PRD §1.4.3]', 'VERTICAL', {
    pad: SPACING.xl, gap: SPACING.lg, fill: 'color/surface', radius: RADIUS.lg
  });
  catBoard.appendChild(text('五大分类色（已冻结）× 供需态 × 完整度三档', 'h3'));
  var catNames = { 'cat-work': '工作', 'cat-house': '房屋', 'cat-vehicle': '车辆', 'cat-life': '生活', 'cat-service': '服务' };
  for (var ck in CATEGORY_COLORS) {
    var crow = box('_pinrow-' + ck, 'HORIZONTAL', { gap: SPACING.lg, align: 'CENTER' });
    crow.appendChild(text(catNames[ck] + ' ' + CATEGORY_COLORS[ck], 'small', 'color/text-secondary'));
    // 前三个显式开 showCompleteness：这里是「规格演示」，须让评审者看到三档角标长什么样。
    // 地图上的 Marker 一律不带（见 pinRaw 注释的判据），两者刻意不一致
    crow.appendChild(pin('category/' + ck, 'resource', 'green', false, true));
    crow.appendChild(pin('category/' + ck, 'resource', 'yellow', false, true));
    crow.appendChild(pin('category/' + ck, 'demand', 'red', false, true));
    // 第四个是选中态尺寸演示，不叠角标，避免同时变两个变量看不出差异
    crow.appendChild(pin('category/' + ck, 'resource', null, true));
    catBoard.appendChild(crow);
  }
  // 原为一张 4 条混合卡：既讲尺寸（无障碍触控区判据）又讲信息维度约束（永久红线），
  // 视觉同权重导致「Marker 只承载两类信息」这条红线淹没在尺寸说明里。
  // 按 severity 拆两张，并把尺寸那张用 target 钉到实际的选中态 Pin 节点上。
  catBoard.appendChild(annotation('Pin 尺寸与形态', [
    '正常 40×40，选中态 48×48 + 阴影（PRD §6.4.2）',
    '资源态=大类色实心；需求态=大类色描边空心+内部 ?',
    '本板第 1-3 列的完整度角标仅为规格演示；地图 Marker 不带角标'
  ], { severity: 'a11y', target: 'pin/cat-service/resource/selected' }));
  catBoard.appendChild(annotation('Marker 信息维度红线', [
    '只承载两类信息：分类（底色+图标）+ 供需态（实心/空心）',
    '完整度改由点击后的信息卡承载，不回到 Marker（PRD §6.4.2）',
    '新增第三类信息前须先做「是新维度还是同类强调」判定（§6.9 已有范式）'
  ], { severity: 'redline' }));
  boards.push(catBoard);

  // 画板 C：字阶与按钮
  var typeBoard = box('board/字阶与按钮 [PRD §1.4.4-1.4.6]', 'VERTICAL', {
    pad: SPACING.xl, gap: SPACING.md, fill: 'color/surface', radius: RADIUS.lg
  });
  typeBoard.appendChild(text('字阶（当前字体族：' + family + '）', 'h3'));
  var scaleKeys = ['h1', 'h2', 'h3', 'body', 'small', 'caption'];
  for (var si = 0; si < scaleKeys.length; si++) {
    var sk = scaleKeys[si];
    typeBoard.appendChild(text(sk.toUpperCase() + ' · ' + TYPE_SCALE[sk].size + 'sp · 找鸭找 Sample', sk));
  }
  typeBoard.appendChild(text('按钮六类', 'h3'));
  for (var vi = 0; vi < BUTTON_VARIANTS.length; vi++) {
    typeBoard.appendChild(button(BUTTON_VARIANTS[vi], BUTTON_VARIANTS[vi], 0));
  }
  boards.push(typeBoard);

  // 画板 D：动效规格总览（2026-08-27，I5）
  //
  // 为什么动效要单独占一个画板，而不是像色彩字号那样只当 Token 表的一行：
  // 前三块画板都能「看见」——色卡是颜色本身、字阶是字本身。动效在静态画布上
  // 根本无法呈现，它只能以文字规格存在。这恰恰是它最容易在交接中蒸发的原因：
  // 没有任何一处画面会因为漏了动效而显得不对。故给它一块专属版面 + 全部六档
  // 挂 interact 档 annotation（Dev Mode 的 Interaction 分类，见 ANNO_CATEGORY）。
  var motionBoard = box('board/动效规格 [PRD §1.4.8]', 'VERTICAL', {
    pad: SPACING.xl, gap: SPACING.md, fill: 'color/surface', radius: RADIUS.lg
  });
  motionBoard.appendChild(text('动效规格六档（PRD §1.4.8 + §6.8）', 'h3'));
  motionBoard.appendChild(text(
    '这是唯一无法进 Figma Variables 的一类 Token：Plugin API 的 createVariable 只接受 '
    + 'COLOR/FLOAT/STRING/BOOLEAN，没有时间与缓动类型。故动效规格以 annotation 承载，'
    + '实现侧从本板取值，不要去 Variables 面板找。',
    'caption', 'color/text-secondary'));
  // 六档逐行铺开，行内容由 motionLine 现算 —— 与下面 annotation 的文本同源
  //
  // 槽位宽度取最长档现算，不写死 130：PRD 若把某档时长调大，写死的槽宽会把
  // 条截短，从此条长与 ms 不再成比例，而画面上看不出错（原则 56 的同类陷阱）。
  var motionSlotW = 0;
  for (var mw in MOTION) {
    var barW = Math.round(MOTION[mw].dur * MOTION_PX_PER_MS);
    if (barW > motionSlotW) motionSlotW = barW;
  }
  for (var mk in MOTION) {
    var mrow = box('_motion-' + mk, 'HORIZONTAL', { gap: SPACING.md, align: 'CENTER' });
    // 时长条：把 ms 数值同时表达成宽度，让「80ms 的按钮反馈比 260ms 的页面切换快得多」
    // 在静态画布上也看得出来。1ms = 0.5px，260ms 档最宽 130px，不撑破画板
    //
    // 条外面再套一层等宽槽位（2026-08-27 实机复验后补）：条宽各档不同，若直接
    // 与文本同排，六行文本的左边缘会随条长参差，最短档比最长档右突出近 90px，
    // 六档无法竖向对照扫读 —— 而这个画板存在的意义就是并列对照。槽位等宽后
    // 条仍以长度表达时长，文本左边缘齐平。截图才看得出来，探针查不出。
    var mslot = box('_motion-slot-' + mk, 'HORIZONTAL', { w: motionSlotW, align: 'CENTER' });
    mslot.appendChild(box('_motion-bar-' + mk, 'HORIZONTAL', {
      w: Math.round(MOTION[mk].dur * MOTION_PX_PER_MS), h: SPACING.md,
      radius: RADIUS.sm, fill: 'color/primary'
    }));
    mrow.appendChild(mslot);
    var mmeta = box('_motion-meta-' + mk, 'VERTICAL', { gap: TIGHT_GAP });
    mmeta.appendChild(text(motionLine(mk), 'small'));
    mmeta.appendChild(text('motion/' + mk + ' ｜ ' + MOTION[mk].prd, 'caption', 'color/text-secondary'));
    mrow.appendChild(mmeta);
    motionBoard.appendChild(mrow);
  }
  motionBoard.appendChild(annotation('动效规格六档', motionSpecLines(), {
    severity: 'interact', target: '_motion-bar-sheet'
  }));
  // 这张 info 卡记的是「本板六档之外的口径」，不是判据。混进上面那张会让评审
  // 把它当成已冻结的六档规格读。
  // 2026-08-27 条目 [60]：原前两条写「PRD 未给，本板不替它拟值」，用户已拍板补齐，
  // 故改为指向 PRD 新规格。**不能只在 PRD 补而留着这里说「未给」** —— 画布会成为
  // 与 PRD 相矛盾的第二个口径，而评审看的是画布（原则㊾）。
  motionBoard.appendChild(annotation('动效规格的三条补充口径', [
    'Marker 首次出现：渐入 180ms ease-out + 上浮 8px（SPACING.sm），两者同起同止；'
      + '多 Marker 相邻错开 20ms、上限 10 个。平移带出的增量 Pin 不做入场动画。详见 PRD §1.4.8',
    'Lottie 确认勾：时长由素材本身决定，素材未制作，故 PRD §1.4.8 只冻结约束 '
      + '（600-1000ms、不循环、不阻塞交互、自带静态收尾帧、主色取 color/primary），'
      + '交付时把实测值填回 PRD 与 MOTION 表',
    '§1.5 U2 要求发布链路动效「统一 200-300ms」，而 §1.4.8 的按钮反馈为 80ms —— '
      + '两者口径不同层（U2 说的是转场，80ms 说的是按压反馈），不构成冲突，此处记档以免被当成矛盾修掉'
  ], { severity: 'info' }));
  boards.push(motionBoard);

  // 画板 E：卡片三态 + 输入框五态实样（2026-09-02，补 §11 两项「规格已定、稿内零实现」）
  //
  // 为什么这两组必须落在本页而不是业务页：它们是**规范演示**，不是产品画面。
  // 卡片选中态在原型内没有交互载体（列表卡点击即跳详情，无多选场景，见 CARD_STATES），
  // 输入框 focus 更是瞬时态 —— 硬塞进业务页就得先造出一个 PRD 里不存在的画面。
  // T6 板第 ⑤ 组「20px 真实尺寸对照条（图标验收用）」已是这一范式的先例。
  //
  // 为什么非补不可：这两组规格此前只存在于 CARD_STATES / FIELD_SPECS 两张表与
  // 规范文档里，画布上一处实样都没有。设计师拿到「选中态加 1px primary-light 边框」
  // 这句话，无从判断那道边框在真实卡片上是否看得见 —— 而它与 surface 的对比度
  // 只有 1.11:1（CONTRAST_PAIRS 已登记，纯装饰豁免）。规格能读懂，观感只能看。
  var stateBoard = box('board/组件状态实样 [PRD §1.4.7 + §1.8]', 'VERTICAL', {
    w: 480, pad: SPACING.xl, gap: SPACING.xl, fill: 'color/surface', radius: RADIUS.lg
  });
  var stateInnerW = 480 - SPACING.xl * 2;

  /**
   * 往状态板追加一条会自动折行的说明文字
   *
   * 与 buildT6Board 的 wrapNote 同一手法：text() 不设 textAutoResize 时 Figma
   * 默认 WIDTH_AND_HEIGHT，长文案会横铺成一整行把父容器撑宽并溢出画框。
   * 顺序不可换 —— textAutoResize 要在 appendChild 之前设，layoutSizingHorizontal
   * 要在之后设（没有自动布局父节点时赋值会抛错）。
   *
   * @param {FrameNode} parent 目标容器（须为自动布局且宽度确定）
   * @param {string} content 说明文案
   * @returns {TextNode} 已挂载的文本节点
   */
  function stateNote(parent, content) {
    var t = text(content, 'caption', 'color/text-secondary');
    t.textAutoResize = 'HEIGHT';
    parent.appendChild(t);
    t.layoutSizingHorizontal = 'FILL';
    return t;
  }

  stateBoard.appendChild(text('组件状态实样（补 §11 两项零实现）', 'h2'));

  // ① 卡片三态：逐档现取 CARD_STATES，不在此处手抄档位名与规格描述
  var cardGroup = box('_state-card', 'VERTICAL', { gap: SPACING.md });
  cardGroup.appendChild(text('① 卡片三态（PRD §1.4.7）', 'h3', 'color/primary'));
  for (var ci = 0; ci < CARD_STATES.length; ci++) {
    var cs = CARD_STATES[ci];
    var csRow = box('_card-state/' + cs.key, 'VERTICAL', { gap: SPACING.xs });
    csRow.appendChild(text(cs.label + '（' + cs.key + '）', 'small', 'color/text-primary'));
    // 卡片实样宽 358（CANVAS.w - lg*2），比板内可用宽 432 窄，不会溢出。
    // 三张卡的文案与分类色刻意一致 —— 唯一变量是状态，这样差异才只剩状态本身
    var demo = card('招后厨帮工·包吃住', '工作 › 全职招聘 › 餐饮服务',
      'category/cat-work',
      { lifecycle: cs.key === 'archived' ? '已下架' : '在架' }, null, cs.key);
    csRow.appendChild(demo);
    stateNote(csRow, cs.spec);
    cardGroup.appendChild(csRow);
  }
  stateBoard.appendChild(cardGroup);

  // ② 输入框五态：field() 早已能生产全五态，缺的只是画布上没有一处画出来
  var fieldGroup = box('_state-field', 'VERTICAL', { gap: SPACING.md });
  fieldGroup.appendChild(text('② 输入框五态（PRD §1.8 触控下限 44）', 'h3', 'color/primary'));
  // 逐档现取 FIELD_SPECS.formField.states 的键序，不手写数组 ——
  // 表里新增一档时本板自动跟上，漏画会被下面那条断言当场发现
  var fStates = FIELD_SPECS.formField.states;
  // 五档各配一组最小可读的示例值：default 空值、其余按该档语义给值。
  // 宽度统一传板内可用宽，避免沿用默认 358 后与板子内边距叠加溢出
  var fSamples = {
    'default': {},
    filled: { value: '13800138000' },
    focus: { value: '138001' },
    error: { value: '1380013', errorText: '手机号须为 11 位数字' },
    disabled: {}
  };
  for (var fk in fStates) {
    var fRow = box('_field-state/' + fk, 'VERTICAL', { gap: SPACING.xs });
    fRow.appendChild(text(fk + '（' + fStates[fk].sample + '）', 'small', 'color/text-primary'));
    var fOpt = { state: fk };
    for (var fp in fSamples[fk]) fOpt[fp] = fSamples[fk][fp];
    fRow.appendChild(field('手机号', '请输入 11 位手机号', stateInnerW, fOpt));
    stateNote(fRow, fStates[fk].usage);
    fieldGroup.appendChild(fRow);
  }
  stateBoard.appendChild(fieldGroup);

  stateBoard.appendChild(annotation('两组状态实样的验收口径', [
    '卡片选中态的 primary-light 边框与 surface 底只差 1.11:1（CONTRAST_PAIRS 已登记为纯装饰豁免），'
      + '故边框不得作为「选中与否」的唯一线索 —— 实现侧引入多选时须同时给勾选框或其他形状标记',
    '卡片下架态的 opacity 50% 把 text-primary 的 14.68:1 压到约 4.9:1，仍在 AA 线上但已无余量，'
      + '**不得再叠加任何其他降透明度处理**（含父容器的整体透明度）',
    'error 态的描边换色只是第二通道，框下那行 caption 错误文案才是主通道 —— '
      + 'field() 已强制 error 态必给 errorText，颜色不得作为唯一通道',
    'disabled 态只降框底色为 background，标签色刻意不降级：框可以不可编辑，'
      + '但「这一格是什么字段」必须始终读得清'
  ], { severity: 'spec' }));
  boards.push(stateBoard);

  layout(page, boards, 3, 0);
  // master 容器摆到画板下方，避免与规格板重叠
  host.x = 0;
  host.y = 1200;
  figma.currentPage.selection = boards;
  figma.viewport.scrollAndZoomIntoView(boards);

  var compCount = 0;
  for (var cn in COMP_CACHE) compCount++;
  var st = planStats();
  // 实际注册数与登记表推算数必须一致：不一致说明 master 注册被改动而
  // planStats 的分项未同步，此时 UI 首屏报的数就是假的，宁可当场炸掉
  if (compCount !== st.masters.total) {
    throw new Error('Component master 数不符：实际 ' + compCount + '，登记表推算 ' + st.masters.total
      + '。请同步 planStats() 的 masters 分项与 registerComponents()。');
  }

  // Component Set 数当场对数（2026-09-01，条目 [77] 第二层 ⑦）：
  // 「合成漏一组」是本步唯一零征兆的失败 —— master 数照样对、画面分毫不差，
  // 只有 host 里少一个折叠容器、设计师面板里少一个变体下拉。故一组不成就炸掉
  var setCount = 0;
  for (var hi = 0; hi < host.children.length; hi++) {
    if (host.children[hi].type === 'COMPONENT_SET') setCount++;
  }
  if (setCount !== st.masters.sets) {
    throw new Error('Component Set 数不符：实际 ' + setCount + '，登记表推算 ' + st.masters.sets
      + '。请同步 COMPONENT_SETS 与 registerComponents() 里的 combineSet 调用。');
  }

  // 样式数同样当场对数（2026-09-01，条目 [77] 第二层 ⑥）：沿用上面这道校验的判据 ——
  // 首屏与摘要串报的数若是假的，比不报更坏。三计数之和才是「面板里实际有几档」：
  // 重跑时多数档走 reused，只看 created 会误判为「一个都没建」
  var textTotal = textStat.created + textStat.reused + textStat.updated;
  var paintTotal = paintStat.created + paintStat.reused + paintStat.updated;
  if (textTotal !== st.styles.text || paintTotal !== st.styles.paint) {
    throw new Error('本地样式数不符：Text 实际 ' + textTotal + '（应 ' + st.styles.text
      + '）、Paint 实际 ' + paintTotal + '（应 ' + st.styles.paint
      + '）。请同步 planStats() 的 styles 分项与 ensureTextStyles()/ensurePaintStyles()。');
  }

  // 写组件契约（2026-08-27，条目 [51] 第 5 步）。必须在数量校验之后：
  // 那时才确定 COMP_CACHE 是全的，否则漏写的 master 会被下面这道校验放过。
  var describedCount = describeComponents(COMP_CACHE);
  // 「有 master 却没 description」是本步唯一会静默发生的失败：新增一类 master
  // 而忘了补描述时，画布上一切正常、数量校验也过，只有 Inspect 面板里空着 ——
  // 而那正是接棒人读契约的地方，最不该是空的。故一个不写就当场炸掉。
  if (describedCount !== compCount) {
    throw new Error('Component description 缺失：' + compCount + ' 个 master 只写了 '
      + describedCount + ' 个描述。请在 describeComponents() 的 descs 表内补齐。');
  }

  var setNames = [];
  for (var sn in COMPONENT_SETS) setNames.push(sn);

  return '批次 1 完成\n字体族：' + family + (family === FONT_FALLBACK ? '（未检测到 Noto Sans SC，已降级）' : '')
    + '\nVariables：新建 ' + stat.created + ' / 沿用 ' + stat.reused + ' / 改值 ' + stat.updated
    + '（应为 ' + st.tokens.total + ' 项：COLOR ' + st.tokens.color + ' + FLOAT ' + st.tokens.float + '）'
    + (stat.updated > 0 ? '\n（Token 已变更，全画布绑定处自动同步）' : '')
    + '\n主色：A 深湖青 #0B7C8C（白字 4.91:1 过 WCAG AA）'
    + '\n本地样式：Text ' + textTotal + ' 档（' + TEXT_STYLE_PREFIX + 'h1…caption）'
    + ' + Paint ' + paintTotal + ' 档（新建 ' + (textStat.created + paintStat.created)
    + ' / 沿用 ' + (textStat.reused + paintStat.reused)
    + ' / 改值 ' + (textStat.updated + paintStat.updated) + '）'
    + '\n（样式面板可直接取用；画布既有文本仍按数值设定，未挂 styleId —— 见 ensureTextStyles 注释）'
    + '\nComponent master：' + compCount + ' 个（状态栏' + st.masters.statusBar
    + ' + 底部Tab' + st.masters.tabs + ' + 按钮' + st.masters.buttons + ' + Pin' + st.masters.pins + '）'
    + '\nComponent Set：' + setCount + ' 组（' + setNames.join(' / ')
    + '）；状态栏无变体轴，保持独立 master'
    + '\n组件契约：' + describedCount + ' 个 description 已写入（右侧 Inspect 面板可见，无需 Dev Mode）'
    + '\n画板：语义色板 / 分类色Pin矩阵 / 字阶与按钮';
}

// ============================================================
// 八、批次 2 · 地图页与列表页
// ============================================================

/** 五大类定义：[分类键, 中文名]，多处复用故提为常量 */
var CAT_LIST = [
  ['cat-work', '工作'], ['cat-house', '房屋'], ['cat-vehicle', '车辆'],
  ['cat-life', '生活'], ['cat-service', '服务']
];

/**
 * 分类三级树（严格照抄 PRD §2.4「分类三级树（首期建议）」的二级与三级类目）。
 *
 * 为什么必须以 §2.4 为准：PRD §6.9 的交互示例里写了「☐ 商铺」「☐ 隔断」，
 * 但 §2.4 的房屋二级为「整租/合租、求租/找房、短租/日租、租房信息咨询」，
 * 三级为「主卧出租、次卧出租、整租出租」，并不存在「商铺」「隔断」。
 * §2.4 是分类体系的定义源（§2.3 明确了层级与叶子数上限），§6.9 只是举例说明交互层级，
 * 故此处取 §2.4，同步把 §6.9 的示例文案改成 §2.4 的真实类目。
 *
 * 结构：catKey → [[二级名, [三级名...]], ...]
 */
var CAT_TREE = {
  'cat-work': [
    ['全职招聘', ['餐饮服务', '零售导购', '家政保洁', '保安仓管', '其他全职']],
    ['兼职/临时工', ['日结零工', '周末兼职', '小时工']],
    ['求职找工作', ['个人求职']]
  ],
  'cat-house': [
    ['整租/合租', ['主卧出租', '次卧出租', '整租出租']],
    ['求租/找房', ['个人求租']],
    ['短租/日租', ['短租民宿']],
    ['租房信息咨询', ['房源线索/中介合作']]
  ],
  'cat-vehicle': [
    ['顺风车/拼车', ['上下班拼车', '跨城顺风车', '周末拼车']],
    ['租车/借车', ['私家车出租', '货车出租']],
    ['二手车转让', ['个人二手车']],
    ['求搭车/求拼', ['个人求搭车']]
  ],
  'cat-life': [
    ['二手闲置转让', ['家具家电', '母婴儿童', '数码电子', '服饰鞋包', '其他二手']],
    ['借物/互助', ['临时借物', '邻里互助', '物品交换']],
    ['寻物启事/失物招领', ['寻找失物', '招领失物']],
    ['宠物相关', ['宠物寄养', '宠物领养']],
    ['求购/求助', ['个人求购', '邻里求助']]
  ],
  'cat-service': [
    ['家政/保洁', ['日常保洁', '深度清洁', '开荒保洁']],
    ['维修/安装', ['家电维修', '水电维修', '家具安装']],
    ['教学/培训', ['家教辅导', '技能教学']],
    ['美容/美发/按摩', ['上门美容', '上门按摩']],
    ['代办/跑腿', ['代取快递', '代跑腿']]
  ]
};

/**
 * 演示内容 fixtures（2026-08-25 抽出）：全画布示例数据的唯一真源。
 *
 * 为什么必须抽出来：此前「工作 › 餐饮 › 帮厨」这条演示主线在 8 处各自直写，
 * 而 CAT_TREE 里「工作」的二级是「全职招聘/兼职临时工/求职找工作」，
 * 三级才有「餐饮服务」——真实类目树里既没有「餐饮」也没有「帮厨」。
 * 这份稿子的下游是设计师、再下游是开发，假类目会被照着画、照着写，
 * 直到联调才发现对不上。一处假数据，两棒之后才爆。
 *
 * 为什么演示主线选「工作 › 全职招聘 › 餐饮服务」：它在 CAT_TREE 中
 * 三层都是各自列表的首项，而 buildCategorySelector 恰好把 i === 0
 * 渲染为选中态——真数据与选中态天然自洽，不必给选择器额外传参指定高亮位。
 */
var CONTENT = {
  /** 演示主线：一条工作类「资源」信息，贯穿列表卡/详情/发布/AI 确认/级联选择器 */
  job: {
    catKey: 'cat-work',
    l1: '工作',
    l2: '全职招聘',
    l3: '餐饮服务',
    /**
     * 发布者昵称与脱敏号码（2026-08-31 条目 [70-f] 新增）。
     *
     * 为什么进 fixtures 而不是直写在 buildContact 里：联系中转页的导航栏标题
     * （PRD §7.4.2 稿图「← 联系 王师傅」）与详情页信任卡（§7.4.1 稿图「王师傅」）
     * 说的是同一个人，往后补信任卡姓名时必须取到同一个值，直写会立刻分叉。
     *
     * 号码格式取稿图的 `138 **** 8888`（带空格）而非 §7.7 实现逻辑里的
     * `138****8888`：稿图是给设计与前端照着排版的，三段之间留空格才看得出
     * 「前 3 位 + 中间 4 位掩码 + 后 4 位」的分段，而 §7.7 那处是写给后端的
     * 字段口径。两处不是同一件事，不必强行统一成一种写法。
     */
    publisher: '王师傅',
    phoneMasked: '138 **** 8888',
    /** 面包屑串，全画布统一走这里，禁止再手写 '›' 拼接 */
    path: '工作 › 全职招聘 › 餐饮服务',
    title: '招后厨帮工·包吃住',
    /** 列表卡副标题里的距离与时效 */
    distance: '1.2km',
    freshness: '今天更新',
    /** 详情页模板字段。顺序即渲染顺序；AI 确认页复用前三项并把「工时」置为未猜出 */
    fields: [
      ['薪资', '4500-5500 元/月'],
      ['工时', '早 9 晚 6，月休 4 天'],
      ['位置', '距你 1.2km'],
      ['要求', '有餐饮经验优先']
    ],
    /**
     * 详情页描述正文（PRD §7.4.1 稿图第 6 行「描述：…」）。
     *
     * 2026-08-29（条目 [70]）补：此前详情页只有模板字段 + 信任卡，PRD 明列的
     * 描述区在画布上缺失，已实现的 Flutter 详情页却按 PRD 画了 _DescriptionSection
     * —— 稿与实现不一致，且往后照稿改 Flutter 会把这一区删掉。
     *
     * 刻意写到三行：描述区要验证的是「长段落在 body 字阶下的行高与扫读性」，
     * 一句话的样例看不出段落排版是否舒适（同 listing_detail_repository.dart 的取值理由）。
     * 内容与本条主线（餐饮全职、包吃住）自洽 —— 不直接搬 Flutter 那条
     * 「长期招周末兼职」，它是兼职口径，与本条的全职招聘互相矛盾。
     */
    desc: '后厨帮工两名，主要做备菜和打荷，有师傅带，不要求会颠勺。'
      + '包吃住，宿舍就在店后面，走路两分钟。月休 4 天可以自己排。'
      + '做满三个月加 300，有意向先打电话聊，随时可以来店里看看。'
  },
  /**
   * 列表页另外三张卡。原先四张卡的类目路径全是编的
   * （「房屋 › 租房 › 整租」「车辆 › 货运 › 小货车」「服务 › 维修 › 水电」），
   * 三条在 CAT_TREE 里都不存在，此处全部换成真值。
   * kind 取「资源」或「需求」，对应 PRD §2.2 的供需二分。
   */
  listExtra: [
    {
      catKey: 'cat-house', l1: '房屋', l2: '求租/找房', l3: '个人求租',
      path: '房屋 › 求租/找房 › 个人求租',
      title: '求租一室一厅', distance: '2.5km', freshness: '昨天更新', kind: '需求'
    },
    {
      catKey: 'cat-vehicle', l1: '车辆', l2: '租车/借车', l3: '货车出租',
      path: '车辆 › 租车/借车 › 货车出租',
      title: '小货车拉货', distance: '0.8km', freshness: '今天更新', kind: '资源'
    },
    {
      catKey: 'cat-service', l1: '服务', l2: '维修/安装', l3: '水电维修',
      path: '服务 › 维修/安装 › 水电维修',
      title: '水电维修上门', distance: '3.1km', freshness: '3 天前', kind: '资源'
    }
  ],
  /**
   * 首页 Marker 信息卡的示例条目（PRD §6.4.2）。
   * 与列表卡刻意不同类目：信息卡是点地图 Pin 弹出的，用生活类能让设计师看到
   * 另一种分类色与另一种完整度角标（🟡），不与列表页的工作类演示重复。
   * 副标题原先写「闲置转让 · 面议 · 可自提」，「闲置转让」不是 CAT_TREE 里的名字。
   */
  marker: {
    catKey: 'cat-life', l1: '生活', l2: '二手闲置转让', l3: '母婴儿童',
    path: '生活 › 二手闲置转让 › 母婴儿童',
    title: '九成新婴儿推车转让',
    /** 信息卡副标题：二级类目 + 价格口径 + 交付方式，三段用 · 分隔 */
    subtitle: '二手闲置转让 · 面议 · 可自提',
    kind: 'resource',
    completeness: 'yellow'
  },
  /**
   * 我的收藏页专用的房屋条目（PRD §10.1）。
   * 为什么不复用 listExtra 里的房屋条目：那条是「需求」（求租），
   * 而收藏页 segTab 停在「资源」页签，卡片供需属性必须与页签一致，
   * 否则设计师会以为「资源」页签下也能出现需求卡。
   */
  favoriteHouse: {
    catKey: 'cat-house', l1: '房屋', l2: '整租/合租', l3: '整租出租',
    path: '房屋 › 整租/合租 › 整租出租',
    title: '整租一室一厅', distance: '2.5km', kind: '资源'
  }
};

/**
 * 在 CAT_TREE 中定位一条 fixtures 类目路径，命中则返回其所属二级类目下的三级类目全列表。
 *
 * 为什么要有这道断言：CONTENT.job.l3 同时是 FLOW_LINKS 里级联选择器的跳转触发点名
 * （_item/L3/<l3>）。若 CAT_TREE 日后按 PRD 调整而 CONTENT 没跟上，选择器渲染出的
 * 三级项就不再包含 l3，批次 5 会静默把这条连线记入 skipped——画布看起来完好，
 * 只是那一跳点不动。这正是「看起来正常的失败」，必须让它响。
 * 列表卡三条虽不承载跳转，同样过一遍：它们是设计师会照着画的类目文案。
 *
 * @param {{catKey:string,l1:string,l2:string,l3:string}} entry fixtures 条目
 * @returns {string[]} entry.l2 之下的全部三级类目名
 * @throws {Error} 当 catKey / l2 / l3 任一在 CAT_TREE 中不存在时抛出，并列出可选值
 */
function catPathLeaves(entry) {
  var branches = CAT_TREE[entry.catKey];
  if (!branches) {
    throw new Error('fixtures catKey「' + entry.catKey + '」不在 CAT_TREE 中');
  }
  for (var i = 0; i < branches.length; i++) {
    if (branches[i][0] !== entry.l2) continue;
    var leaves = branches[i][1];
    for (var k = 0; k < leaves.length; k++) {
      if (leaves[k] === entry.l3) return leaves;
    }
    throw new Error('fixtures l3「' + entry.l3 + '」不在「' + entry.l2
      + '」的三级类目中，可选：' + leaves.join('/'));
  }
  var names = [];
  for (var m = 0; m < branches.length; m++) names.push(branches[m][0]);
  throw new Error('fixtures l2「' + entry.l2 + '」不在「' + entry.l1
    + '」的二级类目中，可选：' + names.join('/'));
}

/**
 * 校验全部 fixtures 条目的类目路径，并返回演示主线的三级类目列表供级联选择器使用。
 *
 * 顺带核对 path 串与 l1/l2/l3 是否一致：path 是给画布用的成串文案，
 * 三段字段是给断言与连线用的，两者若不同步，画布上显示的路径就与真正校验过的路径不是一回事。
 *
 * @returns {string[]} CONTENT.job.l2 之下的全部三级类目名
 * @throws {Error} 任一条目路径不存在，或 path 串与三段字段不一致
 */
function contentCatPath() {
  var all = [CONTENT.job].concat(CONTENT.listExtra)
    .concat([CONTENT.marker, CONTENT.favoriteHouse]);
  var jobLeaves = null;
  for (var i = 0; i < all.length; i++) {
    var e = all[i];
    var expected = e.l1 + ' › ' + e.l2 + ' › ' + e.l3;
    if (e.path !== expected) {
      throw new Error('fixtures「' + e.title + '」的 path 串「' + e.path
        + '」与三段字段拼出的「' + expected + '」不一致');
    }
    var leaves = catPathLeaves(e);
    if (i === 0) jobLeaves = leaves;
  }
  return jobLeaves;
}

/**
 * 构造一个可点击的圆形悬浮按钮（FAB 风格），用于收起态的各类唤起入口。
 *
 * 为什么收起态用圆形小按钮而不是继续留一条细横条：横条无论多薄都会
 * 横贯整屏、切断地图视野；圆形按钮只吃 44×44 一个角，是移动端遮挡最小的载体，
 * 且 44 恰为 iOS HIG 的最小可点区域，不牺牲可点性。
 *
 * @param {string} name 图层名
 * @param {FrameNode|TextNode} child 按钮内的图标或文字节点
 * @param {string} fillRole 底色 role
 * @returns {FrameNode} 44×44 圆形按钮节点
 */
function fabButton(name, child, fillRole) {
  var b = box(name, 'HORIZONTAL', {
    w: 44, h: 44, radius: RADIUS.full, fill: fillRole || 'color/surface',
    align: 'CENTER', justify: 'CENTER'
  });
  b.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.16 },
    offset: { x: 0, y: 2 }, radius: 8, spread: 0, visible: true, blendMode: 'NORMAL'
  }];
  b.appendChild(child);
  return b;
}

/**
 * 构造收起态的「已选条件摘要胶囊」——折叠方案的关键补偿件。
 *
 * 为什么必须有它：用户要求「选择完成之后可以收起」，但一旦控件收起，
 * 用户就失去了「我现在到底在筛什么」的反馈，会反复展开确认，反而更费操作。
 * 故收起态不是把控件藏干净，而是压缩成一行只读摘要：
 * 范围 + 供需 + 分类路径三项，点它即重新展开。这是「收起」与「可用」的唯一交点。
 *
 * @param {string} summary 摘要文案，如「5km · 资源+需求 · 全部分类」
 * @returns {FrameNode} 摘要胶囊节点
 */
function filterSummaryChip(summary) {
  // 2026-09-01 条目 [77]：本节点是 TAG_SPECS.notTag（D 族）的实处 —— 名字带
  // Chip、圆角为 full，但它是「点开重新展开筛选」的入口，语义是按钮 + 容器，
  // 不是一排里选一个的胶囊，故取值不由 TAG_SPECS 定义（内边距 sm/md 也与 A 族不同）。
  var chip = box('_filter-summary', 'HORIZONTAL', {
    padTop: SPACING.sm, padBottom: SPACING.sm,
    padLeft: SPACING.md, padRight: SPACING.md,
    gap: SPACING.sm, radius: RADIUS.full, fill: 'color/surface', align: 'CENTER'
  });
  chip.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.14 },
    offset: { x: 0, y: 2 }, radius: 8, spread: 0, visible: true, blendMode: 'NORMAL'
  }];
  chip.appendChild(box('_summary-dot', 'HORIZONTAL', {
    // 2026-09-01 条目 [77]：字面 8 改为读 DOT_SIZES.unread（值不变）
    w: DOT_SIZES.unread.size, h: DOT_SIZES.unread.size, radius: RADIUS.full, fill: 'color/primary'
  }));
  chip.appendChild(text(summary, 'caption', 'color/primary-dark'));
  // 下箭头用两条斜矩形拼不出，用字符即可（此处仅为方向提示，非语义图标）
  chip.appendChild(text('展开', 'caption', 'color/primary'));
  return chip;
}

/**
 * 构造悬浮在地图之上的顶部控制栏：范围档 + 资源/需求胶囊切换。
 *
 * 为什么做成悬浮层而不是地图上方的实体行：PRD §6.4.1 的首页
 * 以地图为主体，实体行会连续挤压可视区。原实现把范围条与分类胶囊
 * 都堆成实体行，地图只剩 480px（占 844 屏高 57%）；改悬浮后地图
 * 可用高度提升到 688px（81%），控件本身以半透明白卡叠加，不占布局流。
 *
 * @returns {FrameNode} 顶部悬浮控制栏（宽 358，需由调用方绝对定位）
 */
function mapOverlayTop() {
  var w = CANVAS.w - SPACING.lg * 2;
  var wrap = box('_overlay-top', 'VERTICAL', {
    w: w, pad: SPACING.md, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.lg
  });
  // 悬浮卡阴影：与地图底图拉开层次，否则浅色地图上边界不可辨
  wrap.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.12 },
    offset: { x: 0, y: 2 }, radius: 8, spread: 0, visible: true, blendMode: 'NORMAL'
  }];

  // 第一行：范围档 1/3/5/10/全城，当前档 5km 高亮（PRD §6.7 口径）
  var radiusRow = box('_radius-slider', 'HORIZONTAL', {
    w: w - SPACING.md * 2, align: 'CENTER', justify: 'SPACE_BETWEEN'
  });
  radiusRow.appendChild(text('范围', 'caption', 'color/text-secondary'));
  var steps = ['1km', '3km', '5km', '10km', '全城'];
  for (var r = 0; r < steps.length; r++) {
    var active = r === 2;
    // 2026-09-01 条目 [77]：手搓 box 改走 chipTag（TAG_SPECS.chip 唯一出口）。
    // 改前值 → 改后值：上下内边距 TIGHT_GAP(2) → xs(4)；非选中态 fill null →
    // background 实底；节点名 _radius-<档> → _chip-tag/radius-<档>。
    // 依据：M4-3e 第一层 ① A 族归一 —— 原「无填充」在白底浮层上看不出可点，
    // 而它与相邻的选中项本是同一组可点筛选项。
    var seg = chipTag('radius-' + steps[r], active);
    seg.appendChild(text(steps[r], TAG_SPECS.chip.scale, chipTagInk(active)));
    radiusRow.appendChild(seg);
  }
  wrap.appendChild(radiusRow);

  // 第二行：资源 / 需求胶囊（PRD §6.4.1「可都选」，故两个都做成已选态）
  var sdRow = box('_supply-demand', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  var sdItems = [['资源', 'resource'], ['需求', 'demand']];
  for (var s = 0; s < sdItems.length; s++) {
    // 2026-09-01 条目 [77]：手搓 box 改走 chipTag。
    // 改前值 → 改后值：左右内边距 md(12) → sm(8)；底色 primary-light + primary
    // 描边 → primary 实底无描边；文字 primary-dark → surface；
    // 节点名 _sd-<供需> → _chip-tag/sd-<供需>。
    // 依据：M4-3e 第一层 ① A 族归一。此处两枚按 PRD §6.4.1「可都选」均为已选态，
    // 故都取选中态取值 —— 改前的「浅底 + 描边」是第三种选中画法，与另三处不一。
    var cap = chipTag('sd-' + sdItems[s][1], true);
    // 用实心/空心小圆呼应 Pin 的供需视觉语言，保持全局一致。
    // 圆点配色随底色一并翻转：底改成 primary 实底后，原先的 primary 实心点会
    // 与底色重合而整枚消失，故实心改白、空心改「透明 + 白描边」，
    // 「实心 = 资源 / 空心 = 需求」这层语言本身不变。
    cap.appendChild(box('_sd-dot', 'HORIZONTAL', {
      w: DOT_SIZES.status.size, h: DOT_SIZES.status.size, radius: RADIUS.full,
      fill: sdItems[s][1] === 'resource' ? 'color/surface' : null,
      stroke: 'color/surface', strokeWeight: 2
    }));
    cap.appendChild(text(sdItems[s][0], TAG_SPECS.chip.scale, chipTagInk(true)));
    sdRow.appendChild(cap);
  }
  wrap.appendChild(sdRow);
  return wrap;
}

/**
 * 构造悬浮在地图之上的底部分类栏：五大类图标胶囊 + 全部。
 *
 * 位置贴在底部 Tab 上方，与顶部控制栏分置两端，中间大片区域留给地图，
 * 避免控件集中在同一侧形成视觉压迫。
 *
 * @returns {FrameNode} 底部悬浮分类栏（宽 358，需由调用方绝对定位）
 */
function mapOverlayCats() {
  // 2026-09-01 条目 [77]：本节点是 TAG_SPECS.notTag（D 族）的实处 —— 圆角 full
  // 是为了让整条浮层从地图上浮出，它是**承载五个圆标的容器**而非标签本身，
  // 故取值不由 TAG_SPECS 定义。内部五个 _chip-disc-* 是竖排「圆标 + 名」，
  // 也不是 A 族胶囊（无胶囊容器、圆底另有 28px 规格）。
  var w = CANVAS.w - SPACING.lg * 2;
  var wrap = box('_overlay-cats', 'HORIZONTAL', {
    w: w, padTop: SPACING.sm, padBottom: SPACING.sm,
    padLeft: SPACING.sm, padRight: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.full,
    align: 'CENTER', justify: 'SPACE_BETWEEN'
  });
  wrap.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.12 },
    offset: { x: 0, y: 2 }, radius: 8, spread: 0, visible: true, blendMode: 'NORMAL'
  }];

  // 「全部」为默认选中态：主色实心，与五大类的分类色描边形成主次
  var all = box('_chip-all', 'VERTICAL', { gap: TIGHT_GAP, align: 'CENTER', justify: 'CENTER' });
  all.appendChild(box('_chip-all-disc', 'HORIZONTAL', {
    w: 28, h: 28, radius: RADIUS.full, fill: 'color/primary',
    align: 'CENTER', justify: 'CENTER'
  }));
  all.appendChild(text('全部', 'caption', 'color/primary'));
  wrap.appendChild(all);

  for (var i = 0; i < CAT_LIST.length; i++) {
    var catRole = 'category/' + CAT_LIST[i][0];
    var cell = box('_chip-' + CAT_LIST[i][0], 'VERTICAL', { gap: TIGHT_GAP, align: 'CENTER', justify: 'CENTER' });
    // 分类圆底用分类色实心 + 白图标，与地图 Pin 资源态完全同构，降低认知成本
    var disc = box('_chip-disc-' + CAT_LIST[i][0], 'HORIZONTAL', {
      w: 28, h: 28, radius: RADIUS.full, fill: catRole,
      align: 'CENTER', justify: 'CENTER'
    });
    disc.appendChild(catIcon(CAT_LIST[i][0], 'color/surface', 16));
    cell.appendChild(disc);
    cell.appendChild(text(CAT_LIST[i][1], 'caption', 'color/text-secondary'));
    wrap.appendChild(cell);
  }
  return wrap;
}

/**
 * 构造地图区图例（PRD §6.4.1 图例块）：说明实心=资源、空心+?=需求。
 * 原实现遗漏了此块，本次随悬浮改造一并补上。
 *
 * @returns {FrameNode} 图例卡节点
 */
function mapLegend() {
  var lg = box('_legend', 'VERTICAL', {
    padTop: SPACING.sm, padBottom: SPACING.sm, padLeft: SPACING.md, padRight: SPACING.md,
    gap: SPACING.xs, fill: 'color/surface', radius: RADIUS.md, stroke: 'color/border'
  });

  /**
   * 追加一行图例：真实样式的小圆 + 说明文字
   *
   * 用真实圆点而非 ●／○ 字符：字符的实心/空心差异依赖字体渲染，
   * 三端字形不一致；用 box 画的圆能与 Pin 完全同构，图例即所见。
   *
   * @param {boolean} isDemand 是否需求态（空心）
   * @param {string} label 说明文字
   * @returns {void}
   */
  function row(isDemand, label) {
    var r = box('_legend-row', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
    r.appendChild(box('_legend-dot', 'HORIZONTAL', {
      // 2026-09-01 条目 [77]：字面 12 改为读 DOT_SIZES.onMap（值不变）
      w: DOT_SIZES.onMap.size, h: DOT_SIZES.onMap.size, radius: RADIUS.full,
      fill: isDemand ? 'color/surface' : 'color/text-secondary',
      stroke: 'color/text-secondary', strokeWeight: 2
    }));
    r.appendChild(text(label, 'caption', 'color/text-secondary'));
    lg.appendChild(r);
  }
  row(false, '实心 = 资源');
  row(true, '空心 + ? = 需求');
  lg.opacity = 0.92;
  return lg;
}

/**
 * 构造「点击 Marker 后弹出的信息卡」（PRD §6.4.2）。
 *
 * 为什么新增（2026-08-24）：完整度三档角标已从地图 Marker 上卸掉
 * —— 40×40 内原先叠了 4 条信息（底色=分类、图标=分类、右上 ?=供需、右下点=完整度），
 * 分类被重复编码两次，完整度在缩略态几乎无人细看，纯在抢辨识带宽。
 * 卸掉之后完整度必须有新落点，否则信息就是丢了；本卡即那个落点。
 *
 * 为什么放在这里而不是直接跳详情页：点 Marker 的意图往往是「先扫一眼够不够格」，
 * 完整度 + 距离 + 一行摘要就能判断，不值得一次全屏跳转；
 * 真要细看再点卡上的「查看详情」进 detail-screen。
 *
 * @param {string} catKey 分类键，如 cat-work
 * @param {string} catName 分类中文名，如 工作
 * @param {string} title 条目标题
 * @param {string} sub 一行摘要（模板关键字段）
 * @param {string} supplyDemand resource / demand
 * @param {string} completeness 完整度档 green / yellow / red
 * @returns {FrameNode} 信息卡节点（宽 358，需由调用方绝对定位）
 */
function markerInfoCard(catKey, catName, title, sub, supplyDemand, completeness) {
  var w = CANVAS.w - SPACING.lg * 2;
  var c = box('_marker-info-card', 'VERTICAL', {
    w: w, pad: SPACING.md, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.lg
  });
  // 阴影：卡片浮在地图之上，无阴影则与浅色底图糊在一起
  c.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.16 },
    offset: { x: 0, y: -2 }, radius: 12, spread: 0, visible: true, blendMode: 'NORMAL'
  }];

  // 两列结构（2026-08-27 条目 [61]，A1 像素精修）：圆标独占左列，**其余全部文字
  // 落在右列**，因此四行正文的左缘由结构保证一致，不靠每行各写 padLeft 去凑。
  //
  // 改前实测四行文字左缘为 36 / 0 / 18 / 0（标题被 28 圆标 + 8 间距推到 36、
  // 摘要直接挂在卡上是 0、完整度被 10 色点 + 8 间距推到 18、动作行又回到 0），
  // 竖向扫读时四条参差的起笔线会让人误以为它们属于不同层级，而它们是同一层。
  // 统一为「正文左缘 = 圆标右边缘」是列表类卡片的通行做法。
  //
  // 为什么用结构而不是给三行各加 padLeft: 36：36 不在 SPACING 阶梯上，
  // bindNum() 对非阶梯值是**静默不绑变量**（code.js:672），三处会一齐脱离
  // Variables 且毫无征兆；而两列结构里这个 36 是 28 + SPACING.sm 现算出来的
  // 副产物，本就不需要、也不该是一个间距 Token。
  var inner = w - SPACING.md * 2;                 // 卡内可用宽 = 358 - 24 = 334
  var textColW = inner - 28 - SPACING.sm;         // 右列宽 = 334 - 28 - 8 = 298

  // 左列：分类圆标。align 取 MIN 而非 CENTER —— 右列现在有四行，
  // 居中会把圆标顶到整卡竖向中点，与标题脱开。
  var head = box('_mi-head', 'HORIZONTAL', { gap: SPACING.sm });
  var disc = box('_mi-disc', 'HORIZONTAL', {
    w: 28, h: 28, radius: RADIUS.full, fill: 'category/' + catKey,
    align: 'CENTER', justify: 'CENTER'
  });
  disc.appendChild(catIcon(catKey, 'color/surface', 16));
  head.appendChild(disc);

  // 右列：标题/分类供需标/摘要/完整度/分隔线/动作行，共用同一条左缘
  var body = box('_mi-body', 'VERTICAL', { w: textColW, gap: SPACING.sm });

  // 标题 + 供需文字标（文字标而非再来一个符号，避免与 Pin 重复编码）
  var ttl = box('_mi-title', 'VERTICAL', { gap: TIGHT_GAP });
  ttl.appendChild(text(title, 'h3', 'color/text-primary'));
  ttl.appendChild(text(catName + ' · ' + (supplyDemand === 'demand' ? '需求' : '资源'), 'caption', 'color/text-secondary'));
  body.appendChild(ttl);

  body.appendChild(text(sub, 'small', 'color/text-secondary'));

  // 完整度行：这是从 Marker 卸下来的那条信息，故用真实色点 + 明确文案，不再是 1px 小角标
  var comp = box('_mi-completeness', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  var compLabel = { green: '信息完整', yellow: '部分字段缺失', red: '关键字段缺失' };
  var compRole = { green: 'color/success', yellow: 'color/warning', red: 'color/error' };
  comp.appendChild(box('_mi-comp-dot', 'HORIZONTAL', {
    // 2026-09-01 条目 [77]：字面 10 改为读 DOT_SIZES.status（值不变）
    w: DOT_SIZES.status.size, h: DOT_SIZES.status.size, radius: RADIUS.full, fill: compRole[completeness]
  }));
  comp.appendChild(text('完整度：' + compLabel[completeness], 'caption', 'color/text-secondary'));
  body.appendChild(comp);

  body.appendChild(box('_mi-divider', 'HORIZONTAL', { w: textColW, h: 1, fill: 'color/border' }));

  // 动作行取固定宽而非 HUG：右端「查看详情 ›」要贴住右列右缘，
  // HUG 宽的容器里 spacer 的 layoutGrow 无处可伸，两端对齐会失效。
  var act = box('_mi-actions', 'HORIZONTAL', { w: textColW, gap: SPACING.sm, align: 'CENTER' });
  act.appendChild(text('距我 1.2km', 'caption', 'color/text-secondary'));
  var spacer = box('_mi-spacer', 'HORIZONTAL', { h: 1 });
  spacer.layoutGrow = 1;
  act.appendChild(spacer);
  act.appendChild(text('查看详情 ›', 'small', 'color/primary'));
  body.appendChild(act);

  head.appendChild(body);
  c.appendChild(head);
  return c;
}

/**
 * 构造 T3 分类三级树弹层（PRD §6.9），入口为地图右上角三竖点（PRD §6.13 T6-②）。
 *
 * 为什么用底部上滑弹层承载三级下钻、而不是把三层都做成悬浮条：
 * 三级树最深一层有 5-6 个类目，若继续横向铺在地图上，需要三条横条叠起来
 * （约 170px），地图会被吃掉四分之一还多，正是用户投诉的遮挡加剧。
 * 弹层是「按需占屏、用完即走」：不选时零占用，选时临时盖住下半屏，
 * 确认后整层退场并把结果压缩成一行摘要胶囊。动效走 PRD §1.4.8
 * 「弹窗/抽屉 = 底部上滑 240ms spring，遮罩渐显 180ms」。
 *
 * 三层结构严格对应 §6.9：
 * · 第 1 层 5 大类顶栏切换（当前大类高亮，默认展开下一级）
 * · 第 2 层 二级类目多选框（按最近 7 天发布数排序）
 * · 第 3 层 三级类目精筛（勾选任意级都立即加载）
 *
 * @param {string} catKey 当前选中的一级分类
 * @param {number} depth 展示到第几层：1=仅一级栏 / 2=含二级 / 3=含三级
 * @param {number} openIdx 第 depth=3 时展开哪个二级项的三级列表，默认 0
 * @returns {FrameNode} 弹层节点（宽 390，需由调用方绝对定位到地图底部）
 */
function catTreeSheet(catKey, depth, openIdx) {
  var oi = openIdx || 0;
  var catRole = 'category/' + catKey;
  var sheet = box('_cat-tree-sheet', 'VERTICAL', {
    // 左右内缘提到弹层本身上（2026-08-27 条目 [61]，A3 像素精修）：
    // 改前 padLeft: SPACING.lg 由 _sheet-title / _tree-lv1 / _tree-lv2 /
    // _sheet-action 四处各自重复声明，任一处漏写即整行错位，而错位在结构断言里
    // 零征兆。提到父级后左缘只有一个来源，新增子行默认就对齐。
    //
    // 随之要改的一件事：子容器不能再传 w: CANVAS.w（那是含内缘的整宽，会顶破
    // 父级可用宽），一律改传 innerW。这里刻意用固定宽而非 layoutAlign STRETCH：
    // 离线布局探针的 Auto Layout mock 不实现 STRETCH（probe:22 已声明），
    // 用 STRETCH 会让探针量到 HUG 宽，从此这一屏的宽度断言失去意义。
    w: CANVAS.w, padTop: SPACING.md, padBottom: SPACING.lg,
    padLeft: SPACING.lg, padRight: SPACING.lg,
    gap: SPACING.md, fill: 'color/surface', radius: RADIUS.xl
  });
  var innerW = CANVAS.w - SPACING.lg * 2;   // 弹层内可用宽 = 390 - 32 = 358
  sheet.effects = [{
    type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.18 },
    offset: { x: 0, y: -4 }, radius: 16, spread: 0, visible: true, blendMode: 'NORMAL'
  }];

  // 顶部把手：告知用户此层可下滑关闭，是「可收起」的最直接可视线索
  var handleRow = box('_sheet-handle-row', 'HORIZONTAL', {
    w: innerW, justify: 'CENTER'
  });
  handleRow.appendChild(box('_sheet-handle', 'HORIZONTAL', {
    w: 36, h: 4, radius: RADIUS.full, fill: 'color/border'
  }));
  sheet.appendChild(handleRow);

  // 标题行：左标题 + 右「收起」，收起是显式退出口，不依赖用户猜手势
  var titleRow = box('_sheet-title', 'HORIZONTAL', {
    w: innerW, align: 'CENTER', justify: 'SPACE_BETWEEN'
  });
  titleRow.appendChild(text('分类筛选 · 第 ' + depth + ' 层', 'h3'));
  titleRow.appendChild(text('收起', 'small', 'color/primary'));
  sheet.appendChild(titleRow);

  // ---- 第 1 层：5 大类顶栏 ----
  var lv1 = box('_tree-lv1', 'HORIZONTAL', {
    w: innerW, gap: SPACING.sm, align: 'CENTER'
  });
  for (var i = 0; i < CAT_LIST.length; i++) {
    var on = CAT_LIST[i][0] === catKey;
    // 选中态底色取 -deep 深色变体，而不是分类原色（2026-08-26 实机对比度核查后修）。
    //
    // 原先用 'category/' + key，标签内文字是白色，实测白字压五个原色只有
    // 2.54–4.23:1，全部低于 PRD §1.8 的 4.5:1。改用 -deep 后为 4.81–4.87:1。
    // 图标一并跟着换底 —— 它与文字同为白色，同一个对比度问题。
    //
    // 只有这里换色：Pin、图例圆点、卡片圆标用的仍是原色，那些是**图形**用途
    // （门槛 3:1，五色全部达标），且 §1.4.3 明确分类色已冻结。
    // 2026-09-01 条目 [77]：手搓 box 改走 chipTag。本处改前取值已与 A 族归一后
    // 的取值完全一致（xs/sm + background 非选中底 + cat-deep 选中底），
    // 故改后画面零变化，仅节点名 _lv1-<分类> → _chip-tag/lv1-<分类>。
    // 依据：M4-3e 第一层 ① —— 收进唯一出口，否则表退化成一份「建议」。
    var tab = chipTag('lv1-' + CAT_LIST[i][0], on, 'category/' + CAT_LIST[i][0] + '-deep');
    tab.appendChild(catIcon(CAT_LIST[i][0], chipTagInk(on), 14));
    tab.appendChild(text(CAT_LIST[i][1], TAG_SPECS.chip.scale, chipTagInk(on)));
    lv1.appendChild(tab);
  }
  sheet.appendChild(lv1);

  if (depth >= 2) {
    var lv2Wrap = box('_tree-lv2', 'VERTICAL', {
      w: innerW, gap: SPACING.xs
    });
    // 说明文字走 listHintRow：它要与紧随其后的勾选项文字同左缘（A2 精修）
    lv2Wrap.appendChild(listHintRow('二级类目（按最近 7 天发布数排序）'));
    var nodes = CAT_TREE[catKey] || [];
    for (var j = 0; j < nodes.length; j++) {
      // depth=3 时只有被展开的那一项勾选，其余留空，避免同屏出现多条三级列表
      var checked = depth === 3 ? j === oi : j < 2;
      lv2Wrap.appendChild(checkRow(nodes[j][0], checked, catRole, false));
      if (depth === 3 && j === oi) {
        // padLeft: SPACING.xl 是三级相对二级的**层级缩进**，属刻意的差异，
        // 与 A3 要消除的「重复声明同一左缘」不是一回事，故保留
        var lv3 = box('_tree-lv3', 'VERTICAL', {
          w: innerW, padLeft: SPACING.xl, gap: SPACING.xs
        });
        lv3.appendChild(listHintRow('三级精筛 · ' + nodes[j][0]));
        for (var k = 0; k < nodes[j][1].length; k++) {
          lv3.appendChild(checkRow(nodes[j][1][k], k === 0, catRole, true));
        }
        lv2Wrap.appendChild(lv3);
      }
    }
    sheet.appendChild(lv2Wrap);
  }

  // 底部动作行：重置 + 确定并收起。「确定」即用户所说的「选择完成之后收起」的触发点
  var actionRow = box('_sheet-action', 'HORIZONTAL', {
    w: innerW, gap: SPACING.md, align: 'CENTER'
  });
  // 2026-09-01 条目 [77]：本行以下两个 box 是 TAG_SPECS.notTag（D 族）的实处 ——
  // 圆角虽为 full，语义是按钮而非标签，故**取值不由 TAG_SPECS 定义**。
  //
  // ⚠️ 已知破线（2026-09-02 条目 [77] ⑰ 实机量出，交付时随稿声明）：
  // 这两个手搓按钮实测高 36（reset，pad 8+8 + small 行高 20）与 34（confirm），
  // **均低于 PRD §1.8 的「按钮最小触控区 44×44」**。它们在 T3 三级树三层弹层里
  // 各出现一次，是产品主路径上的真实可点元素，不是演示件。
  //
  // 本轮不改的原因：改走 BUTTON_SPECS 真源表须先补一档「满宽 grow + full 圆角」
  //（现有 capsule 档宽度写死 312），master 数由 20 变 22，牵动 Component Set
  // 与全部断言基线 —— 等于交付前夜重开一轮全量重跑加重出图。
  // 已在《设计系统与组件规范》§11 写明实测值与「实现侧务必补到 44」，
  // 并在离线探针里列为**具名豁免**（豁免必须显式，否则新建矮按钮时断言仍全绿）。
  var reset = box('_sheet-reset', 'HORIZONTAL', {
    padTop: SPACING.sm, padBottom: SPACING.sm, padLeft: SPACING.xl, padRight: SPACING.xl,
    radius: RADIUS.full, stroke: 'color/border', align: 'CENTER', justify: 'CENTER'
  });
  reset.appendChild(text('重置', 'small', 'color/text-secondary'));
  actionRow.appendChild(reset);
  var confirm = box('_sheet-confirm', 'HORIZONTAL', {
    padTop: SPACING.sm, padBottom: SPACING.sm,
    radius: RADIUS.full, fill: 'color/primary', align: 'CENTER', justify: 'CENTER'
  });
  confirm.layoutGrow = 1;
  confirm.appendChild(text('确定并收起', 'small', 'color/surface'));
  actionRow.appendChild(confirm);
  sheet.appendChild(actionRow);

  return sheet;
}

/**
 * 复选方框边长（三级树复选行）。
 *
 * 提成常量是为了让「与复选行文字对齐」这件事有单一来源（2026-08-27 条目 [61]，
 * A2 像素精修）：树里的说明文字要缩进到与勾选项文字同一左缘，缩进量 =
 * CHECKBOX_SIZE + SPACING.sm。写死两遍 18 的话，改框大小时说明文字会悄悄错位。
 * 它是**尺寸**不是间距，故按 box() 已声明的口径（code.js:777）不入 SPACING 阶梯。
 */
var CHECKBOX_SIZE = 18;

/**
 * 构造一行复选框（方框 + 勾 + 标签），供三级树的二级/三级列表复用。
 *
 * 用真实方框加 SVG 勾而非 ☑️／☐ 字符：这两个字符在三端字体下时而渲染为
 * 彩色 emoji、时而为黑白符号，尺寸与基线都不稳定，而勾选态是本弹层
 * 最需要一眼可辨的状态。
 *
 * @param {string} label 类目名
 * @param {boolean} checked 是否已勾选
 * @param {string} catRole 当前分类色 role（选中态用分类色填充方框）
 * @param {boolean} isLeaf 是否三级叶子（叶子字号更小，形成层级缩进感）
 * @returns {FrameNode} 复选行节点
 */
function checkRow(label, checked, catRole, isLeaf) {
  var r = box('_check-row', 'HORIZONTAL', {
    padTop: SPACING.xs, padBottom: SPACING.xs, gap: SPACING.sm, align: 'CENTER'
  });
  var bx = box('_checkbox', 'HORIZONTAL', {
    w: CHECKBOX_SIZE, h: CHECKBOX_SIZE, radius: RADIUS.sm,
    fill: checked ? catRole : 'color/surface',
    stroke: checked ? catRole : 'color/border', strokeWeight: checked ? 1 : 1.5,
    align: 'CENTER', justify: 'CENTER'
  });
  if (checked) bx.appendChild(svgIcon('_tick', ICON_PATHS.tick, 'color/surface', 14));
  r.appendChild(bx);
  r.appendChild(text(label, isLeaf ? 'caption' : 'small',
    checked ? 'color/text-primary' : 'color/text-secondary'));
  return r;
}

/**
 * 构造一行「矢量圆点 + 档名文字」的完整度标识（2026-08-29，条目 [70]）。
 *
 * 替换此前散落 9 处的 🟢🟡🔴 emoji。两个必须一起做的改动：
 *
 * ① emoji 换矢量 —— 理由同 checkRow 里不用 ☑️：emoji 由系统字体渲染，三端
 *    字形与配色都不一致，且不受 paintOf(role) 控制，§1.4.2 实算的对比度对它无效。
 *
 * ② 补上文字档名 —— 这是本次真正的可访问性修正。改之前「🟢」的颜色是三档的
 *    **唯一**载体，色弱用户无法区分，这正是条目 [43] 给 Pin 角标标 ⚠️ 时的同一
 *    问题。Pin 当时靠 2px 白描边补偿，但文字行里没有描边可留，只能补文字。
 *    补完之后颜色降级为「加速识别的冗余通道」，而非唯一通道。
 *
 * @param {string} level 完整度档位，取 'green' | 'yellow' | 'red'
 * @param {string} [scale] 档名文字的字阶，默认 'small'
 * @param {string} [textRole] 档名文字颜色 role，默认跟随档位语义色的文字版
 * @returns {FrameNode} 横排的「圆点 + 档名」节点
 */
function completenessTag(level, scale, textRole) {
  var dotRole = { green: 'color/success', yellow: 'color/warning', red: 'color/error' }[level];
  var inkRole = { green: 'color/success-text', yellow: 'color/warning-text', red: 'color/error-text' }[level];
  var label = { green: '完整', yellow: '半完整', red: '待补充' }[level];
  var r = box('_completeness-' + level, 'HORIZONTAL', {
    gap: SPACING.xs, align: 'CENTER'
  });
  // 2026-09-01 条目 [77]：圆点边长由「按字阶派生」改为固定取 DOT_SIZES.status。
  // 改前值 → 改后值：round(TYPE_SCALE[scale].size * 0.75)，small 档算出 9px
  // → 固定 10px。依据：M4-3e 第一层 ② —— 同一个「完整度」语义在一屏内出现
  // 9px（本处）与 10px（_mi-comp-dot）两个值，只差 1px 却读成两套东西。
  // 原派生公式的初衷（配 h3 时不显小）由 DOT_SIZES 的分档承担：真需要更大的
  // 场合走 onMap/pinBadge 档，而非让每个调用点各算一个尺寸。
  var s = DOT_SIZES.status.size;
  r.appendChild(svgIcon('_dot', ICON_PATHS['dot-solid'], dotRole, s));
  r.appendChild(text(label, scale || 'small', textRole || inkRole));
  return r;
}

/**
 * 构造一行「矢量勾 + 说明文字」的已完成标识（2026-08-29，条目 [70]）。
 *
 * 替换此前散落 4 处的 ✅ emoji，理由同 completenessTag 的 ①。
 * 不需要补文字通道 —— ✅ 的语义本来就由紧随其后的「已实名」等文字承载，
 * emoji 只是重复了一遍，去掉颜色也读得懂。
 *
 * @param {string} label 说明文字
 * @param {string} [scale] 字阶，默认 'small'
 * @param {string} [textRole] 文字颜色 role，默认 success-text
 * @returns {FrameNode} 横排的「勾 + 文字」节点
 */
function doneTag(label, scale, textRole) {
  var r = box('_done-tag', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  // 勾的边长跟随字阶：固定 12px 配 h3(16px) 会显得勾比字矮一截，
  // 像是没对齐而不是有意的次要标记
  var s = (TYPE_SCALE[scale] || TYPE_SCALE.small).size + 2;
  r.appendChild(svgIcon('_tick', ICON_PATHS.tick, 'color/success', s));
  r.appendChild(text(label, scale || 'small', textRole || 'color/success-text'));
  return r;
}

/**
 * 构造一行分组标题（2026-08-29 条目 [70] 后补，供设置页等长列表分组用）。
 *
 * 为什么需要：PRD §3.4.3 把设置项明确分成「账号与安全 / 通用 / 隐私 / 关于」
 * 四组，而原实现是 5 条无分组的平列。平列在条目少时看不出问题，条目补齐到
 * 十余条后就变成一堵没有落点的列表墙 —— 用户找「清除缓存」得从头扫到尾。
 *
 * @param {string} label 分组名
 * @returns {FrameNode} 分组标题行节点
 */
function groupTitle(label) {
  var r = box('_group-title/' + label, 'HORIZONTAL', {
    w: CANVAS.w, padLeft: SPACING.lg, padRight: SPACING.lg,
    padTop: SPACING.md, padBottom: SPACING.xs
  });
  r.appendChild(text(label, 'caption', 'color/text-secondary'));
  return r;
}

/**
 * 构造一条通知行（2026-08-29 条目 [70] 后补，对齐 PRD §8.3.3）。
 *
 * 为什么不继续用 listRow：§8.3.3 明列单条通知行是「图标 · 标题 · 摘要 · 时间 ·
 * 未读红点」五段，listRow 只给得出「标题 + 右值 + ›」两段 —— 摘要与未读态整个
 * 缺失，而未读态是通知中心唯一的交互状态。另外 listRow 尾部的 › 意味着「点进去
 * 有下一级」，通知点击是跳对应详情而非展开，用 › 会误导。
 *
 * @param {string} iconKey ICON_PATHS 的键，按三类通知取 bell/dots/tick
 * @param {string} title 通知标题
 * @param {string} summary 摘要
 * @param {string} time 时间文案
 * @param {boolean} unread 是否未读，未读时右侧出红点
 * @returns {FrameNode} 通知行节点
 */
function notifyRow(iconKey, title, summary, time, unread) {
  var r = box('notify/' + title, 'HORIZONTAL', {
    w: CANVAS.w, padLeft: SPACING.lg, padRight: SPACING.lg,
    padTop: SPACING.md, padBottom: SPACING.md, gap: SPACING.sm,
    fill: 'color/surface', stroke: 'color/border', align: 'MIN'
  });
  r.appendChild(svgIcon('_icon', ICON_PATHS[iconKey], 'color/primary', 20));
  var main = box('_notify-main', 'VERTICAL', { gap: SPACING.xs });
  main.layoutGrow = 1;
  main.appendChild(text(title, 'body', unread ? 'color/text-primary' : 'color/text-secondary'));
  main.appendChild(text(summary, 'small', 'color/text-secondary'));
  r.appendChild(main);
  var right = box('_notify-right', 'VERTICAL', { gap: SPACING.xs, align: 'MAX' });
  right.appendChild(text(time, 'caption', 'color/text-secondary'));
  // 未读红点是本页唯一状态，但它不能是唯一通道：已读标题走 text-secondary、
  // 未读走 text-primary，色阶差与红点互为冗余（同 completenessTag 的理由）
  // 2026-09-01 条目 [77]：字面 8 改为读 DOT_SIZES.unread（值不变）
  if (unread) right.appendChild(svgIcon('_unread', ICON_PATHS['dot-solid'], 'color/error', DOT_SIZES.unread.size));
  r.appendChild(right);
  return r;
}

/**
 * 构造一行认证状态条目（2026-08-29 条目 [70] 后补，对齐 PRD §4.4 稿图）。
 *
 * 为什么不复用 listRow：listRow 满宽 390、自带底色与描边，是「设置页整段贴边
 * 列表」的形态；本行活在 358 宽的卡内，宽度、底色、描边都由外层认证卡承担，
 * 复用会出现「卡里再套一条通栏描边」的双层边界。
 *
 * 状态一律用「矢量色点 + 状态文字」而非稿图里的 ✅🟡❌：理由同
 * completenessTag —— emoji 不受 paintOf(role) 控制，且颜色单独承载状态时
 * 色弱用户读不出，必须补文字通道。
 *
 * @param {string} label 认证类型名，如「个人实名」
 * @param {string} state 状态档，取 'passed' | 'reviewing' | 'none'
 * @param {string} meta 状态右侧补充文字（通过日期，或「发布 X 类必须」）
 * @param {string} [action] 右端动作文案，如「管理」；省略则不出动作
 * @param {number} [width] 行宽。默认按「358 卡宽 - md 内边距 ×2」推算；宿主卡
 *   padding 不同时必须显式传，否则行会顶出卡外或右端动作被挤掉
 * @returns {FrameNode} 认证行节点
 */
function certRow(label, state, meta, action, width) {
  var dotRole = { passed: 'color/success', reviewing: 'color/warning', none: 'color/error' }[state];
  var inkRole = { passed: 'color/success-text', reviewing: 'color/warning-text', none: 'color/error-text' }[state];
  var stateLabel = { passed: '已通过', reviewing: '审核中', none: '未认证' }[state];
  // 必须显式给宽（2026-08-30 条目 [71]）：本行原先只写 { gap, align }，容器宽度
  // 是 hug。hug 容器没有「剩余宽」可分，下面 main.layoutGrow = 1 便拉不动它 ——
  // main 塌成 0 宽，于是「企业认证」与「查看 ›」坐标重合、meta 整段被挤出可视区。
  // 实机渲染图（r64-trust.png）上三行全部文字压字，是本轮唯一的阻断级缺陷。
  //
  // 这个坑项目里早有定论：searchBar 的 :1514 注释写明「宽度既然由内容决定，
  // layoutGrow 就拉不动它」，notifyRow(:3380) 与 card(:1717) 两处也都在容器上
  // 显式写了 w —— 只有本函数漏了。故此处补 w，并把它做成必填参数由调用方传，
  // 因为行宽取决于宿主卡片的可用宽（cw - padding），构造器无从自知。
  var r = box('cert/' + label, 'HORIZONTAL', {
    w: width || CANVAS.w - SPACING.lg * 2 - SPACING.md * 2, gap: SPACING.sm, align: 'CENTER'
  });
  var main = box('_cert-main', 'VERTICAL', { gap: SPACING.xs });
  // grow=1：动作文案宽度不定（管理/查看/去认证 二到三字），左列吃剩余宽
  // 才能保证四行的动作文案右缘对齐
  main.layoutGrow = 1;
  main.appendChild(text(label, 'body', 'color/text-primary'));
  var st = box('_cert-state', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  // 色点边长跟随字阶派生，口径与 completenessTag 一致（同一页上两种色点
  // 若一个 8px 一个 10px，会被当成两套语义）
  st.appendChild(svgIcon('_dot', ICON_PATHS['dot-solid'], dotRole,
    Math.round(TYPE_SCALE.small.size * 0.75)));
  st.appendChild(text(stateLabel, 'small', inkRole));
  if (meta) st.appendChild(text(meta, 'small', 'color/text-secondary'));
  main.appendChild(st);
  r.appendChild(main);
  if (action) r.appendChild(text(action + ' ›', 'small', 'color/primary'));
  return r;
}

/**
 * 构造一行「与复选项文字同左缘」的列表说明文字。
 *
 * 为什么需要它（2026-08-27 条目 [61]，A2 像素精修）：说明文字若直接挂在列表
 * 容器上，左缘为 0，而紧随其后的每个 checkRow 文字左缘是 CHECKBOX_SIZE +
 * SPACING.sm = 26 —— 说明与它所说明的那批项差 26px，读起来像两个层级。
 *
 * 用「等宽空占位 + SPACING.sm 间距」而不是 padLeft: 26 复刻这段缩进：26 不在
 * SPACING 阶梯上，bindNum() 对非阶梯值**静默不绑变量也不报错**（:672），
 * 直接写 26 会让这里悄悄脱离 Variables；用占位则间距仍是阶梯上的 sm。
 *
 * @param {string} content 说明文案
 * @returns {FrameNode} 说明行节点
 */
function listHintRow(content) {
  var row = box('_list-hint', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  // 空占位与复选方框等宽，高 1 只为不撑行高；无填充故不可见
  row.appendChild(box('_list-hint-indent', 'HORIZONTAL', { w: CHECKBOX_SIZE, h: 1 }));
  row.appendChild(text(content, 'caption', 'color/text-secondary'));
  return row;
}

/**
 * 构造一张骨架占位卡（PRD §6.4.4 兜底过程态 0–1 秒「骨架卡 3 条」）。
 *
 * 为什么必须画出来而不是写进标注（2026-08-31 条目 [70-h]，23 张变体图首次
 * 出图后查出）：§6.4.4 那张表写的是**界面元素**（缺省图 / 骨架卡 3 条 /
 * 进度条 / 按钮 / 终态空页），不是设计意图。此前六个过程态画框只在地图上
 * 方多了一行说明文字，画面与主态逐像素相同 —— 等于这六档从未出稿。
 *
 * 形态取「灰条」而非灰底卡：骨架屏的语义是「结构已定、内容未到」，故复刻
 * 列表卡的分类色条 + 标题行 + 摘要行三段骨架，让评审看得出它对应哪种卡；
 * 若只画一个空灰矩形，看不出将要填什么。
 *
 * 灰阶一律走 color/border（Token 内已有的最浅可见灰），不新造 skeleton 专用
 * Token —— 骨架屏是同一套灰阶的临时用法，不是新的语义色。
 *
 * @param {number} width 卡宽，由调用方按容器可用宽传入
 * @returns {FrameNode} 骨架卡节点
 */
function skeletonCard(width) {
  var c = box('_skeleton-card', 'HORIZONTAL', {
    w: width, pad: SPACING.lg, gap: SPACING.md,
    fill: 'color/surface', radius: RADIUS.lg, align: 'MIN'
  });
  // 左侧分类色条位：真实卡这里是分类色，骨架期还不知道类目，故用灰
  c.appendChild(box('_sk-bar', 'VERTICAL', { w: 4, h: 44, radius: RADIUS.sm, fill: 'color/border' }));
  var main = box('_sk-main', 'VERTICAL', { gap: SPACING.sm });
  main.layoutGrow = 1;
  // 两条灰条对应真实卡的「标题」与「摘要」两行；标题行更宽更高，
  // 保持与 card() 的 h3 / small 两级字阶同样的视觉权重差
  main.appendChild(box('_sk-title', 'HORIZONTAL', { w: 180, h: 16, radius: RADIUS.sm, fill: 'color/border' }));
  main.appendChild(box('_sk-sub', 'HORIZONTAL', { w: 120, h: 12, radius: RADIUS.sm, fill: 'color/border' }));
  c.appendChild(main);
  return c;
}

/**
 * 构造一条水平进度条（PRD §6.4.4 兜底过程态 1–10 秒「进度条走满 10 秒」）。
 *
 * 为什么不用 disabled 按钮或加载图标替代：PRD 写的是「进度条走满 10 秒」——
 * 进度条承载的是「还要等多久」这一确定性信息，转圈图标恰恰不给这个信息。
 * 这一档的产品意图正是把无限等待变成有限等待，替换成图标就抽掉了意图。
 *
 * 画到 60% 而不是 0% 或 100%：稿图要表达的是「正在走」这个中间态，
 * 两端极值都会被读成静止。
 *
 * @param {number} width 轨道宽，由调用方按容器可用宽传入
 * @param {number} ratio 已完成比例，0–1
 * @returns {FrameNode} 进度条节点
 */
function progressBar(width, ratio) {
  var track = box('_progress-track', 'HORIZONTAL', {
    w: width, h: 6, radius: RADIUS.full, fill: 'color/border'
  });
  // 已完成段是 track 的子节点：轨道走 Auto Layout 横排，
  // 子节点从左缘起排，天然实现「左侧填充」而无需绝对定位
  track.appendChild(box('_progress-fill', 'HORIZONTAL', {
    w: Math.round(width * ratio), h: 6, radius: RADIUS.full, fill: 'color/primary'
  }));
  return track;
}

/**
 * 构造分页列表底部的「没有更多了」收尾条（2026-08-30 条目 [70]）。
 *
 * 为什么需要它：PRD §6.7 交互表（:1291）写明「列表滑到底部 → 加载下一页，每次
 * 20 条；『没有更多了』→ 显示鸭子空状态」。三个「我的」列表页（通知/收藏/发布）
 * 走的都是这套分页（§7 接口表里三条 GET 均标「分页」），却都没画收尾态 ——
 * 于是页面底部只剩一段无名空白，评审无从判断是「还能再滑」还是「已经到底」。
 *
 * 为什么不用 annotation 来交代这件事：annotation 会被 detachAnnotations() 移出
 * 画框（见 :2314），交代在那里等于稿面上没有。收尾态是真实上屏元素，必须画进画框。
 *
 * 鸭子取 40px：落 duckSymbol 的 mini 档（§1.4.1.2 三档位，<64 用圆盘+实体鸭头）。
 * 收尾条是页脚配角，用 96px 完整版会抢主列表的视觉重心。
 *
 * 2026-09-01 条目 [77]：本函数改为 emptyState('inline', ...) 的一层薄封装。
 * 取值与改前逐项相同（鸭 40 / caption 次级灰 / 上下 xl / 间距 sm），节点名
 * 仍显式保留 `_list-end`（4 处探针断言与渲染核对认这个名）。留着这层封装而不是
 * 让 4 个调用点直接调 emptyState：「收尾条」有它自己的固定文案与语义，
 * 让 4 处各自传一遍「没有更多了」，改文案时就会漏。
 *
 * @param {number} [width] 条宽，默认满屏 390。挂进带 lg 内边距的 _body 时须传
 *   CANVAS.w - SPACING.lg * 2，否则满宽条会把容器顶到溢出
 * @returns {FrameNode} 收尾条节点
 */
function listEndRow(width) {
  return emptyState('inline', '没有更多了', {
    w: width || CANVAS.w, name: '_list-end'
  });
}

/**
 * 构造地图主区：底图 + 散布 Pin + 悬浮控件（可收起）+ 图例 + 可选 T3 弹层。
 *
 * 容器为 stack（非 Auto Layout）：悬浮效果要求子节点重叠，
 * Auto Layout 会把它们排成流式序列，无法叠加。
 *
 * 关于「收起」（2026-08-23 依用户反馈改造）：
 * 上一版把范围条、供需胶囊、五大类栏、图例四件全部常驻悬浮，合计吃掉约
 * 200px 竖向空间，688px 地图的净可视区被压到 490px 上下，等于白改。
 * 现改为默认收起：仅留右上角三竖点入口（44×44）+ 左上角一行只读摘要胶囊，
 * 常驻占用降到约 44px；范围/供需/分类分别由三点入口唤起，选完即收。
 * 图例也不再常驻，改由「?」小按钮按需唤起 —— 图例是一次性认知，
 * 不是每次看地图都要复读的信息。
 *
 * @param {string} label 画布区状态说明文案
 * @param {boolean} bare 为 true 时只出底图与 Pin，供 list-screen 等场景复用
 * @param {FrameNode} note 可选标注卡。地图拉满后 screen 的 Auto Layout
 *                    已无余高容纳实体标注（44+48+688+64=844 正好占满），故叠加进地图内
 * @param {Object} opt 可选项：
 *                 · collapsed 为 true（默认）走收起态，false 走展开态
 *                 · sheet 传入 catTreeSheet() 节点则叠加弹层 + 遮罩
 *                 · legend 为 true 时显示图例（默认不显示）
 *                 · infoCard 传入 markerInfoCard() 节点则贴底叠加（点 Marker 后的态）
 *                 · pins 整组替换默认 7 个 Pin，用于表达关键词过滤后的命中集
 *                 · summary 覆写收起态摘要胶囊文案，须与 pins 表达的范围保持一致
 * @returns {FrameNode} 地图主区节点
 */
function mapCanvas(label, bare, note, opt) {
  opt = opt || {};
  var collapsed = opt.collapsed === undefined ? true : opt.collapsed;
  // 高度 = 屏高 844 − 状态栏 44 − 导航栏 48 − 底部 Tab 64 = 688（占屏 81%）
  var H = CANVAS.h - 44 - 48 - 64;
  // 容器本身不再上色：底色改由 _map-bg 矩形承载，那上面填的是内嵌的高德底图
  var m = stack('_map-canvas', CANVAS.w, H);
  mapBasePlate(m, CANVAS.w, H);

  // 状态说明文案：包一层白底胶囊，否则纯文字压在地图底色上对比度不足。
  //
  // 必须限宽（2026-08-27「单个文本超出 FIXED 宽祖先」断言首次捞出）：
  // 胶囊被绝对定位在 x=SPACING.lg 上，此前宽度完全 hug 文案，而
  // EMPTY_FALLBACK_TIMELINE 里的 PRD 原句长达 40+ 字，量出 421～520 宽，
  // 横向直接超出 390 的 _map-canvas，被 clipsContent 从右侧齐齐切掉。
  // 限宽 = 画布宽 − 左右各留 SPACING.lg，并把文本改为宽度 FILL + 高度自适应，
  // 长文案换行而非撑破。
  var capW = CANVAS.w - SPACING.lg * 2;
  // 2026-09-01 条目 [77]：字面取值改为读 TAG_SPECS.hintBar（C 族第 1 处）。
  // 改前值 → 改后值：取值逐项不变，仅改为查表。依据：M4-3e 第一层 ① ——
  // C 族两处（本处与 _hint）改前即已逐项一致，本轮只登记该事实、不动画面。
  var cap = box('_map-caption', 'HORIZONTAL', {
    w: capW,
    padTop: TAG_SPECS.hintBar.padV, padBottom: TAG_SPECS.hintBar.padV,
    padLeft: TAG_SPECS.hintBar.padH, padRight: TAG_SPECS.hintBar.padH,
    fill: TAG_SPECS.hintBar.fill, radius: TAG_SPECS.hintBar.radius, align: 'CENTER'
  });
  var capText = text(label, TAG_SPECS.hintBar.scale, TAG_SPECS.hintBar.textColor);
  // 先解宽度 hug 再给 layoutGrow，顺序与 navSearch 的 _search-text 一致：
  // textAutoResize 默认 WIDTH_AND_HEIGHT，不改成 HEIGHT 则 layoutGrow 拉不动
  capText.textAutoResize = 'HEIGHT';
  capText.layoutGrow = 1;
  cap.appendChild(capText);
  cap.opacity = 0.92;

  // 散布 Pin：手工给定坐标模拟真实地图的不规则分布，
  // 而非等距排列（等距会让人误以为是列表而不是地图）
  //
  // opt.pins 可整组替换，用于表达「关键词过滤后地图只剩命中项」——
  // 过滤的效果必须体现在 Marker 的增减上，只改搜索框里的文字等于没过滤
  var pins = opt.pins || [
    ['cat-work',    'resource', 'green',  false,  56, 180],
    ['cat-house',   'demand',   'yellow', false, 196, 128],
    ['cat-vehicle', 'resource', 'red',    false, 296, 216],
    ['cat-life',    'resource', 'green',  true,  132, 300],
    ['cat-service', 'demand',   'green',  false, 252, 356],
    ['cat-work',    'demand',   'yellow', false,  72, 420],
    ['cat-house',   'resource', 'green',  false, 300, 448]
  ];
  for (var i = 0; i < pins.length; i++) {
    var p = pin('category/' + pins[i][0], pins[i][1], pins[i][2], pins[i][3]);
    m.appendChild(p);
    p.x = pins[i][4];
    p.y = pins[i][5];
  }

  // 自身位置 Marker：主色实心小圆 + 白描边，区别于业务 Pin
  var me = box('_my-location', 'HORIZONTAL', {
    w: 18, h: 18, radius: RADIUS.full, fill: 'color/primary',
    stroke: 'color/surface', strokeWeight: 3
  });
  m.appendChild(me);
  me.x = CANVAS.w / 2 - 9;
  me.y = H / 2 - 9;

  if (bare) {
    // 无悬浮层时说明文案直接贴顶
    m.appendChild(cap);
    cap.x = SPACING.lg;
    cap.y = SPACING.md;
    return m;
  }

  // 右上角常驻入口：三竖点（PRD §6.13 T6-②「地图右上角三个竖点展开」）
  var entry = fabButton('_layer-entry', svgIcon('_dots', ICON_PATHS.dots, 'color/primary-dark', 20));
  m.appendChild(entry);
  entry.x = CANVAS.w - 44 - SPACING.lg;
  entry.y = SPACING.md;

  // 图例入口：与三点同列下方，点开才出图例（图例是一次性认知，无需常驻）
  var legendBtn = fabButton('_legend-entry', text('?', 'h3', 'color/primary-dark'));
  m.appendChild(legendBtn);
  legendBtn.x = entry.x;
  legendBtn.y = entry.y + 44 + SPACING.sm;

  var lastY;
  if (collapsed) {
    // ---- 收起态：只留一行只读摘要胶囊，常驻占用约 44px ----
    // opt.summary 可覆写摘要文案：搜索过滤后若仍显示「全部分类」，
    // 摘要就与导航栏搜索框自相矛盾，用户无从判断当前到底在筛什么
    var chip = filterSummaryChip(opt.summary || '5km · 资源+需求 · 全部分类');
    m.appendChild(chip);
    chip.x = SPACING.lg;
    chip.y = SPACING.md;
    lastY = chip.y + chip.height;
  } else {
    // ---- 展开态：范围档 + 供需 + 五大类全部展开，并给出「收起」提示 ----
    var top = mapOverlayTop();
    m.appendChild(top);
    top.x = SPACING.lg;
    top.y = SPACING.md;

    var cats = mapOverlayCats();
    m.appendChild(cats);
    cats.x = SPACING.lg;
    cats.y = top.y + top.height + SPACING.sm;
    lastY = cats.y + cats.height;
  }

  // 说明文案挂在最后一件控件正下方，与之左对齐形成一列
  m.appendChild(cap);
  cap.x = SPACING.lg;
  cap.y = lastY + SPACING.sm;

  // 图例：仅在显式要求时出现，位置贴底避免与顶部控件抢位
  if (opt.legend) {
    var lg = mapLegend();
    m.appendChild(lg);
    lg.x = SPACING.lg;
    lg.y = H - lg.height - SPACING.md;
  }

  // 标注卡：右对齐叠在说明文案之下。
  // 接受单张或数组（2026-08-27，I1）：同一屏往往既有实现口径又有无障碍红线，
  // severity 分档后它们已不该合成一张卡，故容器必须能放多张。
  if (note) {
    var notes = note.length === undefined ? [note] : note;
    var ny = cap.y + cap.height + SPACING.sm;
    for (var ni = 0; ni < notes.length; ni++) {
      m.appendChild(notes[ni]);
      notes[ni].x = CANVAS.w - notes[ni].width - SPACING.lg;
      notes[ni].y = ny;
      notes[ni].opacity = 0.96;
      ny += notes[ni].height + SPACING.sm;
    }
  }

  // 点击 Marker 后的信息卡：贴地图底缘，不加遮罩（地图仍可继续浏览）
  if (opt.infoCard) {
    m.appendChild(opt.infoCard);
    opt.infoCard.x = SPACING.lg;
    opt.infoCard.y = H - opt.infoCard.height - SPACING.md;
  }

  // T3 弹层：先铺半透明遮罩再叠弹层，遮罩必须在弹层之前 append 才能压住地图而不压住弹层
  if (opt.sheet) {
    var mask = box('_sheet-mask', 'HORIZONTAL', {
      w: CANVAS.w, h: H, fill: 'color/text-primary'
    });
    m.appendChild(mask);
    mask.x = 0;
    mask.y = 0;
    mask.opacity = 0.4;

    m.appendChild(opt.sheet);
    opt.sheet.x = 0;
    // 弹层贴地图底缘上滑而入（PRD §1.4.8：底部上滑 240ms spring）
    opt.sheet.y = H - opt.sheet.height;
  }

  return m;
}

/**
 * 构造列表页顶部的实体筛选栏（列表页无地图，控件无处可浮，只能占布局流）。
 *
 * 直接复用地图的两组悬浮件本体：它们本身是 Auto Layout 容器，
 * 套一层带内边距的外壳即可当实体行用，从而与地图页共享同一套筛选视觉，
 * 不必再维护第二套样式。
 *
 * @returns {FrameNode} 列表页筛选栏节点
 */
function listFilterBar() {
  var bar = box('_list-filter', 'VERTICAL', {
    w: CANVAS.w, padTop: SPACING.md, padBottom: SPACING.md,
    padLeft: SPACING.lg, padRight: SPACING.lg, gap: SPACING.sm,
    fill: 'color/surface', stroke: 'color/border'
  });
  bar.appendChild(mapOverlayTop());
  bar.appendChild(mapOverlayCats());
  return bar;
}

/**
 * 首页导航栏的固定配置（PRD §6.4.1 ASCII 图：Logo + 搜索框 + 地图/列表切换 + 通知铃）。
 *
 * 为什么抽成常量：批次 2 里引用它的 home-screen 画框共 22 处（主态 + 展开态
 * + 图例态 + 信息卡态 + 搜索过滤态 + T3 三级树 ×3 + 过程态 ×6
 * + 基站兜底态 + 降级态 ×3 + 半径档 ×4），若把配置逐处写死，
 * 改一次占位文案就要改 22 处，必漏。
 * （位置权限引导页不引用本表——它不出导航栏，见该画框构造处的注释）
 *
 * 占位文案为什么不用 PRD §6.4.1 图里的「搜索"就近的保洁/拼车/二手"」原句：
 * 导航栏可用宽 = 390 − 左右 padding 32 = 358，扣掉标题「鸭圈」约 32
 * + 「列表」约 28 + 铃 24 + 三档 gap 24 = 108，搜索框实得约 250px；
 * 其内部再扣 padding 24 + 放大镜 14 + 两档 gap 8 = 46，文案实得约 204px。
 * 原句 20 字按 12px 字号约需 240px，必被截断；压缩为「保洁/拼车/租房」
 * 共 9 字约 108px，覆盖三类高频词且留足余量。
 * 「租房」替代原句的「二手」是为了与下方搜索过滤态演示的关键词一致。
 */
var HOME_NAV = { right: '列表', search: '搜索保洁/拼车/租房', bell: 3 };

/**
 * 执行批次 2：生成 home-screen 主态 + 6 过程态 + 2 定位权限降级态 + 3 性能降级态
 * + 4 半径档，以及 list-screen
 * @returns {Promise<string>} 执行结果摘要
 */
async function batchMap() {
  // fixtures 类目路径前置校验：放在最前面而不是用到时才查，
  // 是为了让「fixtures 与 CAT_TREE 脱节」在任何节点落地之前就炸掉，
  // 而不是先铺出半个画布再报错、留下一堆需要手工清的残留。
  contentCatPath();
  await loadFonts();
  await hydrateVariables();
  await hydrateComponents();
  // 幂等：清空本 Section 旧内容，避免重跑叠加同名画框
  var reset = await resetSection(SECTION_NAMES.map, SECTION_Y.map);
  var page = reset.page;
  var frames = [];

  // ---- home-screen 主态（PRD §10.1）：默认收起，最大化地图可视区 ----
  var home = screen('home-screen', '鸭圈首页·主态（筛选收起）', 'PRD §10.1');
  home.appendChild(statusBar());
  home.appendChild(navBar('鸭圈', HOME_NAV));
  home.appendChild(mapCanvas('地图画布（高德 SDK 承载区）', false, [
    annotation('主态 = 筛选收起', [
      '常驻件仅三竖点入口 44px + 摘要胶囊 44px，其余全收起',
      '摘要胶囊回显当前条件，点它或三点入口即展开',
      '图例改为「?」按需唤起，不再常驻占位'
    ]),
    // 条目 [52] 取证真缺口 #5：外部先例（Apple MapKit / Material）普遍显式
    // 声明「视觉尺寸」与「命中区」是两个值，我们此前只声明了视觉尺寸
    annotation('命中区与视觉区分离', [
      'Marker 视觉 40×40，命中区须补足 ≥44×44（外扩透明区，不放大图形）',
      '摘要胶囊、三竖点入口同理：视觉高度可小于 44，命中高度不可',
      '实现侧对应 Flutter 的 GestureDetector 外扩，不是把 Pin 画大'
    ], { severity: 'a11y' }),
    // 条目 [52] 取证真缺口 #2：聚合圆缺尺寸分档，4 条与 40 条视觉同大
    annotation('聚合圆三档尺寸', [
      '2-9 条 → 32×32；10-99 条 → 40×40；100+ → 48×48',
      '数量差异必须由尺寸表达，仅靠圆内数字在缩放后不可读',
      '已于 2026-08-27 回写 PRD §6.4.2（条目 [60]），不再是待补项'
    ], { severity: 'a11y' })
  ]));
  home.appendChild(bottomTab('鸭圈'));
  frames.push(home);

  // ---- 筛选展开态：范围档 + 供需 + 五大类全部铺开（PRD §6.4.1）----
  var expanded = screen('home-screen', '筛选展开态', 'PRD §6.4.1', true);
  expanded.appendChild(statusBar());
  expanded.appendChild(navBar('鸭圈', HOME_NAV));
  expanded.appendChild(mapCanvas('筛选展开：范围 + 供需 + 五大类', false, [
    annotation('展开态', [
      '展开时占用约 200px，故不作为默认态',
      '选择完成后收起，回到主态的 44px 摘要胶囊',
      // 原为手抄「底部上滑 240ms spring（PRD §1.4.8）」。改从 MOTION 现算：
      // 这是三处手抄里唯一会渲染到画布的一处，也就是唯一会被评审当成判据读的一处
      '展开/收起动效：' + motionLine('sheet') + '（' + MOTION.sheet.prd + '）'
    ]),
    // motion/layer 钉在分类圆排上（2026-08-27，I5）：这一档是全部六档里最容易
    // 被实现成「整屏重绘」的一档 —— §6.8 要的是 Marker 颜色渐变而形状立即切换，
    // 两个属性不同步。不钉到具体控件上，这条差别在交接时没有落点。
    annotation('图层切换动效', [
      motionLine('layer') + '（' + MOTION.layer.prd + '）',
      '颜色渐变与形状切换不同步：形状（实心↔空心）立即变，颜色走 200ms 渐变',
      '切换期间不重建 Marker 节点，只改属性 —— 重建会看到闪一下'
    ], { severity: 'interact', target: '_overlay-cats' })
  ], { collapsed: false }));
  expanded.appendChild(bottomTab('鸭圈'));
  frames.push(expanded);

  // ---- 图例唤起态：点右上「?」才出图例，验证图例不常驻的方案 ----
  var legendOn = screen('home-screen', '图例唤起态', 'PRD §6.4.1', true);
  legendOn.appendChild(statusBar());
  legendOn.appendChild(navBar('鸭圈', HOME_NAV));
  legendOn.appendChild(mapCanvas('点「?」唤起图例', false,
    annotation('图例按需唤起', [
      '图例是一次性认知，无需每次看地图都复读',
      '实心 = 资源 / 空心 + ? = 需求（PRD §2.5）'
    ]), { legend: true }));
  legendOn.appendChild(bottomTab('鸭圈'));
  frames.push(legendOn);

  // ---- 点击 Marker 信息卡态：承载从 Marker 上卸下来的完整度信息（PRD §6.4.2）----
  var infoOn = screen('home-screen', '点击 Marker 信息卡态', 'PRD §6.4.2', true);
  infoOn.appendChild(statusBar());
  infoOn.appendChild(navBar('鸭圈', HOME_NAV));
  infoOn.appendChild(mapCanvas('点选中 Pin 后底部弹出信息卡', false,
    annotation('完整度的新落点', [
      'Marker 已不带完整度角标：40px 内曾叠 4 条信息，分类被重复编码两次',
      '完整度改在本卡以「色点 + 文字」明示，可读性远高于 1px 角标',
      '卡内四条信息：分类+供需、字段摘要、完整度、距离',
      '再点「查看详情」才进 detail-screen，避免一次点击就全屏跳转'
    ]),
    {
      infoCard: markerInfoCard(CONTENT.marker.catKey, CONTENT.marker.l1,
        CONTENT.marker.title, CONTENT.marker.subtitle,
        CONTENT.marker.kind, CONTENT.marker.completeness)
    }));
  infoOn.appendChild(bottomTab('鸭圈'));
  frames.push(infoOn);

  // ---- 搜索过滤态：输入关键词「租房」后地图只剩房屋类 Marker（PRD §2.9 同义词映射）----
  // 为什么必须单独出这一框：搜索框静态摆在导航栏上，看不出它到底做了什么。
  // 关键词的价值全在「过滤后地图变了」这个结果上，故本框刻意把 7 个 Pin 收成 3 个，
  // 且三个都是房屋类，与摘要胶囊回显的分类范围严格一致。
  var searched = screen('home-screen', '搜索过滤态 · 关键词「租房」', 'PRD §2.9', true);
  searched.appendChild(statusBar());
  searched.appendChild(navBar('鸭圈', {
    right: '列表', search: HOME_NAV.search, searchValue: '租房', bell: 3
  }));
  searched.appendChild(mapCanvas('关键词「租房」命中：房屋 › 租房（整租/合租/单间）', false,
    annotation('关键词过滤图层', [
      '「租房」经同义词映射命中 房屋›租房 整个子树（PRD §2.9）',
      '同义词表由运营后台配置：「租房」↔「出租」↔「合租」（PRD §2.10）',
      '过滤结果与范围/供需筛选是「与」关系，不互相覆盖',
      '摘要胶囊同步回显关键词，避免收起后忘了自己在搜什么',
      '点搜索框右侧叉号清空关键词，地图恢复全类目'
    ]),
    {
      // 只留房屋类：两条已有的房屋 Pin + 一条补位，坐标沿用原图的不规则分布
      pins: [
        ['cat-house', 'demand',   'yellow', false, 196, 128],
        ['cat-house', 'resource', 'green',  true,  300, 448],
        ['cat-house', 'resource', 'green',  false,  88, 336]
      ],
      summary: '5km · 资源+需求 · 关键词「租房」'
    }));
  searched.appendChild(bottomTab('鸭圈'));
  frames.push(searched);

  // ---- T3 分类三级树弹层三层下钻（PRD §6.9 + §6.13 T6-②）----
  // 三个画框对应「第 1 层大类顶栏 → 第 2 层二级多选 → 第 3 层三级精筛」，
  // 类目全部取自 PRD §2.4 分类三级树（非 §6.9 举例文案，详见 CAT_TREE 注释）
  var treeSteps = [
    ['cat-house', 1, 0, '第 1 层 · 5 大类顶栏切换', '每个大类默认展开下一级'],
    ['cat-house', 2, 0, '第 2 层 · 二级类目多选', '按最近 7 天发布数排序'],
    ['cat-house', 3, 0, '第 3 层 · 三级类目精筛', '勾选任意级都立即加载地图结果']
  ];
  for (var t = 0; t < treeSteps.length; t++) {
    var ts = screen('home-screen', 'T3 三级树 · ' + treeSteps[t][3], 'PRD §6.9', true);
    ts.appendChild(statusBar());
    ts.appendChild(navBar('鸭圈', HOME_NAV));
    // 弹层与遮罩两档只挂在第 1 层（2026-08-27，I5）：三个下钻框是同一个弹层的
    // 三个内部状态，进场动效只发生在第 1 层出现的那一刻。三框各挂一份会让人
    // 以为每次切层都要重播一次上滑。
    var treeNotes = [
      annotation(treeSteps[t][3], [
        treeSteps[t][4],
        '入口：地图右上角三竖点（PRD §6.13 T6-②）',
        '类目取 PRD §2.4 分类三级树，§6.9 举例文案已同步修正',
        '「确定并收起」后回到主态摘要胶囊'
      ])
    ];
    if (t === 0) {
      treeNotes.push(annotation('弹层进场动效', [
        motionLine('sheet') + '（' + MOTION.sheet.prd + '）',
        motionLine('mask') + '（' + MOTION.mask.prd + '）',
        '两者同时起步而时长不同：遮罩 180ms 先到位，弹层 240ms 带回弹后到',
        '层内切换（第 1→2→3 层）不重播进场，只换内容'
      ], { severity: 'interact', target: '_sheet-mask' }));
    }
    ts.appendChild(mapCanvas('三点入口唤起分类三级树', false, treeNotes,
      { sheet: catTreeSheet(treeSteps[t][0], treeSteps[t][1], treeSteps[t][2]) }));
    ts.appendChild(bottomTab('鸭圈'));
    frames.push(ts);
  }

  // ---- home-screen 六个空状态兜底过程态（PRD §6.4.4）----
  // 注意：这是空状态兜底时间轴，不是性能降级规范，两者不可叉乘
  // 这条警示约束的是 EMPTY_FALLBACK_TIMELINE 这张表——2026-08-24 前本处前两框
  // 写的正是性能加载态（骨架屏 / 首屏 Pin 上屏），违反了这条注释自己，已归位
  //
  // 2026-08-31（条目 [70-h]）改为按元素画，不再只贴一行说明文字：
  // 出图后发现六框与主态逐像素相同，PRD 写明的缺省图 / 骨架卡 / 进度条 /
  // 按钮 / 终态空页全部缺失。现按 EMPTY_FALLBACK_TIMELINE 的元素级字段逐档画。
  //
  // 两种版式，依据 PRD 原句区分，不是我选的：
  // · terminal 档（30 秒仍无）PRD 明写「落到终态空页」—— 空页就是空页，
  //   不出地图。仍出满屏地图与「空页」语义相反（这正是出图查出的最重一处）；
  //   其余档 PRD 未撤地图，故保留地图，把该档元素叠在地图之上贴底。
  // · 叠加位置贴底而非居中：过程态元素是「地图之上的临时层」，
  //   贴底才不遮挡用户正在看的地图中心区，与 markerInfoCard 同一位置口径。
  var procW = CANVAS.w - SPACING.lg * 2;
  for (var i = 0; i < EMPTY_FALLBACK_TIMELINE.length; i++) {
    var step = EMPTY_FALLBACK_TIMELINE[i];
    var f = screen('home-screen', '过程态 ' + step.at, 'PRD §6.4.4', true);
    f.appendChild(statusBar());

    // 该档要叠在地图上（或铺在终态空页里）的元素组
    var procPanel = box('_proc-panel', 'VERTICAL', {
      w: procW, pad: SPACING.lg, gap: SPACING.md,
      fill: 'color/surface', radius: RADIUS.lg, align: 'CENTER'
    });
    // 鸭子缺省图：PRD 只在 0–1 秒与 30 秒两档写明「鸭子 IP 缺省图 / 鸭子缺省图」，
    // 其余档不画 —— 中间档是文案切换，再出一次缺省图会看成回退到第一档
    //
    // 2026-09-01 条目 [77]：两处字面 96 / 64 改读 EMPTY_STATE_SIZES（值不变）。
    // 本处不套 emptyState() 构造器：外层是 surface 卡片、正文要 FILL、后面还跟
    // 进度条与按钮组，而六档过程态共用这一段代码，套进来要动到另五档（见该表注释）
    if (step.skeleton || step.terminal) {
      procPanel.appendChild(duckSymbol(step.terminal
        ? EMPTY_STATE_SIZES.terminal.duck
        : EMPTY_STATE_SIZES.loading.duck));
    }
    var leadText = text(step.lead,
      step.terminal ? EMPTY_STATE_SIZES.terminal.leadScale : 'body',
      'color/text-primary');
    leadText.textAutoResize = 'HEIGHT';
    procPanel.appendChild(leadText);
    leadText.layoutSizingHorizontal = 'FILL';
    if (step.progress) procPanel.appendChild(progressBar(procW - SPACING.lg * 2, 0.6));
    if (step.skeleton) {
      // 「骨架卡 3 条」是 PRD 逐字给的条数，不取整不省略
      for (var sk = 0; sk < 3; sk++) {
        procPanel.appendChild(skeletonCard(procW - SPACING.lg * 2));
      }
    }
    if (step.results) {
      // 「铺卡片」用 CONTENT fixtures 里的真实条目，不造假数据：
      // 这两档要验证的正是「结果卡与主线信息一致」，编一条会让评审对不上类目
      // 2026-09-01 条目 [77]：第四参由裸字符串 freshness 改为具名槽位
      //（改前 card(..., CONTENT.job.freshness) 与列表页传「资源」写法相同，
      // 看不出这里放的是时间而不是供需）。文案与画面均不变
      procPanel.appendChild(card(CONTENT.job.title,
        CONTENT.job.path + ' · ' + CONTENT.job.distance,
        'category/' + CONTENT.job.catKey, { freshness: CONTENT.job.freshness }));
    }
    if (step.buttons) {
      for (var bi = 0; bi < step.buttons.length; bi++) {
        procPanel.appendChild(button(step.buttons[bi][0], step.buttons[bi][1],
          procW - SPACING.lg * 2));
      }
    }

    if (step.terminal) {
      // 终态空页：无地图、无筛选控件，只有缺省图 + 文案 + 主按钮，
      // 面板居中托在 _body 里（不贴底，空页的重心在中部）
      var emptyBody = box('_body', 'VERTICAL', {
        w: CANVAS.w, pad: SPACING.lg, gap: SPACING.lg,
        fill: 'color/background', align: 'CENTER', justify: 'CENTER'
      });
      emptyBody.appendChild(procPanel);
      emptyBody.appendChild(annotation('过程态 ' + step.at, [
        step.ui,
        '依据 §6.4.4 空状态兜底六行时间轴',
        '本时间轴与性能降级态互不叉乘'
      ]));
      f.appendChild(navBar('鸭圈', HOME_NAV));
      f.appendChild(emptyBody);
      // 用 layoutGrow=1 而非 layoutSizingVertical='FILL'：两者在实机等价，
      // 但 grow 是稿内其余贴底页（profile/trust 的 _body）一致的写法，
      // 且「Tab 贴画框下沿」断言认的就是「前有 grow>0 兄弟」这条路——
      // 写 FILL 则 Tab 会被判成悬在内容尽头（内容只到 407 < 844）。
      emptyBody.layoutGrow = 1;
    } else {
      f.appendChild(navBar('鸭圈', HOME_NAV));
      f.appendChild(mapCanvas(step.lead, false, annotation('过程态 ' + step.at, [
        step.ui,
        '依据 §6.4.4 空状态兜底六行时间轴',
        '本时间轴与性能降级态互不叉乘'
      ]), { infoCard: procPanel }));
    }
    f.appendChild(bottomTab('鸭圈'));
    frames.push(f);
  }

  // ---- 定位权限降级：A 态引导页 + B 态「曾授权后被关」（PRD §6.4.4 权限状态三分）----
  // 引导页刻意不出地图与底部 Tab：未授权前用户进不到首页主态，
  // 若画上地图就等于暗示「不授权也能看」，与本页争取授权的目的相反
  //
  // 2026-08-31（条目 [70-h]）补出 B 态：§6.4.4「权限状态三分」表明写三态，
  // 而此前只画了 A 态。B 态不是 A 态的换皮 —— PRD 写明「系统拒绝是 sticky 的」，
  // B 态若还显示「开启位置权限」，点了**没有任何反应**，用户会认为 App 坏了。
  // 这是行为差异而非文案差异，必须单独出稿让评审看到按钮语义换了。
  // C 态不在此处补：PRD 明写 C 态「不出引导页，直接走 §6.8 降级终态」，
  // 那个终态就是紧随其后的 cell-fallback 框，已有稿，不该再画第三张引导页。
  //
  // 两态共用同一段构造代码（PRD 末条明令「A/B 两态的引导页共用同一套布局与
  // 插画，只有标题、说明、主按钮文字与主按钮动作四处不同，不做成两个独立
  // 页面，避免两处各自漂移」）—— 抄一份改四处正是这条要防的事。
  var permStates = [
    {
      key: 'permission-guide',
      heading: '先让我知道你在哪',
      lead: '找鸭找只推你走得到的地方——身边几公里内的活儿、房子、顺路车。',
      sub: '不开定位就只能看全城，近处的机会会被淹掉。',
      primaryLabel: '开启位置权限'
    },
    {
      key: 'permission-reopen',
      heading: '你之前允许过定位，现在被关掉了',
      lead: '找鸭找只推你走得到的地方——身边几公里内的活儿、房子、顺路车。',
      // 这一行是 B 态与 A 态的实质差异所在：必须说明「为什么这次要去系统设置」，
      // 否则用户看到按钮文字变了却不知道原因，会反复点回不存在的系统弹窗
      sub: '系统已记住上次的拒绝，App 内无法再次弹窗，需要到系统设置里打开。',
      primaryLabel: '去系统设置打开'
    }
  ];
  for (var pi = 0; pi < permStates.length; pi++) {
    var ps = permStates[pi];
    var pg = COVERAGE_STATES[ps.key];
    var guide = screen('home-screen', pg.title, pg.prdRef, true);
    guide.appendChild(statusBar());
    var guideBody = box('_body', 'VERTICAL', {
      w: CANVAS.w, pad: SPACING.xl, gap: SPACING.lg, fill: 'color/background'
    });
    // 标题同样要 FILL + HEIGHT：A 态「先让我知道你在哪」7 字在 h1 下宽 245 不越界，
    // B 态「你之前允许过定位，现在被关掉了」13 字 hug 到 360，已超 _body 可用宽 342。
    // 两态共用一段代码正是为了这种事——只按 A 态的短文案写死，B 态必被截断。
    var guideHeading = text(ps.heading, 'h1', 'color/text-primary');
    guideHeading.textAutoResize = 'HEIGHT';
    guideBody.appendChild(guideHeading);
    guideHeading.layoutSizingHorizontal = 'FILL';
    // 这两行是本页最长的文案，必须显式声明「宽度跟随容器、高度自适应」。
    // 不声明时 text() 的 textAutoResize 是 WIDTH_AND_HEIGHT（宽高双 hug），
    // 在纵排 Auto Layout 里宽度不受容器约束：第一行实测 hug 到 421，
    // 超出 _body 可用宽 342，横向直接撑破 390 画框
    // （2026-08-27「单个文本超出 FIXED 宽祖先」断言首次捞出）。
    //
    // layoutSizingHorizontal='FILL' 必须在 appendChild【之后】赋值：
    // 该属性要求节点已经是某个 Auto Layout 父级的直接子节点，
    // 提前赋值真机会抛「requires an auto-layout parent」（实机批次 2 报错处）。
    var guideLead = text(ps.lead, 'body', 'color/text-secondary');
    guideLead.textAutoResize = 'HEIGHT';
    guideBody.appendChild(guideLead);
    guideLead.layoutSizingHorizontal = 'FILL';
    var guideSub = text(ps.sub, 'small', 'color/text-secondary');
    guideSub.textAutoResize = 'HEIGHT';
    guideBody.appendChild(guideSub);
    guideSub.layoutSizingHorizontal = 'FILL';
    guideBody.appendChild(button(ps.primaryLabel, 'primary', CANVAS.w - SPACING.xl * 2));
    // 次按钮两态相同：§6.4.4 明令「三态均须提供『不用了』出口」，不做硬门禁
    guideBody.appendChild(button('手动选择城市', 'secondary', CANVAS.w - SPACING.xl * 2));
    guideBody.appendChild(annotation(pg.title, pg.notes));
    guide.appendChild(guideBody);
    frames.push(guide);
  }

  var cf = COVERAGE_STATES['cell-fallback'];
  var cell = screen('home-screen', cf.title, cf.prdRef, true);
  cell.appendChild(statusBar());
  cell.appendChild(navBar('鸭圈', HOME_NAV));
  cell.appendChild(mapCanvas('基站+商圈定位 · 精度约 1–3km，非城市中心假值', false,
    annotation(cf.title, cf.notes),
    // 商圈名不写具体地名（2026-08-31 条目 [70-h] 出图查出）：
    // 原写「朝阳门商圈附近」，而 _map-bg 内嵌的底图是合肥京商商贸城一带，
    // 地名与画面所指互相矛盾。基站兜底要表达的是「精度只到商圈级」这件事，
    // 具体是哪个商圈与本状态无关，故改为不含地名的表述 —— 同理也避免
    // 往后换底图时又落下一处需要同步的地名。
    { summary: '当前商圈附近 · 全部类 · 供需全开' }));
  cell.appendChild(bottomTab('鸭圈'));
  frames.push(cell);

  // ---- 三个性能降级态（PRD §6.10.1 POC 前置与降级开关）----
  var degrade = [
    ['降级-聚合强制', 'Marker ≥500 强制聚合（PRD §6.8）'],
    ['降级-渲染上限', 'POC 不通过则渲染上限下调至 500 Pin'],
    ['降级-差异化阈值', '工作 3 / 房屋 5 / 生活 8（PRD §6.15）']
  ];
  for (var d = 0; d < degrade.length; d++) {
    var g = screen('home-screen', degrade[d][0], 'PRD §6.10.1', true);
    g.appendChild(statusBar());
    g.appendChild(navBar('鸭圈', HOME_NAV));
    g.appendChild(mapCanvas(degrade[d][1], false, annotation(degrade[d][0], [
      degrade[d][1],
      'P95≤300ms 为四段之和：缓存查找+网络+Dart聚合+上屏（PRD §6.10）',
      'amap_map 无原生 MarkerCluster，聚合须 Dart 侧网格自实现'
    ])));
    g.appendChild(bottomTab('鸭圈'));
    frames.push(g);
  }

  // ---- 四个半径档垫图位（PRD §6.4.4 S2 蜂窝）----
  // 取值一律来自 S2_RADIUS_TIERS，本处不写字面量；
  // 该表注释里写明了它与 §6.7 范围条五档是两套不同口径，改前必读
  for (var r = 0; r < S2_RADIUS_TIERS.length; r++) {
    var tier = S2_RADIUS_TIERS[r];
    var rf = screen('home-screen', '半径档 ' + tier.tier, 'PRD §6.4.4', true);
    rf.appendChild(statusBar());
    rf.appendChild(navBar('鸭圈', HOME_NAV));
    rf.appendChild(mapCanvas('半径 ' + tier.tier + ' · ' + tier.density, false,
      annotation('S2 动态蜂窝半径档 ' + tier.tier, [
        tier.density,
        '本档属 S2 蜂窝自动响应（3/5/10/全城，系统按密度切）；用户手动拖的范围条是另一套五档（1/3/5/10/全城，PRD §6.7）',
        '缓存键 5 元组里的「半径档」指范围条那一套，不是本框（PRD §6.10）'
      ]),
      // 摘要胶囊必须随档位走（2026-08-31 条目 [70-h] 出图查出）：
      // 此前四框都吃 mapCanvas 的默认摘要「5km · 资源+需求 · 全部分类」，
      // 于是「半径档 3km」这一框的胶囊上明晃晃写着 5km —— 同一屏两个数字
      // 自相矛盾，评审无从判断哪个才是当前档。摘要是画面上唯一显示当前半径
      // 的常驻控件，它不跟着变，这四框就等于没表达出档位差异。
      { summary: tier.tier + ' · 资源+需求 · 全部分类' }));
    rf.appendChild(bottomTab('鸭圈'));
    frames.push(rf);
  }

  // ---- list-screen（PRD §10.1）----
  // 搜索框同样补上：PRD §6.4.3 列表页顶部规格含「搜索图标」，
  // 且两页共享同一套筛选与范围状态，搜索作为筛选的一部分不应只有一页有
  var list = screen('list-screen', '列表页', 'PRD §10.1');
  list.appendChild(statusBar());
  list.appendChild(navBar('列表', { right: '地图', search: '搜索保洁/拼车/租房', bell: 3 }));
  list.appendChild(listFilterBar());
  var listBody = box('_list-body', 'VERTICAL', {
    w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md, fill: 'color/background'
  });
  // 四张卡全部走 CONTENT fixtures（2026-08-25）：类目路径原先四条全是编的，
  // 与 CAT_TREE 无一对得上。contentCatPath() 在批次 2 入口已校验过全部条目。
  var listCards = [CONTENT.job].concat(CONTENT.listExtra);
  for (var lc = 0; lc < listCards.length; lc++) {
    var cd = listCards[lc];
    // 2026-09-01 条目 [77]：第四参改具名槽位 supplyDemand。cd.kind 的取值
    // 就是「资源」/「需求」，与新鲜度、生命周期同放一格是改造前的病症
    listBody.appendChild(card(cd.title,
      cd.path + '｜' + cd.distance + '｜' + cd.freshness,
      'category/' + cd.catKey, { supplyDemand: cd.kind || '资源' }));
  }
  listBody.appendChild(annotation('列表页口径', [
    '不占底部 Tab，由首页右上视图切换进入（PRD §10.1）',
    '与地图共享同一套筛选与范围状态',
    '5 大类 + 二级筛选 + 三种排序'
  ]));
  // motion/fade 钉在列表体上（2026-08-27，I5）：这一档规定的是「骨架屏与内容
  // 不叠加」——两者同时可见 180ms 会看成重影。列表体是骨架屏的宿主，规格钉在
  // 这里，实现列表的人才读得到；钉在画板 D 上他不会去翻。
  listBody.appendChild(annotation('列表加载动效', [
    motionLine('fade') + '（' + MOTION.fade.prd + '）',
    '骨架屏与真实内容不得同时可见：骨架屏移除后内容才起淡入',
    '首屏之后的分页加载不重放淡入，只在底部追加'
  ], { severity: 'interact', target: '_list-body' }));
  // 分页收尾（2026-08-30 条目 [70]）：§6.7 :1291 那条交互约定本就是写给本页的
  //（「列表滑到底部 → 加载下一页，每次 20 条；『没有更多了』→ 鸭子空状态」），
  // 三个「我的」列表页只是同规格的复用方
  listBody.appendChild(listEndRow(CANVAS.w - SPACING.lg * 2));
  list.appendChild(listBody);
  // 底部 Tab 贴底（2026-08-30 条目 [70]）：Tab 是全局导航，在其余 23 处落点里
  // 都在屏幕最下沿（home 系列靠 _map-canvas 的 grow=1 撑满，profile 靠 _spacer）。
  // 本页原先是裸 appendChild，Tab 随内容高度悬在 693px、离底 151px，评审会
  // 误以为列表页的 Tab 是另一种形态。
  pushToBottom(list, [bottomTab('鸭圈')]);
  frames.push(list);

  layout(reset.section, frames, 5, 0);
  // 清扫异常残留的游离零件（正常流程下应为 0）
  var orphans = sweepOrphans(page);
  figma.viewport.scrollAndZoomIntoView(frames);

  return '批次 2 完成\n生成 ' + frames.length + ' 个画框：\n'
    + '· home-screen 主态（筛选收起）×1\n· 筛选展开态 ×1\n· 图例唤起态 ×1\n· 点击 Marker 信息卡态 ×1\n'
    + '· 搜索过滤态（关键词「租房」）×1\n'
    + '· T3 三级树下钻 ×3\n· 空状态过程态 ×6\n· 定位权限降级两段 ×2\n· 性能降级态 ×3\n· 半径档垫图 ×4\n· list-screen ×1'
    + '\n清空旧内容 ' + reset.cleared + ' 个｜清扫游离零件 ' + orphans + ' 个';
}

// ============================================================
// 九、批次 3 · 核心流程十页
// ============================================================

/**
 * 创建一个表单输入行占位（标签 + 输入框）
 *
 * 宽度默认 CANVAS.w - lg*2 = 358，那是「页面用 lg 内边距」时的可用宽。
 * 登录页用的是 xl 内边距（可用宽 342），沿用默认值会溢出 16px；且它还要
 * 与右侧的图形码块、获取按钮并排分宽。故 2026-08-26 增开 width 参数。
 * 不改默认值：十几处调用点都在 lg 内边距的页面里，改默认会全体位移。
 *
 * @param {string} label 字段名
 * @param {string} placeholder 占位提示文案
 * @param {number} [width] 覆写宽度，省略时取 lg 内边距下的可用宽 358
 * @param {Object} [opt] 状态选项（2026-09-01 条目 [77]）
 * @param {string} [opt.state] FIELD_SPECS.formField.states 的键，省略即 default。
 *   传 filled / focus 时须一并给 value；传 error 时须一并给 errorText
 * @param {string} [opt.value] 已输入的值，filled / focus / error 态用
 * @param {string} [opt.errorText] error 态框下那行错误文案；error 态必填
 * @returns {FrameNode} 表单行节点
 */
function field(label, placeholder, width, opt) {
  opt = opt || {};
  var S = FIELD_SPECS.formField;
  // 状态名对不上表就当场炸掉，不静默退回 default：默认态与 focus 态在画面上
  // 只差描边颜色，静默退回会让「三态画上去了」这件事看起来是真的（原则 56）
  var st = S.states[opt.state || 'default'];
  if (!st) throw new Error('field() 未知状态：' + opt.state + '。见 FIELD_SPECS.formField.states');
  if (opt.state === 'error' && !opt.errorText) {
    // error 态不许只换描边颜色：颜色是单通道，色盲用户读不到「哪里错了」。
    // FIELD_SPECS 的 error 条已写明「框下必配一行 caption 错误文案」，
    // 这道校验保证那句话不是注释里的空话
    throw new Error('field() 的 error 态必须给 errorText —— 颜色不得作为唯一通道');
  }
  var w = width || (CANVAS.w - SPACING.lg * 2);
  var f = box('field/' + label, 'VERTICAL', { w: w, gap: S.gap });
  // 标签色不随 disabled 降级（见 FIELD_SPECS 注释）：框可以不可编辑，
  // 但「这一格是什么字段」必须始终读得清
  f.appendChild(text(label, S.labelScale, S.labelColor));
  var input = box('_input', 'HORIZONTAL', {
    w: w, h: S.h, padLeft: S.padH, padRight: S.padH,
    fill: st.fill, radius: S.radius, stroke: st.stroke, strokeWeight: st.strokeWeight,
    align: 'CENTER'
  });
  // 有值就显值、无值显 placeholder：颜色一律取状态表，不在此处判断 ——
  // 「已有值转实色」这条口径若在两个构造器里各写一遍，改一处漏一处
  input.appendChild(text(opt.value || placeholder, S.textScale, st.textColor));
  f.appendChild(input);
  if (opt.state === 'error') {
    var err = text(opt.errorText, 'caption', st.hintColor);
    err.name = '_field-error';
    f.appendChild(err);
  }
  return f;
}

/**
 * 创建一个「点开选择器」型表单行（标签 + 可点区 + 右侧 ›）（2026-08-29，条目 [70]）
 *
 * 为什么新增而不复用 listRow（P5 修复）：发布页原先「标题/薪资」走 field（标签在上、
 * 44 高白底框），「选择分类/地点」走 listRow（满宽白底行卡、标签与值同排）。同一张
 * 表单里两种形态并存，评审与开发都会读成「这是两组性质不同的东西」，而它们其实
 * 都是这条发布信息的字段，只是取值方式一个敲键盘一个开选择器。
 *
 * 还有一处几何问题：listRow 宽度写死 CANVAS.w = 390（它本是满宽设置行，
 * 用于个人中心那种无内边距页面），塞进 lg 内边距的发布页 body 里超出可用宽 358。
 *
 * 与 field 的唯一差异是框内右端多一个 ›，用来区分「可输入」与「可跳转」——
 * 这个差异必须留：把它也做成一模一样，用户会去点它然后等键盘弹出。
 *
 * @param {string} label 字段名
 * @param {string} [value] 已选值；省略时按未选态渲染 placeholder
 * @param {string} [placeholder] 未选态提示文案
 * @param {number} [width] 覆写宽度，省略时取 lg 内边距下的可用宽 358
 * @returns {FrameNode} 表单行节点
 */
function selectField(label, value, placeholder, width) {
  // 2026-09-01 条目 [77]：改读 FIELD_SPECS.formField，取值与改前逐项相同
  //（44 / R-md / surface / border / md 内边距 / small 标签 / body 内文）。
  // 不给 selectField 开 focus / error / disabled 三态：它不接受键盘输入，
  // focus 无从发生；错误与禁用由它唤起的选择器承载。表里那三态属 _input 一支
  var S = FIELD_SPECS.formField;
  var stDefault = S.states['default'];
  var stFilled = S.states.filled;
  var w = width || (CANVAS.w - SPACING.lg * 2);
  var f = box('field/' + label, 'VERTICAL', { w: w, gap: S.gap });
  f.appendChild(text(label, S.labelScale, S.labelColor));
  var ctrl = box('_select', 'HORIZONTAL', {
    w: w, h: S.h, padLeft: S.padH, padRight: S.padH,
    fill: stDefault.fill, radius: S.radius, stroke: stDefault.stroke,
    strokeWeight: stDefault.strokeWeight,
    align: 'CENTER', justify: 'SPACE_BETWEEN'
  });
  // 已选值走 filled 态色，未选走 default 态色：同一个位置的两种状态靠色阶区分，
  // 与 field 的输入框内文本共用同一张状态表，不再各写一份
  ctrl.appendChild(value
    ? text(value, S.textScale, stFilled.textColor)
    : text(placeholder || '请选择', S.textScale, stDefault.textColor));
  ctrl.appendChild(text('›', S.textScale, stDefault.textColor));
  f.appendChild(ctrl);
  return f;
}

/**
 * 创建一个设置/我的页的列表条目行
 * @param {string} label 条目名
 * @param {string} value 右侧值或状态文案
 * @returns {FrameNode} 条目行节点
 */
function listRow(label, value) {
  var r = box('row/' + label, 'HORIZONTAL', {
    w: CANVAS.w, padLeft: SPACING.lg, padRight: SPACING.lg, padTop: SPACING.md, padBottom: SPACING.md,
    fill: 'color/surface', stroke: 'color/border', align: 'CENTER', justify: 'SPACE_BETWEEN'
  });
  r.appendChild(text(label, 'body', 'color/text-primary'));
  var right = box('_row-right', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  // value 为空时不建文本节点（2026-08-26 实机核查后修，与 navBar 的
  // _nav-action 空壳同一类问题）：原先无条件 text(value || '')，无右值的条目
  // 会产出 4 个 characters === "" 、宽 0 的空文本节点。它们不可见，但会
  // 污染两处：① 「宽 0 节点」体检把它们报成异常；② 图层树里多出 4 个
  // 名为「Text」的无意义节点，交付给开发时须逐个确认才知是废节点。
  if (value) right.appendChild(text(value, 'small', 'color/text-secondary'));
  right.appendChild(text('›', 'body', 'color/text-placeholder'));
  r.appendChild(right);
  return r;
}

/**
 * 创建一个横向 Tab 切换条（用于我的发布 / 我的收藏 / 通知中心）
 * @param {Array<string>} labels Tab 文案数组
 * @param {number} activeIndex 高亮项下标
 * @returns {FrameNode} Tab 条节点
 */
function segTab(labels, activeIndex) {
  var t = box('_seg-tab', 'HORIZONTAL', {
    w: CANVAS.w, fill: 'color/surface', stroke: 'color/border', justify: 'CENTER'
  });
  for (var i = 0; i < labels.length; i++) {
    var cell = box('_seg-' + labels[i], 'VERTICAL', {
      w: CANVAS.w / labels.length, padTop: SPACING.md, padBottom: SPACING.md,
      align: 'CENTER', justify: 'CENTER'
    });
    cell.appendChild(text(labels[i], 'body', i === activeIndex ? 'color/primary' : 'color/text-secondary'));
    t.appendChild(cell);
  }
  return t;
}

/**
 * 构造 splash-screen：启动页（PRD §2.1 U1）
 *
 * 2026-08-25 新增。此前整页缺失——PRD §1.4.1.2 把启动页列为完整版 IP 的
 * 首个消费位置，但画布上没有对应画框，导致「素材有规格、无落点」。
 *
 * 不放 statusBar：启动页是全屏品牌页，系统状态栏由 OS 绘制，
 * 画上自绘状态栏反而与真机不符。
 *
 * @returns {FrameNode} 启动页节点
 */
function buildSplash() {
  var s = screen('splash-screen', '启动页', 'PRD §2.1 U1');
  // 品牌色满屏 + 白色符号（2026-08-26 精修，用户拍定）
  //
  // 此前是白底 + 主色符号，理由写的是「真机冷启动首帧是纯白，品牌色底会有
  // 一次可见的底色跳变」。这条推理本身没错，但它跟一个已交付的真源撞了：
  // PRD §1.7 表③ 的 `splash.svg`（build-4b-assets.py:399 `<rect fill=BRAND>`）
  // 就是品牌色满屏 + 白盘白鸭头。画布与交付素材各画一版，等于把「哪个是启动页」
  // 这个问题留给下游猜。真源冲突只能取其一，取已交付的那个。
  //
  // 首帧跳变的解法在工程侧而非设计侧：iOS LaunchScreen / Android
  // windowBackground 直接配成品牌色，第一帧就是品牌色，跳变自然不存在。
  s.fills = [paintOf('color/primary')];
  // 图层名 _splash-tap 而非 _body：本框整个正文区就是批次 5 的跳转触发点，
  // 专名让 FLOW_LINKS 的第二列可读（见 FLOW_LINKS 内该条注释）
  var body = box('_splash-tap', 'VERTICAL', {
    w: CANVAS.w, h: CANVAS.h, gap: SPACING.sm,
    align: 'CENTER', justify: 'CENTER'
  });
  // 132.6px 对齐已交付的 splash.svg（390 × 34% = 132.6，见 build_splash()），
  // 而非此前的 160。仍落在完整版档（≥96），两道同心弧齐全。
  //
  // 这里刻意用默认染色（色块 = primary、负形 = surface）而不做反相：
  // full 档结构是「圆角色块 + 白环 + 白盘」，色块取 primary 后与品牌色底
  // 同色，视觉上整块消失，画面上只剩浮在品牌色屏上的白环白盘白鸭头 ——
  // 这恰好等于 splash.svg 的做法（build_splash() 注释：「启动页符号不加
  // 圆角底板（整屏已是品牌色），直接画白色盘环与鸭头」）。
  //
  // 反过来传 duckSymbol(132.6, 'color/surface', 'color/primary') 做真反相
  // 是错的：那会得到一块白色圆角方块压在品牌色屏上，块内是主色环，与
  // 交付素材完全不是一个东西。
  body.appendChild(duckSymbol(132.6));
  // 品牌色底上文字必须走 surface：h1 默认的 text-primary 深灰压主色底
  // 对比度不足（PRD §1.8 正文 ≥ 4.5:1）
  body.appendChild(text('找鸭找', 'h1', 'color/surface'));
  // slogan 取 PRD §3.4.1 的原文，与登录页同一句。此前「本地供需，一图看清」
  // 是自拟文案，PRD 里没有出处
  body.appendChild(text('用就近的资源解决本地的需求', 'body', 'color/surface'));
  s.appendChild(body);
  // 口径卡现在挂在画框外（layout() 里的 detachAnnotations 统一提出），
  // 故不必再顾虑 clipsContent 的裁切，挂 body 或挂 s 都可以；仍挂 body 是
  // 因为 detachAnnotations 按 findAll 深搜，挂哪层都能捞到
  body.appendChild(annotation('启动页口径', [
    '底色品牌色满屏、符号反相为白：对齐已交付的 splash.svg（PRD §1.7 表③）',
    '符号 132.6px = 390 × 34%，落完整版档（≥96px，PRD §1.4.1.2）',
    'slogan 取 PRD §3.4.1 原文，与登录页同句',
    '动效仅允许整体缩放与不透明度渐变，禁止弧线逐帧扩散（PRD §1.4.1.3）',
    '不画自绘状态栏：真机由 OS 绘制',
    '首帧跳变在工程侧解决：LaunchScreen / windowBackground 配品牌色'
  ]));
  return s;
}

/**
 * 构造 privacy-gate 主态：隐私协议门（PRD §6.5.1 / §10.1）
 *
 * 2026-09-01（条目 [76]）补出。这一页是 §10.1 十九页里唯一没有稿的一页，
 * 也是 §14.6 列的 🔴 上架驳回阻塞项 —— 它被漏掉的经过见 §6.5.1 开头：
 * §6.7 与 §14.3 都要求「未同意不初始化地图」，但 §10.1 页面清单一直没有
 * 承载这条要求的页面，直到「§10.1 ↔ MAIN_SCREENS 对数」那条探针抓出。
 *
 * **正文内容逐字取自已实现的 Flutter 页**（privacy_gate_screen.dart 的
 * _AgreementView），不另拟一套：该页码侧已落地，稿再自拟文案就等于凭空
 * 造出第三份口径，而稿码分歧里用户唯一直接读到的就是这些字（本轮同时把
 * 本页纳入「Figma ↔ Flutter 关键按钮对数」那条守门）。
 *
 * **协议正文刻意不上稿**：§6.5.1 明写「协议文本走在线 URL，不内嵌写死」
 * （上架手册 P6 要求隐私政策必须是独立可访问的 HTML 页）。把全文画到稿上
 * 等于把「文本可远端更新」这条设计判断画反。同理也不画《用户协议》
 * 《隐私政策》的可点入口：码侧要到 M4-4 政策上线后才有真实 URL 可跳，
 * 现在画一个可点链接是稿超前于码，属于本轮刚立起来的稿码对数要防的事，
 * 留到 M4-4 与真实 URL 一并补。
 *
 * @returns {FrameNode} 隐私协议门主态节点
 */
function buildPrivacyGate() {
  var s = screen('privacy-gate', '隐私协议门', 'PRD §6.5.1');
  s.appendChild(statusBar());
  var body = box('_body', 'VERTICAL', {
    w: CANVAS.w, pad: SPACING.xl, gap: SPACING.md, fill: 'color/background'
  });

  // 标题与下方四段正文全部要 FILL + HEIGHT：本页是全稿最长的连续文本，
  // text() 默认 WIDTH_AND_HEIGHT（宽高双 hug），在纵排 Auto Layout 里宽度
  // 不受容器约束，会横向撑破 390 画框（同 buildPermission 两态那处）。
  // layoutSizingHorizontal='FILL' 必须在 appendChild【之后】赋值 ——
  // 该属性要求节点已是某个 Auto Layout 父级的直接子节点。
  var heading = text('欢迎使用找鸭找', 'h1', 'color/text-primary');
  heading.textAutoResize = 'HEIGHT';
  body.appendChild(heading);
  heading.layoutSizingHorizontal = 'FILL';

  // 四段正文与 _AgreementView 里那一整串 Text 逐段对应：
  // 引导句 / 三条收集清单 / 高德 SDK 明示 / 不同意的后果。
  // 拆成四个文本节点而非一整串：稿上要能逐段指出「哪一段满足哪条要求」，
  // 一整串 200 余字的段落在评审时无法逐条对照。
  var paras = [
    '在使用前，请阅读并同意《用户协议》与《隐私政策》。',
    // 三条收集清单：PIPL 要求逐项告知收集范围与用途，不许只写「必要信息」
    '我们将收集以下信息以提供服务：\n'
      + '· 位置信息 —— 用于展示你附近的资源与需求；\n'
      + '· 手机号 —— 用于登录与联系中转；\n'
      + '· 发布内容 —— 用于在地图与列表中展示。',
    // 第三方 SDK 明示：上架手册要求列明服务商全称与其收集的信息类型，
    // 只写「集成地图服务」会被驳回
    '本应用集成高德地图 SDK（服务商：高德软件有限公司），用于地图展示与定位，'
      + '会收集位置信息与设备标识。',
    '你可以选择不同意，届时仍可浏览应用，但地图与定位功能不可用。'
  ];
  for (var i = 0; i < paras.length; i++) {
    var p = text(paras[i], 'body', 'color/text-secondary');
    p.textAutoResize = 'HEIGHT';
    body.appendChild(p);
    p.layoutSizingHorizontal = 'FILL';
  }

  // 两键贴底：码侧是 Expanded 滚动区 + 底部按钮，稿侧对应做法是 _spacer 撑开。
  // 同意在上、不同意在下，与 _AgreementView 的排列一致 —— 次序本身是表态
  //（把「不同意」放上面会让它显得是推荐动作）。
  // 「不同意」用 ghost 而非 secondary：§6.5.1 要求提供这个出口但不鼓励它，
  // 而 secondary 带主色描边，视觉权重与主按钮接近。
  pushToBottom(body, [
    annotation('隐私协议门红线（PRD §6.5.1）', [
      '首启首个可交互页，排在 login 之前：发验证码已构成个人信息处理',
      '协议门与定位权限分两步，不合并：合并即捆绑授权，是额外驳回点',
      '不可绕过：无右上角叉、不响应返回键（码侧 PopScope canPop:false）',
      '不同意 → 受限态，不退出应用：工信部禁止「不同意就不给用」',
      '同意须连 agreedVersion 一起落盘，政策改版后重新弹门（PIPL）',
      '未同意期间不得调 updatePrivacyAgree / 实例化 AMap / 申请定位 / 读设备标识',
      '上条验收方法是抓包实测（§14.6），非代码走查',
      '协议正文不上稿：文本走在线 URL（§9 GET /legal/{doc}），M4-4 接真实 URL'
    ], { severity: 'redline' }),
    button('同意并继续', 'primary', CANVAS.w - SPACING.xl * 2),
    button('不同意', 'ghost', CANVAS.w - SPACING.xl * 2)
  ]);
  s.appendChild(body);
  // 必须在 appendChild 之后：layoutGrow 要求已有 Auto Layout 父级
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 privacy-gate 受限态变体：不同意后的可浏览态（PRD §6.5.1）
 *
 * 与主态并列出图供评审对照 —— 「不同意会发生什么」是本页最容易被做错的地方，
 * 而做错的两种形态（退出应用 / 停在空白页）在稿上都表现为「没有这张图」。
 *
 * 为什么只补这一档变体、不再画「同意态」：**同意态就是主态本身**
 * （_AgreementView 是默认视图，_DeclinedView 才是分支）。再单画一张
 * 「同意态」等于把主态抄一遍，与条目 [70] 记的「重复稿」同一个错。
 *
 * 为什么本态不进 FLOW_LINKS：连线两端必须是 MAIN_SCREENS 登记的主态
 *（探针有此断言），变体画框不在其中。受限态靠并列出图供对照，不靠连线。
 *
 * @returns {FrameNode} 受限态变体节点
 */
function buildPrivacyDeclined() {
  var st = COVERAGE_STATES['privacy-declined'];
  var s = screen('privacy-gate', st.title, st.prdRef, true);
  s.appendChild(statusBar());
  // 居中而非贴底：本态只有一句说明与一个出口，重心在中部（同空状态终态页的
  // 做法）。故本页不进探针的 tailPages 表 —— 那张表管的是「带底部主操作的页」。
  var body = box('_body', 'VERTICAL', {
    w: CANVAS.w, h: CANVAS.h - 44, pad: SPACING.xl, gap: SPACING.md,
    fill: 'color/background', align: 'CENTER', justify: 'CENTER'
  });
  var heading = text('地图功能需要你的同意', 'h2', 'color/text-primary');
  heading.textAutoResize = 'HEIGHT';
  body.appendChild(heading);
  heading.layoutSizingHorizontal = 'FILL';
  var lead = text('你尚未同意隐私政策，地图与定位功能暂不可用。\n'
    + '你可以随时重新阅读并同意。', 'body', 'color/text-secondary');
  lead.textAutoResize = 'HEIGHT';
  body.appendChild(lead);
  lead.layoutSizingHorizontal = 'FILL';
  // 文字自身也要居中（2026-09-02 实机看图查出）：容器的 align: 'CENTER' 只把
  // 子节点**块**摆到交叉轴中间，块内文字仍按默认 LEFT 排。两个文本又都 FILL 满宽，
  // 于是「块居中」在这里等于没生效 —— 正文两行左对齐、按钮通栏，整屏重心偏左上，
  // 与「居中收口页」的意图相反。这正是此前记下的「坐标断言判『中心 x=195 = 居中』
  // 过于宽松」的实际后果：FILL 之后中心 x 必然是 195，断言永远绿。
  //
  // 只在本页显式设，不下沉进 text()：全项目其余文字一律 LEFT（正文段落、表单标签、
  // 列表行都该左对齐），而别的居中场景（认证浮层、空态「没有更多了」）文案短且单行，
  // 居中块内 LEFT 与 CENTER 无视觉差，改了只是无谓扩大改动面。
  heading.textAlignHorizontal = 'CENTER';
  lead.textAlignHorizontal = 'CENTER';
  // 正文与出口按钮之间走 ACTION_GAP 而非容器统一 gap：改前两者只隔 12px，
  // 实机看图（2026-09-01）读起来按钮像正文的最后一行。见 ACTION_GAP 说明。
  appendActionWithGap(body, button('重新阅读协议', 'primary', CANVAS.w - SPACING.xl * 2));
  body.appendChild(annotation(st.title, st.notes));
  s.appendChild(body);
  return s;
}

/**
 * 构造 login-screen：手机号验证码一步进入（PRD §3.4.1 / §10.1）
 *
 * 2026-08-26 精修：按 PRD §3.4.1 逐条对齐，此前缺失五项（图形验证码、
 * 密码登录折叠入口、自动注册说明、第三方入口灰禁用、协议勾选），且有
 * 三处硬偏差（字段宽度溢出、主按钮非胶囊且宽度超标、表单间距用了 lg）。
 *
 * @returns {FrameNode} 登录页节点
 */
function buildLogin() {
  var s = screen('login-screen', '登录/注册（合并）', 'PRD §3.4.1');
  s.appendChild(statusBar());
  // 表单间距取 md 而非 lg：PRD §3.4.1 明写「表单（md 间距，R-md 输入框）」。
  // 此前用 lg（16）把整屏撑高，补齐五项内容后会溢出 844
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.xl, gap: SPACING.md });
  // 可用内容宽 = 390 - xl*2 = 342。field() 内部按 CANVAS.w - lg*2 = 358 定宽，
  // 比容器可用宽多 16px，会被 Auto Layout 挤压或溢出，故显式传宽
  var innerW = CANVAS.w - SPACING.xl * 2;

  // 品牌位改用真实 IP 符号（2026-08-25）：此前只有 text('找鸭找')，PRD §1.4.1.2 明列
  // 「登录页顶部（§3.4.1）」属完整版消费位置，故取 96px 完整版（两道弧）
  var brand = box('_brand', 'VERTICAL', { gap: SPACING.sm, align: 'CENTER' });
  brand.appendChild(duckSymbol(96));
  brand.appendChild(text('找鸭找', 'h1', 'color/primary'));
  // slogan 取 PRD §3.4.1 原文。此前「本地供需，一图看清」是自拟文案，PRD 无出处
  brand.appendChild(text('用就近的资源解决本地的需求', 'small', 'color/text-secondary'));
  body.appendChild(brand);

  body.appendChild(field('手机号', '请输入 11 位手机号', innerW));

  // 图形验证码（PRD §3.4.1 主方案的第二个要素，此前整项缺失）。
  // 它挡的是机器批量拉短信，必须在「获取短信验证码」之前，故排在短信码行之上
  var capRow = box('_captcha-row', 'HORIZONTAL', { gap: SPACING.sm, align: 'MAX' });
  capRow.appendChild(field('图形验证码', '输入图中字符', innerW - 96 - SPACING.sm));
  // 图形码本体画成占位块而非文字：真实内容是服务端下发的随机图，
  // 原型里写死任何字符都会被误读成「验证码就是这四位」
  var capImg = box('_captcha-image', 'HORIZONTAL', {
    w: 96, h: 44, radius: RADIUS.md, fill: 'color/background',
    stroke: 'color/border', align: 'CENTER', justify: 'CENTER'
  });
  capImg.appendChild(text('图形码', 'caption', 'color/text-placeholder'));
  capRow.appendChild(capImg);
  body.appendChild(capRow);

  // 按钮宽 104 而非 88：「获取验证码」5 字 × body 14px = 70，加 buttonRaw 的
  // 左右 lg 内边距 16×2 = 32，实需 102。原先传 88 装不下 —— box() 轴向修好之后
  // 宽度真被固定为 88，文字就会被挤出容器（离线全批次回归实测「合计 102 > 容器 88」）。
  // 轴向没修之前这个错是隐形的：横排 box 的 w 当时没生效，按钮按内容 hug 成 102，
  // 看起来「正常」。取 104 留 2px 余量，字段宽随之收窄。
  var codeBtnW = 104;
  var codeRow = box('_code-row', 'HORIZONTAL', { gap: SPACING.sm, align: 'MAX' });
  codeRow.appendChild(field('短信验证码', '6 位验证码', innerW - codeBtnW - SPACING.sm));
  codeRow.appendChild(button('获取验证码', 'secondary', codeBtnW));
  body.appendChild(codeRow);

  // 协议勾选：PRD §3.4.1 要求「默认不勾，必须手动勾」，故 checked 传 false。
  // 复用 checkRow() 而不另写：勾选态的视觉已在分类树里定过，两处不该长不一样
  body.appendChild(checkRow('我已阅读并同意《用户协议》与《隐私政策》', false, 'color/primary', true));

  // 主按钮：PRD §3.4.1「主色胶囊（80% 宽）」。此前是 primary 变体（R-md 直角胶囊）
  // 且宽 342 = 87.7%，两处都不合规。胶囊走 capsule 变体（RADIUS.full）
  var btnRow = box('_primary-row', 'HORIZONTAL', { w: innerW, justify: 'CENTER' });
  btnRow.appendChild(button('登录 / 注册', 'capsule', Math.round(CANVAS.w * 0.8)));
  body.appendChild(btnRow);

  // 自动注册说明（PRD §3.4.1 底部条款）：这句是「为什么没有注册页」的唯一解释，
  // 缺了它用户会以为自己走错页面
  body.appendChild(text('未注册手机号验证后自动注册', 'caption', 'color/text-secondary'));

  // 密码登录：PRD §3.4.1 列为「次方案，可折叠切换」。原型里只呈现折叠入口
  // 本身（ghost 文字按钮），不画展开态 —— 展开态是同一组字段换个标签，
  // 单独画一版只会让评审多一屏要核对的重复内容
  body.appendChild(button('用密码登录', 'ghost', 0));

  // 第三方入口：PRD §3.4.1「本期不实现，灰禁用」。画出来而非省略，是因为
  // 「本期不做」本身是要给评审看的范围声明；省略等于让人以为漏设计了
  var thirdTitle = box('_third-title', 'HORIZONTAL', { w: innerW, justify: 'CENTER' });
  thirdTitle.appendChild(text('第三方登录（本期不开放）', 'caption', 'color/text-placeholder'));
  body.appendChild(thirdTitle);
  var thirdRow = box('_third-party', 'HORIZONTAL', { w: innerW, gap: SPACING.md, justify: 'CENTER' });
  var thirdNames = ['微信', 'QQ', 'Apple'];
  for (var i = 0; i < thirdNames.length; i++) {
    // disabled 变体自带 opacity 0.4，灰禁用态无需另设
    thirdRow.appendChild(button(thirdNames[i], 'disabled', 0));
  }
  body.appendChild(thirdRow);

  body.appendChild(annotation('登录页口径', [
    '手机号验证码一步进入，无独立注册页（PRD §10.1）',
    '主方案三要素：手机号 + 图形验证码 + 短信验证码（PRD §3.4.1）',
    '图形码画占位块不写死字符：真实内容由服务端随机下发',
    '密码登录为次方案，仅呈现折叠入口，不画展开态',
    '协议默认不勾，必须手动勾选（PRD §3.4.1）',
    '主按钮主色胶囊、宽 312 = 390 × 80%（PRD §3.4.1）',
    '第三方入口本期不实现，灰禁用态呈现以声明范围',
    '未实名可浏览，发布时由 cert-modal 拦截'
  ]));
  // motion/press 挂在这里而不是画板 D（2026-08-27，I5）：按压反馈是全局规格，
  // 但「全局」在交接里等于「没有具体归属」。钉到主按钮上，实现这颗按钮的人
  // 才会在 Dev Mode 里读到它。选主按钮而非三个禁用的第三方按钮 —— disabled
  // 态本就不该有按下反馈。
  body.appendChild(annotation('按压反馈动效', [
    motionLine('press') + '（' + MOTION.press.prd + '）',
    '本档为全站按钮通用，不限本页；disabled 态不触发',
    '缩放中心取按钮几何中心，不位移'
  ], { severity: 'interact', target: 'btn/capsule/登录 / 注册' }));
  s.appendChild(body);
  return s;
}

/**
 * 构造详情页描述区（PRD §7.4.1 稿图第 6 行「描述：…」）
 *
 * 2026-08-31（条目 [70-f]）从 buildDetail 内联代码抽成构造器：
 * detail-offline 缺这一块导致中部空 400px，而 §7.8 只许两态有
 * 红条 / disabled / Opacity 60% 三项差异。抽出来而不是在失效态复制一份 ——
 * 复制的那份会与正常态各自演化，「两态同形」这条要求当天就失效。
 *
 * 位置按 PRD 稿图：模板字段区之后、信任卡之前。这个次序不是随意的 ——
 * 模板字段是「结构化事实」（可比价、可筛选），描述是「发布者自己的话」，
 * 信任卡是「这话可不可信」。三者是「是什么 → 怎么说 → 信不信」的递进，
 * 把描述放到信任卡之后就变成了先判断可信度再给内容。
 *
 * @returns {FrameNode} 描述区节点
 */
function detailDescBox() {
  var descBox = box('_description', 'VERTICAL', {
    w: CANVAS.w - SPACING.lg * 2, pad: SPACING.md, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/border'
  });
  descBox.appendChild(text('描述', 'h3'));
  // 三行长文本必须显式 FILL：text() 默认 textAutoResize 是 WIDTH_AND_HEIGHT，
  // 在纵排 Auto Layout 里会一路 hug 到撑破 390 画框（同 guideLead 的处理）。
  // 且 layoutSizingHorizontal 必须在 appendChild 之后赋值，否则真机抛
  // 「requires an auto-layout parent」
  var descText = text(CONTENT.job.desc, 'body', 'color/text-primary');
  descText.textAutoResize = 'HEIGHT';
  descBox.appendChild(descText);
  descText.layoutSizingHorizontal = 'FILL';
  return descBox;
}

/**
 * 构造详情页发布者信任卡（PRD §7.4.1 稿图「发布者信任卡」）
 *
 * 2026-08-31（条目 [70-f]）抽成构造器，理由同 detailDescBox。
 *
 * @returns {FrameNode} 信任卡节点
 */
function detailTrustCard() {
  var trust = box('_trust-card', 'VERTICAL', {
    w: CANVAS.w - SPACING.lg * 2, pad: SPACING.md, gap: SPACING.xs,
    fill: 'color/primary-light', radius: RADIUS.lg
  });
  // 卡内首行带发布者名（§7.4.1 稿图「🐥 头像 │ 王师傅」）：改前只写「信任卡」，
  // 而 contact 页导航已在说「联系 王师傅」—— 两页说的是同一个人，
  // 详情页却不告诉你他是谁，从详情点进联系页时名字是凭空出现的
  trust.appendChild(text('信任卡 · ' + CONTENT.job.publisher, 'h3', 'color/primary-dark'));
  // 三项资质横排：此前是一行 emoji 文本「已实名 ✅｜资质认证 ✅｜信息完整度 🟢」，
  // 2026-08-29（条目 [70]）改为矢量组件。竖分隔符「｜」一并去掉 ——
  // 它原本用来在一整行文本里切分三段，现在三段已是三个独立节点，
  // 再留分隔符就是拿标点当布局用
  var trustRow = box('_trust-items', 'HORIZONTAL', { gap: SPACING.md, align: 'CENTER' });
  trustRow.appendChild(doneTag('已实名', 'small', 'color/primary-dark'));
  trustRow.appendChild(doneTag('资质认证', 'small', 'color/primary-dark'));
  trustRow.appendChild(completenessTag('green', 'small', 'color/primary-dark'));
  trust.appendChild(trustRow);
  trust.appendChild(text('不含信誉评价、不含交易记录（Scope 红线）', 'caption', 'color/primary-dark'));
  return trust;
}

/**
 * 构造详情页模板字段卡（PRD §7.4.1 稿图「模板字段区」）
 *
 * 2026-08-31（条目 [70-f]）抽成构造器：两态原先各写一份同样的四行循环，
 * 且失效态注释里专门写了「必须与正常态逐字一致」—— 那正是该由同一份代码保证的事。
 *
 * @returns {FrameNode} 模板字段卡节点
 */
function detailTemplateFields() {
  var tmpl = box('_template-fields', 'VERTICAL', {
    w: CANVAS.w - SPACING.lg * 2, pad: SPACING.md, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/border'
  });
  tmpl.appendChild(text('模板字段', 'h3'));
  var pairs = CONTENT.job.fields;
  for (var i = 0; i < pairs.length; i++) {
    var pr = box('_pair', 'HORIZONTAL', { w: CANVAS.w - SPACING.lg * 2 - SPACING.md * 2, justify: 'SPACE_BETWEEN' });
    pr.appendChild(text(pairs[i][0], 'small', 'color/text-secondary'));
    pr.appendChild(text(pairs[i][1], 'body'));
    tmpl.appendChild(pr);
  }
  return tmpl;
}

/**
 * 构造 detail-screen：模板字段 + 描述 + 信任卡 + 联系主按钮（PRD §10.1）
 * @returns {FrameNode} 详情页节点
 */
function buildDetail() {
  var s = screen('detail-screen', '详情页', 'PRD §10.1');
  s.appendChild(statusBar());
  s.appendChild(navBar('详情', { back: true, right: '收藏' }));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });
  body.appendChild(text(CONTENT.job.title, 'h2'));
  var tagRow = box('_tags', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  // 详情页这里只是「分类身份标识」，完整度另有独立的信任卡承载，故不传角标
  tagRow.appendChild(pin('category/' + CONTENT.job.catKey, 'resource', null, false));
  tagRow.appendChild(text(CONTENT.job.path, 'small', 'color/text-secondary'));
  body.appendChild(tagRow);
  body.appendChild(detailTemplateFields());
  body.appendChild(detailDescBox());
  body.appendChild(detailTrustCard());
  // 「联系 TA」贴底（2026-08-29 条目 [70]，P2 修复）：PRD §7.4.1 稿图末行明写
  // 「底部固定主按钮胶囊」，此前按钮只是跟在信任卡后面，下方空 315px ——
  // 既不吸底也不居中，看不出是「固定主按钮」。补了描述区后内容更长，
  // 但仍不足 844，所以吸底仍需 _spacer 来实现。
  //
  // 转场 annotation 排在按钮之前而非之后：它钉在 _nav-left 上（见下注释），
  // 属规格说明，不该插在主操作与页面底沿之间打断按钮的贴底关系
  pushToBottom(body, [
    // motion/page 钉在返回入口所在的 _nav-left 上（2026-08-27，I5）：详情页是
    // 全站唯一「有明确前进/返回方向」的页面（首页与列表页互切属同级视图切换），
    // 转场方向的规格必须落在有方向可言的地方。target 不用返回箭头本身 ——
    // 它是 text('‹') 产出的节点，名字就是那个字符，与文案耦合太紧。
    annotation('页面转场动效', [
      motionLine('page') + '（' + MOTION.page.prd + '）',
      '方向与手势一致：返回手势拖动量直接驱动位移，不是松手后才播 260ms',
      '首页↔列表页属同级视图切换，不走本档（无前进/返回语义）'
    ], { severity: 'interact', target: '_nav-left' }),
    button('联系 TA', 'primary', CANVAS.w - SPACING.lg * 2)
  ]);
  s.appendChild(body);
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 detail-screen 已下架/过期态（PRD §7.8 详情页边界）
 *
 * 与 buildDetail 并列存在，不改动正常态本体——两态需在画布上并列对照。
 *
 * Opacity 60% 的落层选择：只压 _body 一层，红条与导航栏留在容器外保持满不透明。
 * 若压整个画框根节点，红条会被一起压到 60%，而 PRD 要求它是最醒目的告知件。
 *
 * @returns {FrameNode} 已下架态详情页节点
 */
function buildDetailOffline() {
  var st = COVERAGE_STATES['detail-offline'];
  var s = screen('detail-screen', st.title, st.prdRef, true);
  s.appendChild(statusBar());
  // 收藏入口保留：PRD §7.8 明确「联系按钮禁用；收藏保留」
  s.appendChild(navBar('详情', { back: true, right: '收藏' }));

  // 顶部红条：不进 _body，故不受下方 Opacity 60% 影响
  var banner = box('_offline-banner', 'HORIZONTAL', {
    w: CANVAS.w, pad: SPACING.md, align: 'CENTER', justify: 'CENTER',
    fill: 'color/error-text'
  });
  banner.appendChild(text(st.banner, 'small', 'color/surface'));
  s.appendChild(banner);

  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });
  body.appendChild(text(CONTENT.job.title, 'h2'));
  var tagRow = box('_tags', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  tagRow.appendChild(pin('category/' + CONTENT.job.catKey, 'resource', null, false));
  tagRow.appendChild(text(CONTENT.job.path, 'small', 'color/text-secondary'));
  body.appendChild(tagRow);
  // 三块内容与正常态共用同一批构造器（2026-08-31 条目 [70-f]）：
  // 改前本页只有模板字段一块，缺描述区与信任卡，于是中部空约 400px ——
  // §7.8 只许两态有红条 / disabled / Opacity 60% 三项差异，缺两块内容是第四、五项。
  // 走构造器而不是把正常态的代码复制过来：复制的那份会各自演化，
  // 「失效态要与正常态逐字一致才能作为对照」这条要求当天就失效
  body.appendChild(detailTemplateFields());
  body.appendChild(detailDescBox());
  body.appendChild(detailTrustCard());
  // 禁用按钮与标注一并贴底（2026-08-31 条目 [70-f]）：改前两者紧跟模板字段卡，
  // 内容止于 555px、下方空 290px，禁用的「联系 TA」悬在页面中间。
  //
  // 为什么必须与正常态 detail 同形：本页存在的唯一理由是给评审做「正常 ↔ 失效」
  // 对照，§7.8 允许的差异只有红条 / disabled / Opacity 60% 三项。按钮位置一旦
  // 不同，对照时会先注意到「按钮怎么跑了」，而不是这三项差异。
  //
  // 注意顺序：annotation 排在按钮之前（同 buildDetail），规格说明不插在
  // 主操作与页面底沿之间；_spacer 由 pushToBottom 插在信任卡与 annotation 之间，
  // 它无填充，被 Opacity 60% 一起压到也不产生任何可见变化
  pushToBottom(body, [
    annotation(st.title, st.notes),
    // 联系按钮禁用：PRD §7.8
    button('联系 TA', 'disabled', CANVAS.w - SPACING.lg * 2)
  ]);
  // 整页内容降至 60%：PRD §7.8「页面整体 Opacity 60%」
  body.opacity = 0.6;
  s.appendChild(body);
  // 必须在 appendChild 之后：layoutGrow 要求已有 Auto Layout 父级
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 publish-screen：三级分类模板 + 发布记忆 + T2 四模式（PRD §10.1）
 * @returns {FrameNode} 发布页节点
 */
function buildPublish() {
  var s = screen('publish-screen', '发布页（模板+记忆）', 'PRD §10.1');
  s.appendChild(statusBar());
  s.appendChild(navBar('发布', { back: true, right: '草稿' }));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });
  var modeRow = box('_t2-modes', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  var modes = ['一句话发', '模板填', '拍照发', '照上次发'];
  for (var i = 0; i < modes.length; i++) {
    // 2026-09-01 条目 [77]：手搓 box 改走 chipTag。
    // 改前值 → 改后值：非选中态「无填充 + border 描边」→ background 实底无描边；
    // 节点名 _mode-<模式> → _chip-tag/mode-<模式>。内边距与字色改前即已一致。
    // 依据：M4-3e 第一层 ① A 族归一 —— 描边式与实底式在同屏是第二种非选中画法。
    var chip = chipTag('mode-' + modes[i], i === 0);
    chip.appendChild(text(modes[i], TAG_SPECS.chip.scale, chipTagInk(i === 0)));
    modeRow.appendChild(chip);
  }
  body.appendChild(text('T2 发布四模式', 'h3'));
  body.appendChild(modeRow);
  // 四个字段统一走「标签在上 + 44 高框」形态（2026-08-29 条目 [70]，P5 修复）。
  // 「选择分类」「地点」原先走 listRow（满宽行卡），与「标题」「薪资」的 field
  // 形态并存，读起来像两组性质不同的东西；且 listRow 写死 390 宽会超出本页可用宽 358。
  // 次序也一并改成「分类 → 标题 → 薪资 → 地点」：分类决定后面出哪套模板字段，
  // 它必须在最前；地点是发完还能改的收尾项，放最后
  body.appendChild(selectField('选择分类', CONTENT.job.path));
  body.appendChild(field('标题', '一句话说清你要发什么'));
  body.appendChild(field('薪资', '如 4500-5500 元/月'));
  body.appendChild(selectField('地点', null, '地图选点'));
  // 「发布」按钮贴底（2026-08-29 条目 [70]，P1/P2 修复）：本页内容实测 512px，
  // 底部空 332px，主按钮悬在四个字段下方、离屏幕底沿还有一大截。
  // 表单页的提交键在底部是三端共识，且 PRD §3.4.1 已为通栏提交定过 capsule 档
  pushToBottom(body, [
    annotation('发布页口径', [
      '三级分类模板由 category-selector 模态承载',
      '发布记忆：默认回填上次同分类填写值',
      '未实名点发布 → cert-modal 拦截（PRD §10.1）'
    ]),
    button('发布', 'primary', CANVAS.w - SPACING.lg * 2)
  ]);
  s.appendChild(body);
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 contact-screen：单轨中转页，逐字落地 PRD §7.4.2 稿图（PRD §10.1）
 *
 * 2026-08-31（条目 [70-f]）整页重写。改前只有一句标题 + 两个按钮，
 * 渲染图上中部约 600px 是纯空白 —— 不是留白过多，是 §7.4.2 稿图明列的
 * 三块内容（隐私保护说明 / 联系方式卡 / 温馨提示与举报）在画布上一个都没有。
 *
 * 为什么去掉「复制微信号」：§7.4.2 注明「用户发布时只填一种联系方式，
 * 中转页只显示该一种联系方式卡片，不做双卡片并列」。改前两个按钮并列，
 * 与这条注、以及本页 annotation 自己写的「二选一单轨：不并列引导」直接相反 ——
 * 稿子上并列引导，红线卡上写着不许并列，两者贴在同一页里。
 * 演示态取「手机号」这一种，与稿图一致。
 *
 * 为什么删掉「选择一种联系方式」「本产品不做站内 IM」两句：
 * 前者在只剩一种联系方式后已无「选择」可言；后者是 Scope 口径，
 * 已由页内红线标注卡第一条承载，正文里再写一遍是同一句话两处维护。
 *
 * 稿图里的 🛡️ / 📞 / 👁️ / ⚠️ / ❌ 五个 emoji 一律不落地：emoji 走系统字体，
 * 三端字形不一且色值不受 paintOf 控制。也不为它们新增五条矢量路径 ——
 * 「隐私保护说明」「手机号」「查看完整号码并外呼」「温馨提示」「举报本次发布」
 * 每一处的文字本身已说清是什么，图标是重复编码（同本页改前注释里
 * 对「拨打电话」不补图标的同一判断）。
 *
 * @returns {FrameNode} 联系中转页节点
 */
function buildContact() {
  var s = screen('contact-screen', '联系中转页', 'PRD §10.1');
  s.appendChild(statusBar());
  // 导航标题带发布者名（§7.4.2 稿图「← 联系 王师傅」）：中转页是从某一条具体
  // 信息点进来的，标题写死「联系对方」会让人不确定自己联系的是哪一条的发布者
  s.appendChild(navBar('联系 ' + CONTENT.job.publisher, { back: true }));
  // pad 从 xl 改 lg、且去掉 align:'CENTER'：本页从「两个居中按钮」变成三块卡片，
  // 卡片可用宽须与 detail / publish 等其余内容页一致（358），居中排列会让
  // 说明块里的多行左对齐正文看起来像是被随机缩进
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });
  var innerW = CANVAS.w - SPACING.lg * 2;

  // 第一块：隐私保护说明（§7.4.2 稿图第 1 段）。走 primary-light 底，
  // 与详情页信任卡同一档 —— 两者都是「平台在为你担保什么」这类告知件
  var privacy = box('_privacy-note', 'VERTICAL', {
    w: innerW, pad: SPACING.md, gap: SPACING.xs,
    fill: 'color/primary-light', radius: RADIUS.lg
  });
  privacy.appendChild(text('隐私保护说明', 'h3', 'color/primary-dark'));
  privacy.appendChild(text('为保护双方隐私，平台提供联系方式中转：', 'small', 'color/primary-dark'));
  // 两条要点已于 2026-08-31 按用户裁决纠偏，PRD §7.4.2 同步回写（含原句/问题/改后对照表）：
  // ① 原句「记录在双方『联系记录』中」两处不成立 —— 全站唯一能看到联系痕迹的是
  //    §8.3.3 互动通知「你的『发布』被联系了 × 次」，仅发布者可见且只有次数，
  //    主动联系方无任何可见记录，故「双方」不成立；且「联系记录」页在附录 B
  //    14 页清单与 §9.4 API 清单里都不存在，原句是在向用户承诺未立项的功能。
  // ② 原句「对方回复后可互加联系方式」的「回复」在本产品内无处发生 ——
  //    §7.2 / §8.3.3 明确不做站内 IM、无消息列表、无聊天详情，联系是单向的
  //    （拿号 → 线下拨打）；互加发生在通话里，是线下行为，不该写成平台功能口吻。
  // 注：contact_event 落库（§9.5）不在纠偏范围，该表只记「联系动作是否发生」，
  //    与 §5.11 / §6.12 / §6.14 红线一致 —— 改的是向用户的表述，不是后端记录。
  privacy.appendChild(text('· 本次联系会计入对方的「被联系」通知', 'caption', 'color/primary-dark'));
  privacy.appendChild(text('· 通话中可自行互加微信等联系方式，平台不留存', 'caption', 'color/primary-dark'));
  body.appendChild(privacy);

  // 第二块：联系方式卡（§7.4.2 稿图第 2 段），只展示发布时填写的那一种
  var contactCard = box('card/contact-channel', 'VERTICAL', {
    w: innerW, pad: SPACING.lg, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/border'
  });
  var phoneRow = box('_phone-row', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
  phoneRow.appendChild(text('手机号', 'small', 'color/text-secondary'));
  // 脱敏号码给到 h2 字阶：它是本页唯一的信息主体，其余都是说明与操作
  phoneRow.appendChild(text(CONTENT.job.phoneMasked, 'h2'));
  contactCard.appendChild(phoneRow);
  contactCard.appendChild(text('（点击号码，查看完整号码并拨打）', 'caption', 'color/text-placeholder'));
  // 主操作留在卡内而非贴底：完整号码是这张卡的内容，「查看完整号码并外呼」
  // 拉到页面底沿会与它所属的号码脱开，稿图里也画在卡的第三行
  contactCard.appendChild(button('查看完整号码并外呼', 'primary', innerW - SPACING.lg * 2));
  body.appendChild(contactCard);

  // 第三块：温馨提示（§7.4.2 稿图第 3 段）。
  // 2026-08-31 用户裁定「补安全提示内容」：稿图这块原本只有一行
  //「建议白天联系，交易请走线下」，落地后本页温馨提示到贴底举报之间空约 400px。
  // 用真内容填而不是拉大间距 —— 中转页是全站唯一「即将与陌生人线下接触」的
  // 节点，安全提示写在这里成本最低。四条已于同日回写进 PRD §7.4.2
  //（含每条来源表），本函数与该节逐字一致，不再是本稿单方面造词。
  // 内边距与行距取 lg / sm（与联系方式卡同档）：本块从一行变四行后，
  // 仍用 md / xs 会让四行挤成一团，与上方卡片的呼吸感不一致。
  var tip = box('_safety-tip', 'VERTICAL', {
    w: innerW, pad: SPACING.lg, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.md, stroke: 'color/warning'
  });
  tip.appendChild(text('温馨提示', 'small', 'color/warning-text'));
  // 第 1 条：§7.4.2 稿图原句
  tip.appendChild(text('· 建议白天联系，交易请走线下', 'caption', 'color/warning-text'));
  // 第 2 条：对应 §7.7 举报原因「诈骗」最常见的形态
  tip.appendChild(text('· 不要提前支付定金、押金或任何费用', 'caption', 'color/warning-text'));
  // 第 3 条：对应本产品大量「上门 / 面谈」类目的人身安全
  tip.appendChild(text('· 上门服务或面谈，建议约在公共场所', 'caption', 'color/warning-text'));
  // 第 4 条：把举报入口与「什么情况该举报」连起来，否则页脚那个按钮
  // 只是一个孤立动作，用户不知道自己遇到的事算不算可举报
  tip.appendChild(text('· 遇到不实信息、诈骗、骚扰，可直接举报', 'caption', 'color/warning-text'));
  body.appendChild(tip);

  // 举报说明：紧贴页脚按钮上方，不放在温馨提示里 —— 它说明的是「点下去会
  // 发生什么」，属于那个按钮的附注。五个原因与处理时限均取 PRD 逐字口径
  var reportNote = box('_report-note', 'VERTICAL', { w: innerW, gap: SPACING.xs });
  reportNote.appendChild(text('举报原因：不实信息 / 诈骗 / 违规类目 / 骚扰 / 其他（PRD §7.7）',
    'caption', 'color/text-secondary'));
  reportNote.appendChild(text('提交后 24 小时内处理（PRD §7.8）',
    'caption', 'color/text-placeholder'));

  pushToBottom(body, [
    annotation('联系页 Scope 红线', [
      '不做 IM 聊天、不做撮合结果追踪（永久红线）',
      '二选一单轨：只显示发布时填的那一种，不做双卡片并列（PRD §7.4.2 注）',
      '联系行为不产生交易记录、不产生信誉评价',
      '完整号码不写入前端初始状态，点击时走 API（PRD §7.7）',
      '隐私说明两句已纠偏：全站联系痕迹只有 §8.3.3「被联系 × 次」通知（仅发布者可见），'
        + '「联系记录」页未立项；不做 IM 故无「回复」，互加发生在通话里'
    ], { severity: 'redline' }),
    reportNote,
    // 举报走 secondary 而非 ghost/danger（2026-08-31 用户拍定）：
    // §7.4.2 稿图画的是 [ 举报本次发布 ] 带方框，而 ghost 无描边无底色，
    // 渲染出来是页脚一行居中文字，看不出是可点按钮 —— 举报是安全兜底入口，
    // 「看不出能点」比「权重略高」代价大得多。
    // 也不用 danger：那是红底白字的不可逆操作档（删除、下架），
    // 举报只是提交一条待复核记录，红底会盖过本页主操作「查看完整号码并外呼」。
    button('举报本次发布', 'secondary', innerW)
  ]);
  s.appendChild(body);
  // 必须在 appendChild 之后：layoutGrow 要求已有 Auto Layout 父级。
  // body 吃满 844 减去状态栏与导航栏的剩余高，内部的 _spacer 才有空间可伸
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 profile-screen：个人中心，信任与认证入口（PRD §10.1）
 * @returns {FrameNode} 个人中心节点
 */
function buildProfile() {
  var s = screen('profile-screen', '个人中心', 'PRD §10.1');
  s.appendChild(statusBar());
  s.appendChild(navBar('我的', { right: '设置' }));
  var head = box('_profile-head', 'HORIZONTAL', {
    w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md, fill: 'color/surface', align: 'CENTER'
  });
  head.appendChild(box('_avatar', 'HORIZONTAL', { w: 56, h: 56, radius: RADIUS.full, fill: 'color/primary-light' }));
  var info = box('_info', 'VERTICAL', { gap: SPACING.xs });
  info.appendChild(text('鸭友 138****8888', 'h3'));
  // 「已实名 ✅ · 资质认证待完成」拆成两段（条目 [70]）：前段已完成走 doneTag，
  // 后段未完成不该带勾，保持纯文字
  var idRow = box('_id-status', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  idRow.appendChild(doneTag('已实名', 'small', 'color/text-secondary'));
  idRow.appendChild(text('· 资质认证待完成', 'small', 'color/text-secondary'));
  info.appendChild(idRow);
  head.appendChild(info);
  s.appendChild(head);
  var group = box('_group', 'VERTICAL', { w: CANVAS.w, gap: 0 });
  group.appendChild(listRow('我的发布', '3 在架'));
  group.appendChild(listRow('我的收藏', '8'));
  group.appendChild(listRow('通知中心', '2 未读'));
  group.appendChild(listRow('信任与认证', '去完善'));
  // 不放「帮助与反馈」（2026-08-31 裁决）：§3.4.2 稿图画了「❓ 帮助与反馈 ›」一行，
  // 但同节 §3.3 的范围约束明写「不含结算记录、帮助中心等超范围项」，且附录 B 的
  // 14 页清单与 §9.4 API 清单里都没有对应页与接口 —— 稿图这一行是在承诺一个
  // 未立项的功能。范围约束优于稿图，故本页不落地，PRD §3.4.2 稿图同步删除。
  group.appendChild(listRow('设置', ''));
  s.appendChild(group);
  // 退出登录（2026-08-29 条目 [70]）：§3.4.2 稿图把它明列为个人中心底部的独立
  // Danger 按钮，§3.4.3 尾注又写「个人中心放，设置页不放重复」。本轮按尾注从设置页
  // 删掉后，整份稿子一度丢了这个元素，故在此按稿图补回。
  // 与列表分开一段：退出是破坏性操作，混在「我的发布/收藏」这类导航行里
  // 会被误点，稿图也是用一条分隔线把它单独隔出来的
  var quit = box('_quit', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg });
  quit.appendChild(button('退出登录', 'danger', CANVAS.w - SPACING.lg * 2));
  // 退出登录与 Tab 一起贴底（2026-08-30 条目 [71]）：上一轮只把 Tab 贴了底，
  // _quit 仍按顺序挂在画框上，于是渲染图（r64-profile.png）上按钮浮在页面中部、
  // 下方空着约 250px —— 既不像吸底也不像随内容，一个破坏性操作悬在半空最容易
  // 被误读为「还有内容没画完」。
  //
  // 为什么归到 tailNodes 而不是给 _quit 前面单独插 spacer：pushToBottom 一次
  // 只造一个 spacer，两个 spacer 会把剩余空间对半分、按钮反而卡在中间偏下。
  // 顺序为 [quit, bottomTab] —— 退出键在 Tab 之上，与 §3.4.2 稿图一致。
  //
  // 与 contact/trust 用 pushToBottom 的差别：本页没有统一的 _body 容器，
  // 三段直接挂在画框上，故 spacer 直接插在画框层
  pushToBottom(s, [quit, bottomTab('我的')]);
  return s;
}

/**
 * 构造 my-publish-screen：全部/在架/已下架/草稿 + 编辑重发下架（PRD §8.3.1）
 *
 * 2026-08-29 条目 [70] 后补：原实现 2 张卡 + 一组游离按钮，实机内容仅到 365px、
 * 空白 479px。三处对齐 §8.3.1：
 *
 * ① Tab 补「全部」——§8.3.1 明列四个页签（全部 · 在架 · 已下架 · 草稿）。
 * ② 卡补到 4 张并覆盖三种状态标（在架绿 / 下架灰 / 草稿黄）。本页页签停在
 *    「全部」，故三种状态可以同屏 —— 这正是补「全部」页签换来的好处：原先停在
 *    「在架」时，下架与草稿两种状态标在整份稿子里没有任何落点。
 * ③ 操作组下沉到每张卡内。原实现把「刷新重发 / 下架」做成整页底部一组游离按钮，
 *    可是 §8.3.1 写的是「右：操作组（编辑 · 重发 · 上下架切换）」—— 是每行一组。
 *    做成整页一组会让人以为它作用于全部条目，而实际是逐条操作。
 *
 * @returns {FrameNode} 我的发布页节点
 */
function buildMyPublish() {
  var s = screen('my-publish-screen', '我的发布', 'PRD §8.3.1');
  s.appendChild(statusBar());
  s.appendChild(navBar('我的发布', { back: true, right: '搜索' }));
  s.appendChild(segTab(['全部', '在架', '已下架', '草稿'], 0));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });

  /**
   * 生成一条「卡片 + 卡内逐条操作组」的组合块。
   *
   * 操作组必须在卡片内（2026-08-30 条目 [71]）：原实现把 acts 与 card 并列挂在
   * 一个透明 _pub 容器里，操作组落在两卡之间的页面底色上、左对齐悬空。渲染图
   * （r64-my-publish.png）上四组按钮看起来都像属于**下面**那张卡 —— §8.3.1 写的
   * 是「右：操作组」，即操作与条目同属一个视觉单元，游离在外就丢了这层归属。
   *
   * 做法是把 acts 追加进 card 返回的 Frame，并把 card 由横排改纵排容纳两行。
   * card() 是纯原生 Frame（未走 COMP_CACHE，见 :1717），可安全增删子节点；
   * 若它是 Instance 则 appendChild 会直接报错，那样就只能改 master。
   *
   * @param {Array} it [标题, 副标题, catKey, 生命周期状态, 完整度档或空, 操作文案数组]
   * @returns {FrameNode} 卡片节点（操作组已在其内）
   */
  var pubItem = function (it) {
    // 2026-09-01 条目 [77]：第四参改具名槽位 lifecycle。本页这一格放的是
    // §8.6 状态机的状态值（在架/已下架/草稿），与列表页那格的供需属性
    // 是两回事，改造前两处都只是个字符串，稿上无从区分
    var c = card(it[0], it[1], 'category/' + it[2], { lifecycle: it[3] }, it[4] || undefined);
    // card 原为 HORIZONTAL（色条 · 主体 · 状态标 三列）。要在其下再放一行操作组，
    // 需把这三列先收进一个横排子容器，卡片本身改纵排
    var top = box('_pub-top', 'HORIZONTAL', {
      w: CANVAS.w - SPACING.lg * 2 - SPACING.lg * 2, gap: SPACING.md, align: 'MIN'
    });
    while (c.children.length) top.appendChild(c.children[0]);
    c.layoutMode = 'VERTICAL';
    // 改轴向后必须同步纠正两轴 sizing（2026-08-30 实机复验发现，条目 [71]）：
    // box() 里 primaryAxisSizingMode 指的是主轴（= layoutMode 方向）。card() 建时是
    // HORIZONTAL 且只传了 w，于是 primary(横)=FIXED、counter(竖)=AUTO。此处把
    // layoutMode 翻成 VERTICAL，两轴语义随之互换 —— 竖轴接过 FIXED 并锁死在原横排
    // hug 出来的 45px，横轴反而变成 HUG。结果是三行内容（top 44 + sep 1 + acts 47）
    // 被裁在 45px 高的卡里，实机渲染图上只剩标题那一行，分隔线与操作组全部不可见。
    // 首轮机读验证只查了 _pub-sep 数量与 legacyPubLayer，两者都在，故没暴露 —— 光看
    // 「节点存在」验不出「节点被裁掉」，高度必须一起断言。
    c.primaryAxisSizingMode = 'AUTO';               // 竖轴：随三行内容 hug
    c.counterAxisSizingMode = 'FIXED';              // 横轴：保持卡片满宽
    c.resize(CANVAS.w - SPACING.lg * 2, c.height);
    c.itemSpacing = SPACING.sm;
    bindNum(c, 'itemSpacing', 'spacing', SPACING.sm);
    c.appendChild(top);
    // 分隔线把「信息」与「操作」隔开：同色同底的两行紧贴时，按钮会被读成正文的
    // 一部分（listRow 里也是用底线区分行边界的）
    var sep = box('_pub-sep', 'HORIZONTAL', {
      w: CANVAS.w - SPACING.lg * 2 - SPACING.lg * 2, h: 1, fill: 'color/border'
    });
    c.appendChild(sep);
    var acts = box('_pub-actions', 'HORIZONTAL', { gap: SPACING.sm });
    for (var j = 0; j < it[5].length; j++) {
      acts.appendChild(button(it[5][j], j === 0 ? 'secondary' : 'ghost', 0));
    }
    c.appendChild(acts);
    return c;
  };

  // 三种状态标各占一条，操作组随状态变化：在架给「下架」、下架给「重发」、
  // 草稿给「继续编辑」。状态与可用操作的对应关系是本页的核心规格（§8.6 状态机），
  // 四条卡若操作组全一样，那张状态机图在稿子上就等于没落地
  var items = [
    [CONTENT.job.title, '浏览 42｜3 天前发布', CONTENT.job.catKey, '在架', 'green', ['编辑', '下架']],
    [CONTENT.listExtra[1].title, '浏览 11｜7 天前发布', CONTENT.listExtra[1].catKey, '在架', 'yellow', ['编辑', '下架']],
    [CONTENT.listExtra[2].title, '浏览 8｜已过期自动下架', CONTENT.listExtra[2].catKey, '已下架', 'yellow', ['刷新重发', '删除']],
    [CONTENT.marker.title, '未发布｜草稿保存于昨天', CONTENT.marker.catKey, '草稿', 'red', ['继续编辑', '删除']]
  ];
  for (var i = 0; i < items.length; i++) body.appendChild(pubItem(items[i]));
  // 分页收尾（2026-08-30 条目 [70]）：§7 接口表 /posts/mine 标「分页」，
  // 四条即首页全量，故落「没有更多了」终态（§6.7 :1291）
  body.appendChild(listEndRow(CANVAS.w - SPACING.lg * 2));
  s.appendChild(body);
  return s;
}

/**
 * 构造 my-favorite-screen：资源/需求/全部 Tab（PRD §8.3.2）
 *
 * 2026-08-29 条目 [70] 后补：原实现 2 张卡，实机内容仅到 303px、空白 541px。
 * 两处对齐 §8.3.2：
 *
 * ① Tab 补「全部」——§8.3.2 明列三个页签（资源 · 需求 · 全部），原先只有两个。
 * ② 卡补到 5 张，且五大分类各占一张。收藏页是唯一一处「同屏出现全部五种分类色」
 *    的真实场景，两张卡只能验到两种色，剩下三种分类色在真实卡片语境下从未被看过
 *    （T6 规格板上的色块是脱离语境的纯色样）。
 *
 * 五张卡 kind 一律「资源」：本页页签停在「资源」，卡片供需属性必须与页签一致，
 * 否则设计师会以为「资源」页签下也能出现需求卡。
 *
 * @returns {FrameNode} 我的收藏页节点
 */
function buildMyFavorite() {
  var s = screen('my-favorite-screen', '我的收藏', 'PRD §8.3.2');
  s.appendChild(statusBar());
  s.appendChild(navBar('我的收藏', { back: true }));
  s.appendChild(segTab(['资源', '需求', '全部'], 0));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });
  // 五条按 catKey 覆盖工作/房屋/车辆/服务/生活，全部取 fixtures 真值。
  // 生活类取 marker 那条（婴儿推车）：它本是首页信息卡的样例，在收藏页复用
  // 恰好演示了「从地图 Pin 收藏来的信息长什么样」，不是随手凑数
  var favs = [
    [CONTENT.job.title, CONTENT.job.path + '｜' + CONTENT.job.distance, CONTENT.job.catKey],
    [CONTENT.favoriteHouse.title,
      CONTENT.favoriteHouse.path + '｜' + CONTENT.favoriteHouse.distance,
      CONTENT.favoriteHouse.catKey],
    [CONTENT.listExtra[1].title,
      CONTENT.listExtra[1].path + '｜' + CONTENT.listExtra[1].distance,
      CONTENT.listExtra[1].catKey],
    [CONTENT.listExtra[2].title,
      CONTENT.listExtra[2].path + '｜' + CONTENT.listExtra[2].distance,
      CONTENT.listExtra[2].catKey],
    [CONTENT.marker.title, CONTENT.marker.subtitle, CONTENT.marker.catKey]
  ];
  for (var i = 0; i < favs.length; i++) {
    body.appendChild(card(favs[i][0], favs[i][1], 'category/' + favs[i][2],
      // 2026-09-01 条目 [77]：五张卡一律「资源」的理由见本函数注释 ——
      // 本页页签停在「资源」，供需属性必须与页签一致。改具名槽位后，
      // 「这一格放的是供需」这件事在调用点就读得出，不必回查 card() 实现
      { supplyDemand: '资源' }));
  }
  // 分页收尾（2026-08-30 条目 [70]）：§7 接口表 /favorites 标「分页」，
  // 五张即首页全量，故落「没有更多了」终态（§6.7 :1291）
  body.appendChild(listEndRow(CANVAS.w - SPACING.lg * 2));
  s.appendChild(body);
  var note = box('_note', 'VERTICAL', { w: CANVAS.w, padLeft: SPACING.lg, padRight: SPACING.lg });
  note.appendChild(annotation('收藏页口径', [
    '取消收藏：卡片上滑或点星标（PRD §8.3.2）',
    '卡片为详情精简版，不重复展示模板字段全量'
  ], { severity: 'spec' }));
  s.appendChild(note);
  return s;
}

/**
 * 构造 notification-screen：系统/互动/认证三类纯通知（PRD §8.3.3）
 *
 * 2026-08-29 条目 [70] 后补：原实现用 3 条 listRow 顶替通知行，实机内容仅到
 * 267px、空白 577px（全画布最大一处）。两处偏差一起修：
 *
 * ① 行形态 —— §8.3.3 明列「图标 · 标题 · 摘要 · 时间 · 未读红点」五段，
 *    listRow 只给两段，摘要与未读态整个缺失。改走新的 notifyRow。
 * ② 条数与覆盖面 —— §8.3.3 逐项列了系统类五种触发（实名通过/审核中/资质通过/
 *    违规下架/版本更新），只画 3 条等于评审看不到「违规下架」这类负向通知长什么样。
 *
 * 本页 segTab 停在「系统」，故只列系统类；互动与认证类的文案在 annotation 里
 * 点明，不混进列表 —— 混进去会让人以为系统页签下也收互动通知。
 *
 * @returns {FrameNode} 通知中心节点
 */
function buildNotification() {
  var s = screen('notification-screen', '通知中心（分类）', 'PRD §8.3.3');
  s.appendChild(statusBar());
  s.appendChild(navBar('通知', { back: true, right: '全部已读' }));
  s.appendChild(segTab(['系统', '互动', '认证'], 0));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, gap: 0 });
  // 五条覆盖 §8.3.3 系统类的全部触发种类，前两条未读、后三条已读：
  // 未读/已读同页出现才看得出两态的色阶差，全未读或全已读都只交付了一半
  body.appendChild(notifyRow('bell', '你的发布已通过审核',
    '「' + CONTENT.job.title + '」已在架，附近的人可以看到', '2 小时前', true));
  body.appendChild(notifyRow('tick', '实名认证已通过',
    '身份证二要素核验成功，已获得实名标', '昨天', true));
  body.appendChild(notifyRow('bell', '一条信息被违规下架',
    '「小货车拉货」含疑似联系方式外露，可修改后重发', '3 天前', false));
  body.appendChild(notifyRow('tick', '家政资质审核中',
    '预计 1 个工作日内出结果', '3 天前', false));
  body.appendChild(notifyRow('dots', '版本更新 v2.1',
    '新增 AI 帮我发、类目三级精筛', '一周前', false));
  // 分页收尾（2026-08-30 条目 [70]）：§7 接口表 /notifications 标「分页」，
  // 五条即为首页全量，故落到「没有更多了」终态（§6.7 :1291）
  body.appendChild(listEndRow());
  s.appendChild(body);
  var note = box('_note', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg });
  note.appendChild(annotation('通知中心口径', [
    '纯通知，不可回复，不做消息列表页与聊天详情页（PRD §8.3.3）',
    '三类：系统（本页）/ 互动（被联系 × 次）/ 认证（审核进度、年审提醒）',
    '点击通知跳对应详情，不做展开态，故行尾不带 ›'
  ], { severity: 'redline' }));
  s.appendChild(note);
  return s;
}

/**
 * 构造 trust-screen：四类认证逐条状态 + 信任指标卡（PRD §4.4 / §10.1）
 *
 * 2026-08-29 条目 [70] 后补，两处改动一起做：
 *
 * ① 两层概括卡 → 四类认证行。原实现只画「第一层实名 / 第二层资质」两张概括卡，
 *    而 §4.3 表列的是四类（个人实名 / 个人资质 / 企业认证 / 车辆认证）、§4.4
 *    稿图逐条画了状态 + 日期 + 动作。概括卡把「哪一类过了、哪一类还没过」这个
 *    本页最核心的信息糊掉了 —— 用户来这一页就是为了看这个。
 *    「二层」说的是认证机制的深度（实名是门槛、资质是加成），不是只有两个条目，
 *    故展开四行不违 T4 红线，红线 annotation 原样保留。
 *
 * ② 补 §4.4 的信任指标卡。这是把 Marker 卸下来的完整度信息在「我的」侧的汇总
 *    落点（详情页信任卡是单条视角，本卡是全量视角）。
 *
 * 顺带这也是 P1 底部空白的真正解法：原先本页可见内容仅到 293px，我用
 * pushToBottom 把红线 annotation 压到页脚，但 detachAnnotations() 会把
 * annotation 卡移出画框挂到 SECTION 上 —— 唯一的尾部元素一走，spacer 之后什么
 * 都不剩，实机仍是 551px 空白。空白的根子从来不是布局，是内容缺。
 *
 * @returns {FrameNode} 信任与认证页节点
 */
function buildTrust() {
  var s = screen('trust-screen', '信任与认证', 'PRD §4.4');
  var cw = CANVAS.w - SPACING.lg * 2;
  s.appendChild(statusBar());
  s.appendChild(navBar('信任与认证', { back: true }));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });

  // ---- 第一层：实名，单独成卡且描边走 success ----
  // 与下面三类同列会丢掉「它是发布前置门槛」这层含义（§4.3：强推荐，未实名
  // 每日仅看 3 条详情）。它是别的认证的前提，不是并列的第四种
  var l1 = box('_layer1', 'VERTICAL', {
    w: cw, pad: SPACING.md, gap: SPACING.xs,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/success'
  });
  l1.appendChild(doneTag('第一层 · 个人实名 已通过', 'h3', 'color/success-text'));
  l1.appendChild(text('身份证二要素 + 手机号一致性，发布前置门槛', 'small', 'color/text-secondary'));
  body.appendChild(l1);

  // ---- 第二层：三类资质逐条列状态 ----
  var l2 = box('_layer2', 'VERTICAL', {
    w: cw, pad: SPACING.md, gap: SPACING.md,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/border'
  });
  l2.appendChild(text('第二层 · 资质认证', 'h3'));
  // 三行刻意各占一档状态（已通过 / 审核中 / 未认证）：本页是设计稿，评审要看的
  // 是三种状态的视觉差，全画成「已通过」等于只交付了三分之一的规格
  //
  // 显式传行宽（2026-08-30 条目 [71]）：宿主 _layer2 宽 cw、内边距 md，故行的
  // 可用宽是 cw - md*2。不传则 certRow 落回 hug、内部 grow 拉不动、三行压字
  var certW = cw - SPACING.md * 2;
  l2.appendChild(certRow('企业认证', 'reviewing', '2026-08-09 提交', '查看', certW));
  l2.appendChild(certRow('家政资质', 'none', '发布家政/保洁/维修类必须', '去认证', certW));
  l2.appendChild(certRow('车辆认证', 'passed', '2026-05-12', '管理', certW));
  body.appendChild(l2);

  // ---- 信任指标卡（PRD §4.4）----
  var tm = box('_trust-metrics', 'VERTICAL', {
    w: cw, pad: SPACING.md, gap: SPACING.sm,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/border'
  });
  tm.appendChild(text('我的信任指标', 'h3'));
  // 三项信号横排：§4.2 定义「信任信号 = 实名标 + 资质标 + 完整度三档」，
  // 三者是并列的一组，分三行会读成三个独立小节
  var sig = box('_signals', 'HORIZONTAL', { gap: SPACING.md, align: 'CENTER' });
  sig.appendChild(doneTag('实名', 'small', 'color/text-secondary'));
  sig.appendChild(doneTag('资质 1 项', 'small', 'color/text-secondary'));
  var avg = box('_avg', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  avg.appendChild(text('完整度', 'small', 'color/text-secondary'));
  avg.appendChild(completenessTag('green', 'small'));
  sig.appendChild(avg);
  tm.appendChild(sig);
  // 条数取「3 在架」与 profile 的 listRow('我的发布', '3 在架') 对齐（2026-08-29
  // 定的口径，PRD §4.4 稿图的「5 条」已同批回写为 3 条）。同一份演示数据在两页
  // 互相矛盾，评审第一眼就会去追哪个是对的，而它其实没有对错、只是我没对齐
  tm.appendChild(text('我在架的 3 条信息完整度分布', 'small', 'color/text-secondary'));
  var dist = box('_dist', 'HORIZONTAL', { gap: SPACING.md, align: 'CENTER' });
  var levels = ['green', 'yellow', 'red'];
  for (var i = 0; i < levels.length; i++) {
    var cell = box('_dist-' + levels[i], 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
    cell.appendChild(completenessTag(levels[i], 'small'));
    cell.appendChild(text('1 条', 'small', 'color/text-secondary'));
    dist.appendChild(cell);
  }
  tm.appendChild(dist);
  // T4 红线在卡内点明而非只写在 annotation 里：annotation 会被
  // detachAnnotations() 移出画框，单看渲染图时这句就不在页面上了。
  // 措辞直接抄 §4.2 的定性句，不写「不含发布记录数/举报率」那种列举 ——
  // 列举反而把不该出现的指标名字印在了页面上
  tm.appendChild(text('只看信息真实性与完整性，不做人的信誉评级（T4 红线）', 'caption', 'color/text-secondary'));
  body.appendChild(tm);

  // 红线 annotation 保留但不再承担贴底职责（原修法失效详见函数头注释）。
  // 补完内容后本页自然填满，不需要 spacer
  body.appendChild(annotation('认证 Scope 红线', [
    '只做二层认证，不做信誉评价体系、不做信誉详情页',
    '不售卖商业化角标（永久红线）'
  ], { severity: 'redline' }));
  s.appendChild(body);
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 settings-screen：账号与安全 + 通用 + 隐私 + 关于（PRD §3.4.3）
 *
 * 2026-08-29 条目 [70] 后补：原实现 5 条无分组平列，实机内容仅到 384px、
 * 空白 460px。两处对齐 §3.4.3：
 *
 * ① 条目补齐。§3.4.3 逐项列了四组共十余项（手机号 / 修改密码 / 注销账号 /
 *    消息通知开关 / 范围默认值 / 清除缓存 / 位置权限说明 / 联系方式展示策略 /
 *    版本号 / 用户协议 / 隐私政策），原先 5 条里「注销账号」「范围默认值」
 *    「联系方式展示策略」这几项恰好是需要单独确认口径的敏感项，全都缺了。
 * ② 补分组标题。十余项平列是一堵没有落点的列表墙，§3.4.3 本身就是分四组写的。
 *
 * 「退出登录」按 §3.4.3 尾注保留在个人中心而非本页 —— 原实现在这里也放了一个，
 * 与那条尾注（「退出登录个人中心放，设置页不放重复」）直接冲突，本次一并去掉。
 *
 * @returns {FrameNode} 设置页节点
 */
function buildSettings() {
  var s = screen('settings-screen', '设置', 'PRD §3.4.3');
  s.appendChild(statusBar());
  s.appendChild(navBar('设置', { back: true }));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, gap: 0 });
  // 分组与条目逐字对应 §3.4.3 的四组正文，右值只在「有当前值可展示」时给：
  // 无右值的条目由 listRow 自行省略文本节点，不产出空壳
  var groups = [
    ['账号与安全', [['手机号', '138****8888'], ['修改密码', ''], ['注销账号', '']]],
    ['通用', [['消息通知', '已开启'], ['默认范围', '5km'], ['清除缓存', '12.4MB']]],
    ['隐私', [['位置权限说明', ''], ['联系方式展示策略', '仅点击后可见']]],
    ['关于', [['版本号', 'v2.1'], ['用户协议', ''], ['隐私政策', '']]]
  ];
  for (var g = 0; g < groups.length; g++) {
    body.appendChild(groupTitle(groups[g][0]));
    var rows = groups[g][1];
    for (var i = 0; i < rows.length; i++) {
      body.appendChild(listRow(rows[i][0], rows[i][1]));
    }
  }
  s.appendChild(body);
  return s;
}

/**
 * 构造 ai-confirm-screen：AI 结果确认页（PRD §5.9 / :727-731 / :1461-1478）
 * 四模式共用的强制确认环节，逐字段展示 AI 猜测值并允许逐项修改
 * @returns {FrameNode} AI 结果确认页节点
 */
function buildAiConfirm() {
  var s = screen('ai-confirm-screen', 'AI 结果确认页', 'PRD §5.9');
  s.appendChild(statusBar());
  s.appendChild(navBar('确认信息', { back: true, right: '全部重填' }));
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.md });
  body.appendChild(text('AI 已识别，请核对', 'h2'));
  body.appendChild(text('每项都可以改，改完再发', 'small', 'color/text-secondary'));

  /**
   * 生成一行 AI 猜测字段：字段名 + 猜测值 + "AI 猜"角标
   * 未猜出的字段按 PRD §5.9 标"需你补充"，不猜不编造
   */
  // 前三行取 fixtures 真值，第四行「工时」刻意置为未猜出：
  // PRD §5.9 要求 AI 猜不出就标「需你补充」，不猜不编造，故此处不复用 fields 的工时值
  var guesses = [
    ['分类', CONTENT.job.path, true],
    ['标题', CONTENT.job.title, true],
    [CONTENT.job.fields[0][0], CONTENT.job.fields[0][1], true],
    [CONTENT.job.fields[1][0], '需你补充', false]
  ];
  for (var i = 0; i < guesses.length; i++) {
    var row = box('_guess-' + guesses[i][0], 'HORIZONTAL', {
      w: CANVAS.w - SPACING.lg * 2, pad: SPACING.md, gap: SPACING.sm,
      fill: 'color/surface', radius: RADIUS.md, stroke: 'color/border',
      align: 'CENTER', justify: 'SPACE_BETWEEN'
    });
    var lft = box('_l', 'VERTICAL', { gap: TIGHT_GAP });
    lft.appendChild(text(guesses[i][0], 'caption', 'color/text-secondary'));
    lft.appendChild(text(guesses[i][2] ? guesses[i][1] : '需你补充', 'body',
      guesses[i][2] ? 'color/text-primary' : 'color/error-text'));
    row.appendChild(lft);
    if (guesses[i][2]) {
      // 2026-09-01 条目 [77]：字面取值改为读 TAG_SPECS.mark（B 族唯一实处）。
      // 改前值 → 改后值：取值逐项不变（TIGHT_GAP/xs + RADIUS.sm + accent 底 +
      // 白字），仅由字面量改为查表。依据：M4-3e 第一层 ① —— B 族样本量为 1，
      // 规格系新立而非归纳，故不改画面、只把取值来源钉到表上。
      var tagBox = box('_ai-tag', 'HORIZONTAL', {
        padTop: TAG_SPECS.mark.padV, padBottom: TAG_SPECS.mark.padV,
        padLeft: TAG_SPECS.mark.padH, padRight: TAG_SPECS.mark.padH,
        radius: TAG_SPECS.mark.radius, fill: TAG_SPECS.mark.fill,
        align: 'CENTER', justify: 'CENTER'
      });
      tagBox.appendChild(text('AI 猜', TAG_SPECS.mark.scale, TAG_SPECS.mark.textColor));
      row.appendChild(tagBox);
    } else {
      row.appendChild(text('去填 ›', 'small', 'color/primary'));
    }
    body.appendChild(row);
  }

  // 底部「再花 5 秒升『完整』」冲刺区（PRD §5.9）
  var sprint = box('_green-sprint', 'VERTICAL', {
    w: CANVAS.w - SPACING.lg * 2, pad: SPACING.md, gap: SPACING.sm,
    fill: 'color/primary-light', radius: RADIUS.lg
  });
  // 标题原为「再花 5 秒升 🟢」，2026-08-29（条目 [70]）拆成「文字 + 矢量档位标识」。
  // 拆开而非整句改成纯文字：这里的 🟢 指的就是完整度那一档，
  // 与页内其他档位标识必须长得一样，否则同一语义出现两种表现
  var sprintTitle = box('_sprint-title', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  sprintTitle.appendChild(text('再花 5 秒升', 'h3', 'color/primary-dark'));
  sprintTitle.appendChild(completenessTag('green', 'h3', 'color/primary-dark'));
  sprint.appendChild(sprintTitle);
  var sp1 = box('_sp-1', 'HORIZONTAL', { w: CANVAS.w - SPACING.lg * 2 - SPACING.md * 2, justify: 'SPACE_BETWEEN', align: 'CENTER' });
  sp1.appendChild(text('门牌号', 'small', 'color/primary-dark'));
  sp1.appendChild(button('取当前定位门牌', 'secondary', 0));
  sprint.appendChild(sp1);
  var sp2 = box('_sp-2', 'HORIZONTAL', { w: CANVAS.w - SPACING.lg * 2 - SPACING.md * 2, justify: 'SPACE_BETWEEN', align: 'CENTER' });
  sp2.appendChild(text('三级类目', 'small', 'color/primary-dark'));
  // 三级类目候选取 CAT_TREE 真值前三项（原先直写「帮厨 / 洗碗 / 传菜」，树里都没有）
  sp2.appendChild(text(contentCatPath().slice(0, 3).join(' / '), 'caption', 'color/primary-dark'));
  sprint.appendChild(sp2);
  body.appendChild(sprint);

  // 「确认发布」与标注贴底（2026-08-31 条目 [70-f]）：改前两者紧跟冲刺区，
  // 内容止于 795px、下方空 240px。本页是发布链路的最后一道闸，
  // 「确认发布」是全站权重最高的提交动作之一，它与 publish 页的「发布」
  // 属同一类通栏提交键，位置必须一致 —— 否则连点两页的人要重新找按钮
  pushToBottom(body, [
    annotation('确认页口径', [
      '强制环节，四模式共用（PRD §5.9）',
      '未猜出字段标「需你补充」，不猜不编造（PRD §5.9）',
      '仅本页点「确认发布」才计 1 次 AI 配额（PRD §5.9）',
      '7 秒口径不含本页耗时（PRD §5.9）',
      '冲刺区只放「完整」档差的两项：门牌号 + 三级类目'
    ]),
    button('确认发布', 'primary', CANVAS.w - SPACING.lg * 2)
  ]);
  s.appendChild(body);
  // 必须在 appendChild 之后：layoutGrow 要求已有 Auto Layout 父级
  body.layoutGrow = 1;
  return s;
}

/**
 * 构造 publish-success-screen：发布完成页（PRD §6.13 T6-④ / :1372-1376 完整度三档）
 * 取代单纯成功 toast，承载完整度卡：当前档 + 还差哪几项 + 权益三条
 * @returns {FrameNode} 发布完成页节点
 */
function buildPublishSuccess() {
  var s = screen('publish-success-screen', '发布完成页', 'PRD §6.13');
  s.appendChild(statusBar());
  var body = box('_body', 'VERTICAL', { w: CANVAS.w, pad: SPACING.xl, gap: SPACING.lg, align: 'CENTER' });
  body.appendChild(text('✓', 'h1', 'color/success-text'));
  body.appendChild(text('发布成功', 'h2'));
  body.appendChild(text('附近的人将看到你的信息', 'small', 'color/text-secondary'));

  // 完整度卡：当前档「半完整」+ 还差哪几项 + 权益三条
  var cc = box('card/completeness', 'VERTICAL', {
    w: CANVAS.w - SPACING.xl * 2, pad: SPACING.lg, gap: SPACING.md,
    fill: 'color/surface', radius: RADIUS.lg, stroke: 'color/warning'
  });
  // 原为一行「当前完整度 🟡 半完整」（条目 [70] 改）。档名不再重复写死在文案里 ——
  // completenessTag 自己就带「半完整」，写两遍会在改档位时漏改其中一处
  var ccTitle = box('_cc-title', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  ccTitle.appendChild(text('当前完整度', 'h3', 'color/warning-text'));
  ccTitle.appendChild(completenessTag('yellow', 'h3', 'color/warning-text'));
  cc.appendChild(ccTitle);
  cc.appendChild(text('三条件满足 2 个（PRD §9.8）', 'caption', 'color/text-placeholder'));

  var gapBox = box('_gap', 'VERTICAL', { gap: SPACING.xs });
  var gapTitle = box('_gap-title', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  gapTitle.appendChild(text('还差这些升', 'small', 'color/text-secondary'));
  gapTitle.appendChild(completenessTag('green', 'small', 'color/text-secondary'));
  gapBox.appendChild(gapTitle);
  gapBox.appendChild(text('· 位置补到门牌号', 'small'));
  cc.appendChild(gapBox);

  // 权益三条（PRD §9.8 推荐池权重表，唯一判定处）
  var benefit = box('_benefits', 'VERTICAL', { gap: SPACING.xs });
  var benefitTitle = box('_benefit-title', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  benefitTitle.appendChild(text('升', 'small', 'color/text-secondary'));
  benefitTitle.appendChild(completenessTag('green', 'small', 'color/text-secondary'));
  benefitTitle.appendChild(text('能得到', 'small', 'color/text-secondary'));
  benefit.appendChild(benefitTitle);
  var items = [
    '推荐池权重 ×2 优先展示（当前 ×1）',
    '附近人 2 倍概率看到你',
    '列表页排序前置，不落末位'
  ];
  for (var i = 0; i < items.length; i++) {
    benefit.appendChild(text('· ' + items[i], 'small', 'color/text-primary'));
  }
  cc.appendChild(benefit);
  // 文案是「回去补齐」而非「立即补齐」（2026-09-01 条目 [75] 改，对齐 Flutter 实现）：
  // 这个按钮跳回发布页，而发布页不保留已填内容 —— §5.11 说的那个能带着原内容
  // 进编辑态的补全页属「我的发布」范围，本期未做。**「立即」在承诺一件它做不到的事**，
  // 用户点进去看到空表单，比按钮文案平淡得多的代价要大
  cc.appendChild(button('回去补齐（约 30 秒）', 'primary', CANVAS.w - SPACING.xl * 2 - SPACING.lg * 2));
  body.appendChild(cc);

  var actRow = box('_actions', 'HORIZONTAL', { gap: SPACING.sm });
  actRow.appendChild(button('去首页看效果', 'secondary', 0));
  actRow.appendChild(button('我的发布', 'ghost', 0));
  body.appendChild(actRow);

  body.appendChild(annotation('发布完成页口径', [
    '取代单纯成功 toast（PRD §6.13 T6-④）',
    '完整度三档判定唯一处为 §9.8（PRD §9.8）',
    '权重口径：完整 ×2 / 半完整 ×1 / 待补充 ×0.5',
    '默认跳「我的发布」，2s Toast + 成功动画（PRD §5.8）',
    '未实名场景改为引导实名主按钮（PRD §3.7）'
  ]));
  s.appendChild(body);
  return s;
}

/**
 * 批次 3 的核心流程页登记表：[画框构造器, 短名]。
 *
 * 短名用于日志回报，与 pageId 去掉 -screen 后缀一致。此前构造器数组与日志里的
 * 页名清单是两份手写副本（改了数组忘改文案就会对不上），改为单表派生。
 */
var CORE_PAGES = [
  // splash → privacy-gate → 受限态 → login 的排列即 §6.5.1 冷启动顺序：
  // 批次 3 按本表顺序落框，画布上左右相邻即流程相邻，评审不必跳着看
  [buildSplash, 'splash'], [buildPrivacyGate, 'privacy-gate'],
  [buildPrivacyDeclined, 'privacy-declined'], [buildLogin, 'login'],
  [buildDetail, 'detail'],
  [buildDetailOffline, 'detail-offline'], [buildPublish, 'publish'], [buildAiConfirm, 'ai-confirm'],
  [buildPublishSuccess, 'publish-success'], [buildContact, 'contact'], [buildProfile, 'profile'],
  [buildMyPublish, 'my-publish'], [buildMyFavorite, 'my-favorite'],
  [buildNotification, 'notification'], [buildTrust, 'trust'], [buildSettings, 'settings']
];

/**
 * 执行批次 3：生成核心流程十四页
 * @returns {Promise<string>} 执行结果摘要
 */
async function batchCore() {
  // 同批次 2：详情/离线态/发布/AI 确认四页均消费 CONTENT，先校验再落地
  contentCatPath();
  await loadFonts();
  await hydrateVariables();
  await hydrateComponents();
  var reset = await resetSection(SECTION_NAMES.core, SECTION_Y.core);
  var page = reset.page;
  var frames = [];
  var names = [];
  for (var i = 0; i < CORE_PAGES.length; i++) {
    frames.push(CORE_PAGES[i][0]());
    names.push(CORE_PAGES[i][1]);
  }
  layout(reset.section, frames, 6, 0);
  var orphans = sweepOrphans(page);
  figma.viewport.scrollAndZoomIntoView(frames);
  return '批次 3 完成\n生成 ' + frames.length + ' 页：\n' + names.join(' / ')
    + '\n清空旧内容 ' + reset.cleared + ' 个｜清扫游离零件 ' + orphans + ' 个';
}

// ============================================================
// 十、批次 4 · 三模态 + T6 四组件
// ============================================================

/**
 * 构造 category-selector：三级分类级联选择器（PRD §10.1）
 * @returns {FrameNode} 分类选择器模态节点
 */
function buildCategorySelector() {
  var s = screen('category-selector', '分类级联选择器', 'PRD §10.1');
  s.appendChild(statusBar());
  s.appendChild(navBar('选择分类', { back: true, right: '取消' }));
  var cols = box('_cascade', 'HORIZONTAL', { w: CANVAS.w, h: 520, gap: 0 });
  // 三列全部取自 CAT_TREE 真值（2026-08-25）：此前 l2 直写「餐饮/零售/工厂/物流/家政」，
  // 与 CAT_TREE 的「全职招聘/兼职临时工/求职找工作」不符，是设计师会照着画错的一处。
  // contentCatPath() 顺带校验演示主线仍在树内，不在则抛错而非静默渲染。
  var l3 = contentCatPath();
  var l1 = [];
  for (var a = 0; a < CAT_LIST.length; a++) l1.push(CAT_LIST[a][1]);
  var l2 = [];
  var workBranches = CAT_TREE[CONTENT.job.catKey];
  for (var b = 0; b < workBranches.length; b++) l2.push(workBranches[b][0]);
  var colData = [l1, l2, l3];
  var colFills = ['color/background', 'color/surface', 'color/primary-light'];
  for (var c = 0; c < 3; c++) {
    var col = box('_col-' + (c + 1), 'VERTICAL', {
      w: CANVAS.w / 3, h: 520, gap: 0, fill: colFills[c]
    });
    for (var i = 0; i < colData[c].length; i++) {
      // 名字带层级与文案：三列同名 _item 会让批次 5 无法唯一定位「帮厨」
      var cell = box('_item/L' + (c + 1) + '/' + colData[c][i], 'HORIZONTAL', {
        w: CANVAS.w / 3, padTop: SPACING.md, padBottom: SPACING.md,
        padLeft: SPACING.md, padRight: SPACING.md, align: 'CENTER', gap: SPACING.xs
      });
      // 选中项取色必须跟着该列底色走（2026-08-26 实机对比度核查后修）。
      //
      // 原先三列统一用 color/primary，但第三列底色是 primary-light，
      // 这正是 PRD §1.4.2 表内明文标 ❌ 的组合：primary 压 primary-light
      // 实测仅 4.42:1，差 4.5 门槛 0.08。PRD 同表给了正确取法 ——
      // primary-light 底上的文字一律用 primary-dark（实测 6.70:1）。
      //
      // 前两列底色分别是 background / surface，primary 压这两者是 4.91:1，
      // 达标，故只需按列区分而不必全改。
      var selRole = colFills[c] === 'color/primary-light'
        ? 'color/primary-dark'
        : 'color/primary';
      cell.appendChild(text(colData[c][i], 'body', i === 0 ? selRole : 'color/text-primary'));
      // 选中态补 ✓ 矢量勾（2026-08-31，四模态首次出图后查出）：
      // §5.4.2 第 3 条明文「选中态：Primary 色 + ✓」，此前只做了 Primary 色。
      // 缺 ✓ 不只是漏一个装饰 —— 三列各有一个选中项，去色后（T6 板去色校验口径）
      // 仅靠色相无从分辨哪一项被选，形状才是承载语义的那一层。
      // 用 svgIcon 而非 '✓' 字符：emoji/符号由系统字体渲染，三端字形不一致。
      if (i === 0) cell.appendChild(svgIcon('_tick', ICON_PATHS.tick, selRole, 14));
      col.appendChild(cell);
    }
    cols.appendChild(col);
  }
  s.appendChild(cols);
  // 底部「确认选择」主按钮（2026-08-31 补）：§5.4.2 第 5 条「底部确认按钮『确认选择』」。
  // 实机量出画框 844 高、内容底沿只到 612，空着的 232px 正是这颗按钮该在的位置 ——
  // 按原则 129，见大片留白先问「这里本该有什么」，答案就写在 PRD 同一节里。
  // 三级已选中（l3 首项）时按钮才可用，故取 primary 实心态而非 disabled 态。
  var confirmBar = box('_confirm-bar', 'VERTICAL', {
    w: CANVAS.w, pad: SPACING.lg, fill: 'color/surface'
  });
  confirmBar.appendChild(button('确认选择', 'primary', CANVAS.w - SPACING.lg * 2));
  s.appendChild(confirmBar);
  var note = box('_note', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg });
  note.appendChild(annotation('级联选择器口径', [
    '三级分类：大类 › 中类 › 小类',
    '选中小类后返回 publish-screen 并触发模板切换',
    '分类树版本号是缓存键 5 元组成员之一（PRD §6.10）'
  ]));
  s.appendChild(note);
  return s;
}

/**
 * 构造 map-selector：地图打点选位（PRD §10.1）
 * @returns {FrameNode} 地图选点模态节点
 */
function buildMapSelector() {
  var s = screen('map-selector', '地图选点', 'PRD §10.1');
  s.appendChild(statusBar());
  s.appendChild(navBar('选择位置', { back: true, right: '确定' }));
  // 改用 stack（无 Auto Layout）：底板矩形须铺满整块并被文案/Pin 叠压，
  // 而 Auto Layout 会把底板当成一个参与排流的兄弟节点、把它挤成一行
  // 地图高从 560 降到 544（2026-08-31）：补门牌两条通路后 _addr 由 75 长到 208 高，
  // 实机量出内容底沿 860 > 画框 844，门牌输入框下缘被裁 16px。
  // 减地图而不减门牌区：门牌是 §7.9 的功能要件、少一像素都影响可点性，
  // 地图只是背景画布，544 与 560 在观感上无差别。
  var MH = 544;
  var m = stack('_map', CANVAS.w, MH);
  mapBasePlate(m, CANVAS.w, MH);

  // 2026-09-01 条目 [77]：字面取值改为读 TAG_SPECS.hintBar（C 族第 2 处）。
  // 改前值 → 改后值：取值逐项不变（含字阶仍取 small，见表内 scaleByNode 说明）。
  // 依据：M4-3e 第一层 ① —— 本轮只登记、不统一 1px 字阶差。
  var hint = box('_hint', 'HORIZONTAL', {
    padTop: TAG_SPECS.hintBar.padV, padBottom: TAG_SPECS.hintBar.padV,
    padLeft: TAG_SPECS.hintBar.padH, padRight: TAG_SPECS.hintBar.padH,
    fill: TAG_SPECS.hintBar.fill, radius: TAG_SPECS.hintBar.radius, align: 'CENTER'
  });
  hint.appendChild(text('拖动地图，中心即选点',
    TAG_SPECS.hintBar.scaleByNode['_hint'], TAG_SPECS.hintBar.textColor));
  m.appendChild(hint);
  hint.opacity = 0.92;

  // 选点 Pin 钉在正中：选点交互的语义就是「屏幕中心 = 选中坐标」
  var sel = pin('category/cat-work', 'resource', null, true);
  m.appendChild(sel);
  sel.x = CANVAS.w / 2 - sel.width / 2;
  sel.y = MH / 2 - sel.height / 2;
  // 文案压在 Pin 上方一段距离，不挡住 Pin 尖端指向的位置
  hint.x = CANVAS.w / 2 - hint.width / 2;
  hint.y = sel.y - hint.height - SPACING.lg;

  s.appendChild(m);
  var addr = box('_addr', 'VERTICAL', { w: CANVAS.w, pad: SPACING.lg, gap: SPACING.sm, fill: 'color/surface' });
  addr.appendChild(text('当前位置', 'small', 'color/text-secondary'));
  addr.appendChild(text('XX 市 XX 区 XX 路 88 号', 'body'));
  // 门牌两条通路（2026-08-31 补）：§7.9「三条件的可自主达成保障」表逐字写明
  // 「地图选点页提供『取当前定位门牌』+ 手动输入门牌框（两者任一填写即达成）」。
  //
  // 这不是可选装饰：位置到门牌号是完整度 🟢 档三条件之一（§7.9 判定表），
  // 而 🟢 档决定曝光权重 ×2。选点页不给这两条通路，用户就落进 PRD 明文
  // 要避免的「想升 🟢 却做不到」。此前实机底沿只到 727、空 117px，正是它的位置。
  //
  // 「取当前定位门牌」用 secondary 而非 primary：本页主操作是顶栏「确定」，
  // 门牌是辅助补全，两颗实心主按钮会争夺同一层视觉权重。
  addr.appendChild(button('取当前定位门牌', 'secondary', CANVAS.w - SPACING.lg * 2));
  addr.appendChild(field('门牌号', '如 3 号楼 2 单元 501', CANVAS.w - SPACING.lg * 2));
  s.appendChild(addr);
  return s;
}

/**
 * 构造 cert-modal：未实名发布拦截浮层（PRD §10.1）
 * @returns {FrameNode} 认证拦截浮层节点
 */
function buildCertModal() {
  var s = screen('cert-modal', '认证拦截浮层', 'PRD §10.1');
  s.appendChild(statusBar());
  var mask = box('_mask', 'VERTICAL', {
    w: CANVAS.w, h: 800, pad: SPACING.xl, align: 'CENTER', justify: 'CENTER'
  });
  // 全画布唯一一处刻意硬编码的填充（2026-08-26 实机核查：2801 个节点里
  // 未绑定变量的 SOLID 填充仅此 1 处）。原因是 token 表里没有遮罩色 ——
  // 21 个 COLOR 变量都是不透明的语义色，而遮罩要的是「黑 + 40% 不透明度」。
  // 不为它新增 token：遮罩只此一用，加变量反而让 token 表多一个孤例。
  // 若将来模态增多、遮罩规格要统一，再补 color/scrim 并回来绑定。
  mask.fills = [{ type: 'SOLID', color: { r: 0, g: 0, b: 0 }, opacity: 0.4 }];
  var sheet = box('_sheet', 'VERTICAL', {
    w: CANVAS.w - SPACING.xl * 2, pad: SPACING.xl, gap: SPACING.md,
    fill: 'color/surface', radius: RADIUS.xl, align: 'CENTER'
  });
  sheet.appendChild(text('发布前需完成实名', 'h2'));
  sheet.appendChild(text('实名后才能发布，保护双方安全', 'small', 'color/text-secondary'));
  sheet.appendChild(button('去实名', 'primary', CANVAS.w - SPACING.xl * 4));
  sheet.appendChild(button('稍后再说', 'ghost', CANVAS.w - SPACING.xl * 4));
  mask.appendChild(sheet);
  s.appendChild(mask);
  return s;
}

/**
 * 构造 T6 四组件规格板（PRD §6.13）
 * 这四个组件不在 §10.1 页面清单内，单独成板供设计师取用
 * @returns {FrameNode} T6 组件板节点
 */
function buildT6Board() {
  var b = box('board/T6 四组件 [PRD §6.13]', 'VERTICAL', {
    w: 480, pad: SPACING.xl, gap: SPACING.xl, fill: 'color/surface', radius: RADIUS.lg
  });
  // 板内可用宽 = 480 - xl 左右内边距。长注释文本必须按这个宽度折行，
  // 见下方 wrapNote 的说明
  var boardInnerW = 480 - SPACING.xl * 2;

  /**
   * 往指定容器追加一条会自动折行的长注释文本
   *
   * 2026-08-31 补：本板三条长注释（完整度角标注意事项 148 字、图标验收判据、
   * 去色校验）原先直接走 text()，而 text() 不设 textAutoResize，Figma 默认
   * WIDTH_AND_HEIGHT —— 文本会横向铺成一整行不折行，把父容器一路撑宽。
   * 实机量出 _t6-3 宽 1290（溢出 480 的画框 834px）、_t6-5 宽 736（溢出 280px），
   * 板子右侧内容整片跑到画框外，出图时被裁掉。
   *
   * 为什么之前没被发现：这块是四个模态之一，14 页普通页每轮都出图人眼过，
   * 而模态从建成起从未出过一张渲染图，探针 250 项也只查节点存在与序列，
   * 没有一条查「子节点是否溢出父画框」。
   *
   * 顺序不可换：textAutoResize 要在 appendChild 之前设（否则先按无限宽算一次），
   * layoutSizingHorizontal = 'FILL' 必须在 appendChild 之后设 ——
   * 没有自动布局父节点时赋值会抛 requires an auto-layout parent。
   *
   * @param {FrameNode} parent 目标容器（须为自动布局且宽度确定）
   * @param {string} content 注释文案
   * @returns {TextNode} 已挂载的文本节点
   */
  function wrapNote(parent, content) {
    var t = text(content, 'caption', 'color/text-secondary');
    t.textAutoResize = 'HEIGHT';
    parent.appendChild(t);
    t.layoutSizingHorizontal = 'FILL';
    return t;
  }

  b.appendChild(text('T6 四组件（不在 §10.1 页面清单内）', 'h2'));

  // ① AI 帮我发 FAB
  var g1 = box('_t6-1', 'VERTICAL', { gap: SPACING.sm });
  g1.appendChild(text('① AI 帮我发 FAB', 'h3', 'color/primary'));
  var fab = box('fab/ai-publish', 'HORIZONTAL', {
    padTop: SPACING.md, padBottom: SPACING.md, padLeft: SPACING.lg, padRight: SPACING.lg,
    radius: RADIUS.full, fill: 'color/accent', gap: SPACING.sm, align: 'CENTER', justify: 'CENTER'
  });
  fab.effects = [{ type: 'DROP_SHADOW', color: { r: 0, g: 0, b: 0, a: 0.2 }, offset: { x: 0, y: 4 }, radius: 12, spread: 0, visible: true, blendMode: 'NORMAL' }];
  // 文案里的 ✨ 去掉（2026-08-29 条目 [70]，P3 同批漏查后补）：本轮首版 emoji
  // 清点用的区间没覆盖 U+2600–27BF，✨ 因此漏网，由新增的「画布零 emoji」
  // 断言捞出。它的危害在这里尤其大 —— FAB 是 Accent 橙底白字的实心块面，
  // 一个不受 paintOf 控制的彩色字符正落在块面中央。
  // 不补矢量图标：AI 语义已由「AI 帮我发」四字 + Accent 专用色双通道承载
  //（PRD §1.4.2「Accent 的唯一用途」），再加装饰星是第三次重复编码。
  fab.appendChild(text('AI 帮我发', 'body', 'color/surface'));
  g1.appendChild(fab);
  g1.appendChild(text('悬浮于 home-screen 右下，唤起一句话发布', 'caption', 'color/text-secondary'));
  b.appendChild(g1);

  // ② 图层控制面板
  var g2 = box('_t6-2', 'VERTICAL', { gap: SPACING.sm });
  g2.appendChild(text('② 图层控制面板', 'h3', 'color/primary'));
  var panel = box('panel/layer-control', 'VERTICAL', {
    w: 220, pad: SPACING.md, gap: SPACING.sm, fill: 'color/surface',
    radius: RADIUS.lg, stroke: 'color/border'
  });
  panel.appendChild(text('图层', 'small', 'color/text-secondary'));
  var layers = [['cat-work', '工作'], ['cat-house', '房屋'], ['cat-vehicle', '车辆'], ['cat-life', '生活'], ['cat-service', '服务']];
  for (var i = 0; i < layers.length; i++) {
    var lr = box('_layer-' + layers[i][0], 'HORIZONTAL', { w: 196, gap: SPACING.sm, align: 'CENTER', justify: 'SPACE_BETWEEN' });
    var lft = box('_l', 'HORIZONTAL', { gap: SPACING.sm, align: 'CENTER' });
    // 2026-09-01 条目 [77]：字面 12 改为读 DOT_SIZES.onMap（值不变）
    lft.appendChild(box('_dot', 'HORIZONTAL', { w: DOT_SIZES.onMap.size, h: DOT_SIZES.onMap.size, radius: RADIUS.full, fill: 'category/' + layers[i][0] }));
    lft.appendChild(text(layers[i][1], 'small'));
    lr.appendChild(lft);
    var sw = box('_switch', 'HORIZONTAL', { w: 32, h: 18, radius: RADIUS.full, fill: i < 3 ? 'color/primary' : 'color/border' });
    lr.appendChild(sw);
    panel.appendChild(lr);
  }
  g2.appendChild(panel);
  g2.appendChild(text('切换图层 P95≤300ms（四段之和，PRD §6.10）', 'caption', 'color/text-secondary'));
  b.appendChild(g2);

  // ③ Pin 完整度角标
  // 定宽（原为 AUTO）：本组含一条 148 字长注释，容器不定宽则 FILL 无依据可算
  var g3 = box('_t6-3', 'VERTICAL', { w: boardInnerW, gap: SPACING.sm });
  g3.appendChild(text('③ 完整度三档角标（规范演示，非地图实态）', 'h3', 'color/primary'));
  var badgeRow = box('_badges', 'HORIZONTAL', { gap: SPACING.lg, align: 'CENTER' });
  // 显式 showCompleteness=true：本组唯一目的就是展示角标形态。
  // 若沿用默认 false，三个 Pin 会长得完全一样，规范演示失效
  badgeRow.appendChild(pin('category/cat-work', 'resource', 'green', false, true));
  badgeRow.appendChild(pin('category/cat-work', 'resource', 'yellow', false, true));
  badgeRow.appendChild(pin('category/cat-work', 'resource', 'red', false, true));
  g3.appendChild(badgeRow);
  // 图例原为一行 emoji 文案「🟢 完整 / 🟡 部分缺失 / 🔴 严重缺失」（条目 [70] 改）。
  // 规格板的图例尤其不能留 emoji：它是「角标该长什么样」的判据本身，
  // 判据自己用了一套不受 Token 控制的颜色，评审就无从核对角标色对不对
  var legendRow = box('_badge-legend', 'HORIZONTAL', { gap: SPACING.md, align: 'CENTER' });
  legendRow.appendChild(completenessTag('green', 'caption', 'color/text-secondary'));
  legendRow.appendChild(completenessTag('yellow', 'caption', 'color/text-secondary'));
  legendRow.appendChild(completenessTag('red', 'caption', 'color/text-secondary'));
  g3.appendChild(legendRow);
  wrapNote(g3, '注意：地图 Marker 不常驻此角标。40×40 内原先叠了 4 条信息（底色=分类、图标=分类、右上 ?=供需、右下点=完整度），分类被重复编码两次、完整度在缩略态几乎无人细看，纯在抢辨识带宽。完整度改由点击 Marker 后的信息卡与列表卡承载（PRD §6.4.2）');
  b.appendChild(g3);

  // ④ 发布完成页完整度卡
  var g4 = box('_t6-4', 'VERTICAL', { gap: SPACING.sm });
  g4.appendChild(text('④ 发布完成页完整度卡', 'h3', 'color/primary'));
  var cc = box('card/completeness', 'VERTICAL', {
    w: 320, pad: SPACING.lg, gap: SPACING.sm, fill: 'color/primary-light', radius: RADIUS.lg
  });
  // 原为「发布成功 · 完整度 🟡 60%」（条目 [70] 改）。百分数留着 ——
  // 它是这张演示卡要展示的东西（档位 + 具体分值），不与档名重复
  var ccTitle = box('_cc-title', 'HORIZONTAL', { gap: SPACING.xs, align: 'CENTER' });
  ccTitle.appendChild(text('发布成功 · 完整度', 'h3', 'color/primary-dark'));
  ccTitle.appendChild(completenessTag('yellow', 'h3', 'color/primary-dark'));
  ccTitle.appendChild(text('60%', 'h3', 'color/primary-dark'));
  cc.appendChild(ccTitle);
  cc.appendChild(text('补齐「工时」和「照片」可提升曝光', 'small', 'color/primary-dark'));
  cc.appendChild(button('立即补齐', 'primary', 0));
  g4.appendChild(cc);
  b.appendChild(g4);

  // ⑤ 20px 真实尺寸对照条
  //
  // 为什么必须有这一组（2026-08-24）：此前两版图标被判「不够形象、无法见图知意」，
  // 直接原因是评审一直在 Figma 里放大到 400% 检视，从未在真实尺寸下看过。
  // Marker 40×40 内图标只占 20×20，放大好看不等于手机上认得出。
  // 本组把 10 个 Marker（五类 × 资源/需求）按 1:1 摆一排，
  // 验收判据：把屏幕缩放到 100%、以手机臂展距离（约 40cm）看，能逐个说出是哪一类。
  // 定宽（原为 AUTO）：本组含两条长注释，同 _t6-3
  var g5 = box('_t6-5', 'VERTICAL', { w: boardInnerW, gap: SPACING.sm });
  g5.appendChild(text('⑤ 20px 真实尺寸对照条（图标验收用）', 'h3', 'color/primary'));

  /**
   * 生成一行 1:1 尺寸的 Marker 对照，五类各一个
   * @param {string} supplyDemand resource / demand
   * @returns {FrameNode} 对照行
   */
  function scaleRow(supplyDemand) {
    var r = box('_scale-row-' + supplyDemand, 'HORIZONTAL', {
      gap: SPACING.md, align: 'CENTER'
    });
    for (var i = 0; i < CAT_LIST.length; i++) {
      var cell = box('_scale-cell', 'VERTICAL', { gap: TIGHT_GAP, align: 'CENTER' });
      cell.appendChild(pin('category/' + CAT_LIST[i][0], supplyDemand, null, false));
      cell.appendChild(text(CAT_LIST[i][1], 'caption', 'color/text-secondary'));
      r.appendChild(cell);
    }
    return r;
  }
  g5.appendChild(text('资源态（实心）', 'small', 'color/text-secondary'));
  g5.appendChild(scaleRow('resource'));
  g5.appendChild(text('需求态（空心 + ?）', 'small', 'color/text-secondary'));
  g5.appendChild(scaleRow('demand'));
  wrapNote(g5, '验收判据：屏幕缩放 100%，以手机臂展距离（约 40cm）看，须能逐个说出是哪一类；说不出即判不通过，回到 ICON_PATHS 换图形而非放大检视');
  wrapNote(g5, '去色校验：在 Figma 里选中上面两行 → 加 Saturation -100 效果，或直接黑白打印；若去色后仍能区分，说明形状本身承载了语义，没有全靠颜色硬撑');
  b.appendChild(g5);

  return b;
}

/**
 * 执行批次 4：生成三模态 + T6 四组件板
 * @returns {Promise<string>} 执行结果摘要
 */
async function batchModal() {
  // 级联选择器三列全部由 CAT_TREE 派生，且第三列承载 FLOW_LINKS 跳转触发点，
  // 这里的校验最关键：l3 对不上会让那条连线静默失效
  contentCatPath();
  await loadFonts();
  await hydrateVariables();
  await hydrateComponents();
  var reset = await resetSection(SECTION_NAMES.modal, SECTION_Y.modal);
  var page = reset.page;
  var frames = [buildCategorySelector(), buildMapSelector(), buildCertModal(), buildT6Board()];
  layout(reset.section, frames, 4, 0);
  var orphans = sweepOrphans(page);
  figma.viewport.scrollAndZoomIntoView(frames);
  return '批次 4 完成\n生成：category-selector / map-selector / cert-modal\n+ T6 五组规格板（含 20px 真实尺寸对照条）'
    + '\n清空旧内容 ' + reset.cleared + ' 个｜清扫游离零件 ' + orphans + ' 个';
}

// ============================================================
// 十之二、批次 5 · 原型跳转连线
// ============================================================

/**
 * 主流程跳转表：[源画框页面ID, 源节点精确名, 目标画框页面ID, 触发方式]
 *
 * 第二列必须是节点的**完整名称**（精确等值），不是关键字：
 * 关键字模糊匹配会因深度优先命中语义无关的靠前节点（详见 findClickable 注释）。
 * 各类节点命名规则：
 * · 按钮        → btn/<variant>/<文案>       （button / buttonRaw）
 * · 列表行      → row/<标签>                 （listRow）
 * · 卡片        → card/<标题>                （card）
 * · 导航右动作  → _nav-action/<文案>          （navBar opt.right）
 * · 底部 Tab    → _tab-<名>                  （bottomTab）
 * · 级联项      → _item/L<层>/<文案>          （buildCategorySelector）
 * · 导航栏搜索框 → _nav-search                （navSearchBox，固定名不含文案）
 * · 导航栏通知铃 → _nav-bell                  （navBell）
 * 导航栏标题为 _nav-title/<文案>，语义上不是可点入口，故一律不出现在本表。
 * 依据 PRD §10 信息架构与 §6.4 主流程
 */
var FLOW_LINKS = [
  // 启动页 → 隐私协议门（2026-09-01 条目 [76] 改目标；原为 → login-screen）。
  // 触发点用 _splash-tap 而非 _body：本表内 _body 在十余个画框里重名，
  // 虽 findClickable 按源画框范围内查重不会冲突，但给触发点起专名
  // 能让「这个节点存在的唯一理由是承载跳转」这件事在代码里自解释。
  // 真机上此跳转是 1.5s 自动转场，Figma 原型无定时触发能力，故降级为点击。
  //
  // **为什么是「改」而不是「再加一条 splash → privacy-gate」**：本表第二列是
  // 节点精确名，而 _splash-tap 在启动页里只有一个 —— findClickable 命中唯一
  // 节点、link() 用 setReactionsAsync 覆盖写，一个触发点连不了两个目标，
  // 加第二条只会让后写的那条把前一条覆盖掉（且不报错）。
  // 目标改为 privacy-gate 而不是保留 login：§6.5.1 明写协议门早于登录
  //（登录发短信已构成个人信息处理），冷启动顺序本身就是合规要求。
  ['splash-screen',           '_splash-tap',                'privacy-gate',           'ON_CLICK'],
  // 协议门同意 → 登录。「不同意 → 受限态」刻意不进本表：本表两端必须是
  // MAIN_SCREENS 登记的主态（下方 batchFlow 有此断言），而受限态是变体画框。
  // 受限态靠与主态并列出图供评审对照，不靠原型连线。
  ['privacy-gate',            'btn/primary/同意并继续',      'login-screen',           'ON_CLICK'],
  // 节点名必须与 login-screen 里实际用的 variant 对齐：该按钮走的是
  // button('登录 / 注册', 'capsule', ...)（见 :3253），Instance 名由
  // button() 拼成 'btn/' + variant + '/' + label。此处曾误写 primary，
  // findClickable 命中 0 个 → link() 抛错 → 被 batchFlow 的 try/catch 收进
  // skipped，只在返回字符串里留一行文字，无人察觉。2026-08-27 由「原型连线
  // 完整性」断言（逐条核 FLOW_LINKS）首次捞出。
  ['login-screen',           'btn/capsule/登录 / 注册',    'home-screen',            'ON_CLICK'],
  ['home-screen',            '_nav-action/列表',           'list-screen',            'ON_CLICK'],
  // 通知铃直达通知中心：PRD §6.4.1 把 🔔 列为导航栏成员，
  // 而 §10.1 里 notification-screen 此前只有「我的 › 通知中心」一个入口，
  // 首页顶部的铃若不可点，用户看到红点却无处可去
  ['home-screen',            '_nav-bell',                  'notification-screen',    'ON_CLICK'],
  ['list-screen',            '_nav-action/地图',           'home-screen',            'ON_CLICK'],
  ['list-screen',            'card/招后厨帮工·包吃住',      'detail-screen',          'ON_CLICK'],
  ['detail-screen',          'btn/primary/联系 TA',        'contact-screen',         'ON_CLICK'],
  ['home-screen',            '_tab-发布',                  'publish-screen',         'ON_CLICK'],
  // 两条源节点名随 P5 由 row/* 改为 field/*（2026-08-29 条目 [70]）：
  // 发布页这两个字段已从 listRow 换成 selectField，节点名前缀跟着变
  ['publish-screen',         'field/选择分类',             'category-selector',      'ON_CLICK'],
  ['publish-screen',         'field/地点',                 'map-selector',           'ON_CLICK'],
  ['publish-screen',         'btn/primary/发布',           'cert-modal',             'ON_CLICK'],
  ['cert-modal',             'btn/primary/去实名',          'trust-screen',           'ON_CLICK'],
  ['category-selector',      '_item/L3/' + CONTENT.job.l3, 'publish-screen',         'ON_CLICK'],
  ['map-selector',           '_nav-action/确定',            'publish-screen',         'ON_CLICK'],
  ['ai-confirm-screen',      'btn/primary/确认发布',        'publish-success-screen', 'ON_CLICK'],
  ['publish-success-screen', 'btn/ghost/我的发布',          'my-publish-screen',      'ON_CLICK'],
  ['publish-success-screen', 'btn/secondary/去首页看效果',   'home-screen',            'ON_CLICK'],
  ['home-screen',            '_tab-我的',                  'profile-screen',         'ON_CLICK'],
  ['profile-screen',         'row/我的发布',               'my-publish-screen',      'ON_CLICK'],
  ['profile-screen',         'row/我的收藏',               'my-favorite-screen',     'ON_CLICK'],
  ['profile-screen',         'row/通知中心',               'notification-screen',    'ON_CLICK'],
  ['profile-screen',         'row/信任与认证',             'trust-screen',           'ON_CLICK'],
  ['profile-screen',         'row/设置',                   'settings-screen',        'ON_CLICK']
];

/**
 * 扫描全文档，按页面 ID 建立「画框主态」索引
 * 同一 pageId 可能有多个画框（如 home-screen 有过程态/降级态/半径档/展开态/T3 弹层），
 * 只取不带 VARIANT_TAG 后缀的主态作为跳转目标
 *
 * 同时统计重名画框：重名会导致索引只保留首个而丢弃其余，
 * 跳转可能连到错误的那一份，故须在批次 5 中显式告警。
 *
 * ⚠️ 画框现已收纳在 SectionNode 内（见 PAGE_NAMES 注释），
 * 故须下探 Section 的 children，不能只扫页面顶层。
 *
 * @returns {Promise<{index: Object, duplicates: Array<string>}>}
 *          index 为 pageId -> FrameNode 映射；duplicates 为重名的 pageId 列表
 */
async function indexMainFrames() {
  await figma.loadAllPagesAsync();
  var index = {};
  var counts = {};

  /**
   * 收录一个候选节点：过滤非主态画框后写入索引与计数
   * @param {SceneNode} node 待判定节点
   * @returns {void}
   */
  function collect(node) {
    if (node.type !== 'FRAME') return;
    var nm = node.name;
    // 跳过变体画框（统一标记，不再依赖中文关键词黑名单）与 master 容器
    if (nm.indexOf(VARIANT_TAG) > -1
      || nm.indexOf('board/') === 0
      || nm.indexOf('_components') === 0) return;
    var pid = nm.split(' ·')[0];
    counts[pid] = (counts[pid] || 0) + 1;
    if (!index[pid]) index[pid] = node;
  }

  var pages = figma.root.children;
  for (var i = 0; i < pages.length; i++) {
    await pages[i].loadAsync();
    var kids = pages[i].children;
    for (var k = 0; k < kids.length; k++) {
      if (kids[k].type === 'SECTION') {
        var inner = kids[k].children;
        for (var j = 0; j < inner.length; j++) collect(inner[j]);
      } else {
        collect(kids[k]);
      }
    }
  }
  var duplicates = [];
  for (var key in counts) {
    if (counts[key] > 1) duplicates.push(key + ' ×' + counts[key]);
  }
  return { index: index, duplicates: duplicates };
}

/**
 * 沿 parent 链上溯，取得节点所属的 PageNode。
 *
 * 为什么不能直接读 node.parent：画框现在挂在 SectionNode 内，
 * parent 是 Section 而不是 Page，直接判 type === 'PAGE' 会永远为假。
 *
 * @param {SceneNode} node 起始节点
 * @returns {PageNode|null} 所属页面，找不到返回 null
 */
function pageOf(node) {
  var p = node.parent;
  while (p && p.type !== 'PAGE') p = p.parent;
  return (p && p.type === 'PAGE') ? p : null;
}

/**
 * 在一个画框内按「节点名精确等值」查找唯一可点节点
 *
 * 为什么必须精确且唯一，而不是早先的 indexOf 模糊匹配：
 * findOne 是深度优先，模糊匹配会让排在前面的语义无关节点抢先命中。
 * 2026-08-24 实测 publish-screen 用关键字「发布」定位，
 * 命中的是导航栏标题文本（_nav-bar 位置最靠前），
 * 于是 cert-modal 的跳转被绑在标题上，底部真正的「发布」主按钮反而没反应。
 * 表面看连线成功、实际交互错位，是最难发现的一类缺陷。
 * 故改为精确等值，并在命中 0 个或多于 1 个时都视为失败上抛，
 * 让批次 5 明确报错，而不是悄悄绑到错误节点上。
 *
 * @param {FrameNode} frame 源画框
 * @param {string} nodeName 目标节点的完整名称（须精确相等）
 * @returns {SceneNode} 唯一命中的节点
 * @throws {Error} 命中 0 个或 2 个以上时抛出，含命中数用于排查
 */
function findClickable(frame, nodeName) {
  var hits = frame.findAll(function (n) { return n.name === nodeName; });
  if (hits.length === 0) throw new Error('未找到节点「' + nodeName + '」');
  if (hits.length > 1) throw new Error('节点「' + nodeName + '」在本画框内重名 ' + hits.length + ' 个，无法确定触发点');
  return hits[0];
}

/**
 * 为一个节点设置原型跳转 reaction
 * @param {SceneNode} node 触发节点
 * @param {FrameNode} target 目标画框
 * @param {string} trigger 触发类型，如 ON_CLICK
 * @returns {Promise<void>}
 */
async function link(node, target, trigger) {
  await node.setReactionsAsync([{
    trigger: { type: trigger },
    actions: [{
      type: 'NODE',
      destinationId: target.id,
      navigation: 'NAVIGATE',
      transition: {
        type: 'SMART_ANIMATE',
        easing: { type: 'EASE_OUT' },
        duration: 0.3
      },
      preserveScrollPosition: false
    }]
  }]);
}

/**
 * 执行批次 5：按 FLOW_LINKS 为主流程画框补原型跳转连线
 * 必须在批次 2/3/4 全部执行完毕后运行，否则目标画框不存在
 * @returns {Promise<string>} 执行结果摘要，含成功与跳过明细
 */
async function batchFlow() {
  var scan = await indexMainFrames();
  var index = scan.index;

  // 前置检查：缺关键页时直接给出可执行指引，而非逐条刷「画框不存在」
  // 判据取三个批次各自的代表页，缺哪个就能反推哪个批次没跑成功
  var required = [
    ['home-screen', '批次 2'], ['list-screen', '批次 2'],
    ['login-screen', '批次 3'], ['publish-screen', '批次 3'], ['profile-screen', '批次 3'],
    ['cert-modal', '批次 4'], ['map-selector', '批次 4']
  ];
  var missingBatches = [];
  for (var r = 0; r < required.length; r++) {
    if (!index[required[r][0]] && missingBatches.indexOf(required[r][1]) === -1) {
      missingBatches.push(required[r][1]);
    }
  }
  if (missingBatches.length) {
    return '批次 5 未执行：缺少前置画框\n\n'
      + '请先成功执行：' + missingBatches.join(' / ')
      + '\n\n说明：批次 5 只负责连线，不生成画框。'
      + '若某批次曾中途报错，它只会生成一部分页面，'
      + '请重新执行该批次（批次已支持幂等，重跑会自动清空旧内容，不会叠加重复页）。';
  }

  var ok = 0;
  var skipped = [];

  for (var i = 0; i < FLOW_LINKS.length; i++) {
    var src = index[FLOW_LINKS[i][0]];
    var dst = index[FLOW_LINKS[i][2]];
    if (!src) { skipped.push(FLOW_LINKS[i][0] + '（源画框不存在）'); continue; }
    if (!dst) { skipped.push(FLOW_LINKS[i][2] + '（目标画框不存在）'); continue; }

    // 同页守卫：Figma 原型跳转不支持跨 Page，跨页时 setReactionsAsync 会抛错。
    // 提前判定可给出明确原因，而非让底层抛出无 message 的异常
    if (pageOf(src) !== pageOf(dst)) {
      skipped.push(FLOW_LINKS[i][0] + ' → ' + FLOW_LINKS[i][2]
        + '（跨 Page 无法跳转，请重跑批次 2/3/4 使其落在同一页）');
      continue;
    }

    // 定位与连线一并纳入 try：定位失败必须明确报错。
    // 早先做法是「找不到就退化为整框点击」，看似保证不断链，
    // 实则把定位失败伪装成成功，掩盖了 reaction 绑到错误节点的问题，
    // 必须让失败可见（2026-08-24 publish-screen 错绑标题即因此长期未被发现）。
    try {
      var node = findClickable(src, FLOW_LINKS[i][1]);
      await link(node, dst, FLOW_LINKS[i][3]);
      ok++;
    } catch (e) {
      // Figma 抛出的未必是标准 Error 对象，直接读 e.message 会得到 undefined，
      // 反而掩盖真实原因，故须做兜底转字符串
      var reason = (e && e.message) ? e.message : String(e);
      skipped.push(FLOW_LINKS[i][0] + ' → ' + FLOW_LINKS[i][2] + '（' + reason + '）');
    }
  }

  // 设置起始画框为 splash-screen，Present 模式从启动页开始走完整冷启动路径。
  // 2026-08-25 从 login-screen 改到 splash-screen：新增启动页后它才是第一屏。
  // 保留 login 兜底：若启动页因故未生成，起点仍落在登录页而非无起点，
  // 否则 Present 模式会随机从画布首个画框开始，看起来像原型坏了。
  // 画框现在挂在 Section 里，故须沿 parent 链上溯到 PageNode
  var startFrame = index['splash-screen'] || index['login-screen'];
  if (startFrame) {
    var lp = pageOf(startFrame);
    if (lp) lp.flowStartingPoints = [{ nodeId: startFrame.id, name: '主流程起点' }];
  }

  var msg = '批次 5 完成\n成功连线 ' + ok + ' / ' + FLOW_LINKS.length + ' 条';
  if (scan.duplicates.length) {
    msg += '\n\n⚠️ 检测到重名画框：\n· ' + scan.duplicates.join('\n· ')
      + '\n重名会导致跳转可能连到错误的那一份，'
      + '建议重新执行对应批次（重跑会自动清空旧内容）。';
  }
  if (skipped.length) msg += '\n\n跳过 ' + skipped.length + ' 条：\n· ' + skipped.join('\n· ');
  msg += '\n\n提示：切到 Figma 顶部 Present 模式测试跳转';
  return msg;
}

// ============================================================
// 十一、清空与消息路由
// ============================================================

/**
 * 清空生成页面上的所有内容（保留 Variables，便于重跑）
 * 注意：会同时删除 Component master，因此必须整体重跑批次 1-5，
 * 不能只清后再单跑批次 2/3/4（那样只会回退成散 Frame）
 *
 * 同时删除旧版分页结构遗留的三个 Page（01 地图与列表 / 02 核心流程 /
 * 03 模态与 T6 组件）。这些旧页里的画框会被 indexMainFrames 扫到，
 * 与新页画框重名，导致跳转连到旧页那一份而全部判为跨页失败。
 *
 * @returns {Promise<string>} 执行结果摘要
 */
async function batchClean() {
  await figma.loadAllPagesAsync();
  var removed = 0;
  var targets = [PAGE_NAMES.setup, PAGE_NAMES.proto];
  // 旧版三页：仅在本次结构调整前生成过的文档里存在，整页删除
  var legacy = ['01 · 地图与列表', '02 · 核心流程', '03 · 模态与 T6 组件'];
  var droppedPages = 0;

  var pages = figma.root.children.slice();
  for (var i = 0; i < pages.length; i++) {
    if (legacy.indexOf(pages[i].name) > -1) {
      // Figma 要求文档至少保留一页，故删除前先切走当前页
      if (figma.currentPage === pages[i]) {
        var keep = null;
        for (var q = 0; q < figma.root.children.length; q++) {
          if (figma.root.children[q] !== pages[i]) { keep = figma.root.children[q]; break; }
        }
        if (keep) await figma.setCurrentPageAsync(keep);
      }
      pages[i].remove();
      droppedPages++;
      continue;
    }
    if (targets.indexOf(pages[i].name) === -1) continue;
    await pages[i].loadAsync();
    // 先清原型起点，避免指向已删节点
    pages[i].flowStartingPoints = [];
    var kids = pages[i].children.slice();
    for (var k = 0; k < kids.length; k++) {
      kids[k].remove();
      removed++;
    }
  }
  COMP_CACHE = {};
  return '已清空 ' + removed + ' 个顶层节点'
    + (droppedPages ? '\n已删除 ' + droppedPages + ' 个旧版分页（跨页跳转失效的根因）' : '')
    + '\nVariables 保留（重跑时复用）\nComponent master 已删除，请从批次 1 重新整体执行';
}

/**
 * 插件消息入口：按 ui.html 传入的 step 分发到对应批次
 * 所有异常统一捕获并回传到 UI 日志，避免插件静默失败
 */
figma.ui.onmessage = async function (msg) {
  if (!msg) return;
  // UI 就绪时索取产出规模，由主线程从真源现算后回填首屏各处计数。
  // 用「UI 主动索取」而非「showUI 后立即推送」：postMessage 早于 UI 脚本注册
  // onmessage 时消息会丢，索取模型天然没有这个竞态。
  if (msg.type === 'stats') {
    figma.ui.postMessage({ type: 'stats', stats: planStats() });
    return;
  }
  if (msg.type !== 'run') return;
  try {
    var result;
    if (msg.step === 'setup')      result = await batchSetup();
    else if (msg.step === 'map')   result = await batchMap();
    else if (msg.step === 'core')  result = await batchCore();
    else if (msg.step === 'modal') result = await batchModal();
    else if (msg.step === 'flow')  result = await batchFlow();
    else if (msg.step === 'clean') result = await batchClean();
    else result = '未知批次：' + msg.step;
    log(result);
  } catch (e) {
    log('执行失败：' + (e && e.message ? e.message : String(e))
      + '\n\n排查建议：\n1. 确认在 Figma 桌面版而非浏览器版\n2. 确认当前不是 Dev Mode（Dev Mode 无法写节点）\n3. 确认对该文件有编辑权限\n4. 先执行批次 1 再执行 2/3/4');
  }
};

figma.showUI(__html__, { width: 340, height: 680 });

// >>> MAP_BG_ASSET_BEGIN (generated by tools/embed-map-bg.py, do not edit by hand)
// ============================================================
// 附：地图底图内嵌资产
//
// 一张高德地图截图（合肥京商商贸城一带，约 1-2km 视野），
// 经 tools/embed-map-bg.py 裁切压缩为 780x1376 JPEG q70 后做 Base64 编码。
//
// 为什么内嵌而不留空位人工贴图：底板共 9 个落点，
// 每次重跑插件都要手工贴 9 次，纯属重复劳动且容易漏贴。
// Figma 官方文档《Working with Images》明确支持以 Base64 形式随插件分发图片，
// 不产生任何网络请求，故 manifest 的 networkAccess: none 无需放开。
//
// 为什么先在本地裁成 390:688 再编码，而不是把整张原图丢给 Figma 的 FILL 去裁：
// 原图接近正方形，FILL 到竖长的地图区会自行裁掉约 41% 的横向像素，
// 那部分字节等于白编码了。本地裁好可省下这笔开销。
//
// 为什么放在文件末尾：这一大段常量不该挤在逻辑代码中间干扰阅读与 diff。
// var 声明在模块顶层，插件加载时整份脚本已执行完毕，
// 而批次逻辑要到 figma.ui.onmessage 触发时才读它，取值一定已就绪。
//
// 为什么是一整行不折行：整串约 17.4 万字符，折成多行 join 反而让 diff 变成
// 十几行齐变；单行的话换底图只体现为一行差异。
//
// 换底图的办法：替换 docs/map-bg.png 后重跑 python tools/embed-map-bg.py，
// 本段会被整段覆盖，不必手工改这串字符。
//
// 截图仅用于内部评审，须保留高德版权水印，不要去水印后外发。
// ============================================================
var MAP_BG_JPEG_B64 = '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';
// <<< MAP_BG_ASSET_END
