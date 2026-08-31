/**
 * 离线布局探针：在 Node 里 mock Figma API，真跑页面构造函数并量出实际尺寸。
 *
 * 为什么必须有它（2026-08-26，M3 精修）：
 * 此前所有探针都是「读 code.js 的文本」，只能验「有没有写对」，验不出「跑起来
 * 长什么样」。本轮就吃了这个亏 —— buildSplash 里一度写成 duckSymbol(132.6, true)，
 * 而该函数第二参是 blockRole 字符串（染色 role）而非布尔反相位。文本探针全绿、
 * node --check 也过，因为语法与命名都没错，错在语义。这类错只有真跑一遍才现形。
 *
 * 它验的三件事，都是文本探针原理上验不到的：
 * ① 内容总高是否溢出 844（login 补了 5 项内容，是本轮最大的溢出风险）；
 * ② 子节点宽度是否超出父容器可用宽（field 溢出 16px 的那类 bug）；
 * ③ 传给工厂函数的参数是否真被当成预期的东西用（染色 role / 尺寸档位）。
 *
 * 为什么不用真 Figma 替代它：实机验收当然更权威，但① 它依赖 Desktop Bridge
 * 在线，不能进 CI；② 人眼看不出「342 还是 358」这种 16px 差；③ 每次都要人重跑
 * 六个批次。离线探针管「机械可判定」的部分，实机管观感，两者不互相替代。
 *
 * 为什么 mock 而不引真 SDK：Figma 没有 Node 端 SDK，插件 API 只存在于其沙箱内。
 *
 * ⚠️ 本 mock 的 Auto Layout 是简化实现，只保证「主轴累加 + 交叉轴取最大」这条
 * 主干正确，不实现 layoutGrow / 换行 / 约束。故它给出的高度是**下界估计**：
 * 报溢出一定是真溢出，报不溢出不能完全排除真机溢出。
 */

'use strict';

const fs = require('fs');
const path = require('path');

const BASE = __dirname;
const CANVAS_H = 844;

// ============================================================
// 一、Mock 节点：实现简化 Auto Layout
// ============================================================

let ID_SEQ = 0;

/**
 * 创建一个 mock 节点，行为对齐 Figma 的 FrameNode / TextNode 关键子集。
 *
 * @param {string} type 节点类型（FRAME / TEXT / RECTANGLE / COMPONENT 等）
 * @returns {Object} mock 节点
 */
function makeNode(type) {
  const n = {
    id: 'M' + (++ID_SEQ),
    type,
    name: '',
    children: [],
    parent: null,
    x: 0,
    y: 0,
    _w: type === 'TEXT' ? 0 : 100,
    _h: type === 'TEXT' ? 0 : 100,
    layoutMode: 'NONE',
    itemSpacing: 0,
    paddingTop: 0,
    paddingBottom: 0,
    paddingLeft: 0,
    paddingRight: 0,
    primaryAxisSizingMode: 'AUTO',
    counterAxisSizingMode: 'AUTO',
    primaryAxisAlignItems: 'MIN',
    counterAxisAlignItems: 'MIN',
    // layoutGrow 只做「如实存取」，不参与本 mock 的布局计算。
    // 目的是让「SPACE_BETWEEN 与 layoutGrow 同设」这条静态断言取到真值；
    // 真要模拟 grow 的拉伸效果需要完整的剩余空间分配算法，超出本 mock 的
    // 定位（见文件头：只保证主轴累加 + 交叉轴取最大）。
    layoutGrow: 0,
    fills: [],
    strokes: [],
    strokeWeight: 1,
    opacity: 1,
    cornerRadius: 0,
    clipsContent: false,
    characters: '',
    fontSize: 14,
    fontName: { family: '', style: '' },
    lineHeight: { value: 0, unit: 'PIXELS' },
    effects: [],
    // 记录变量绑定，供断言检查
    boundVariables: {},
    // 记录本节点被显式 resize 过的轴，用于区分 FIXED 与 HUG
    _resizedW: false,
    _resizedH: false,
  };

  /**
   * 按 Auto Layout 规则重算自身尺寸（HUG 轴才重算，FIXED 轴保持）。
   * @returns {void}
   */
  n._reflow = function () {
    if (n.layoutMode === 'NONE') return;
    const horiz = n.layoutMode === 'HORIZONTAL';
    let main = 0;
    let cross = 0;
    let count = 0;
    for (const c of n.children) {
      // 移出画框的标注卡等绝对定位子节点不参与流式排布
      if (c.layoutPositioning === 'ABSOLUTE') continue;
      const cw = c.width;
      const ch = c.height;
      main += horiz ? cw : ch;
      cross = Math.max(cross, horiz ? ch : cw);
      count++;
    }
    if (count > 1) main += n.itemSpacing * (count - 1);
    const mainPad = horiz
      ? n.paddingLeft + n.paddingRight
      : n.paddingTop + n.paddingBottom;
    const crossPad = horiz
      ? n.paddingTop + n.paddingBottom
      : n.paddingLeft + n.paddingRight;

    // 主轴：primaryAxisSizingMode AUTO 时抱内容
    if (n.primaryAxisSizingMode === 'AUTO') {
      if (horiz) n._w = main + mainPad;
      else n._h = main + mainPad;
    }
    // 交叉轴：counterAxisSizingMode AUTO 时抱内容
    if (n.counterAxisSizingMode === 'AUTO') {
      if (horiz) n._h = cross + crossPad;
      else n._w = cross + crossPad;
    }
    // 内容溢出记录：FIXED 轴装不下内容时留痕，供断言查
    n._contentMain = main + mainPad;
    n._contentCross = cross + crossPad;
  };

  /**
   * 向上冒泡触发重算，模拟 Figma 增删子节点后父级自动 HUG。
   * @returns {void}
   */
  n._bubble = function () {
    let p = n;
    while (p) {
      p._reflow();
      p = p.parent;
    }
  };

  Object.defineProperty(n, 'width', {
    get: () => n._w,
    enumerable: false,
  });
  Object.defineProperty(n, 'height', {
    get: () => n._h,
    enumerable: false,
  });

  // layoutSizing* 必须带真机的前置约束，不能做成裸字段。
  //
  // 2026-08-27：这两个属性原本是普通字段，纯存取、不校验。于是我在
  // buildPermissionGuide 里写出「先设 FILL、后 appendChild」的顺序错误时，
  // 离线一路全绿，直到实机跑批次 2 才抛错。Figma 的规则是：
  // **只有 FILL** 要求节点已是 Auto Layout 父级的直接子节点，否则报
  // "Setting layoutSizingHorizontal to FILL requires an auto-layout parent"。
  // FIXED 无此要求（它只是把该轴尺寸固定），所以 button() 里那句
  // inst.layoutSizingHorizontal = 'FIXED'（code.js:1555，在 appendChild 之前）
  // 在真机上是合法的 —— 首版约束写成「FILL 或 FIXED 都校验」，
  // 立刻把这处合法代码误报成错，是检查器过严的典型（说明文档 ㊲）。
  //
  // 这是第二次栽在「mock 把有前置条件的 API 做成无条件成功」上
  //（前一次是 setReactionsAsync 完全没实现）：
  // **凡真机会因调用顺序/上下文抛错的 API，mock 必须把那个条件也实现出来，
  // 且条件要照真机原样收窄，不能宁严勿松 —— 过严会造出成批假阳性。**
  const layoutSizingGuard = (axis) => ({
    get: () => n['_layoutSizing' + axis],
    set: (v) => {
      if (v === 'FILL') {
        const p = n.parent;
        if (!p || p.layoutMode === 'NONE' || p.layoutMode === undefined) {
          throw new Error(
            'Cannot set layoutSizing' + axis + '="FILL" on node "' + n.name +
            '"：FILL 要求节点已是 Auto Layout 父级的直接子节点。' +
            '当前 parent=' + (p ? p.name + '(layoutMode=' + p.layoutMode + ')' : 'null') +
            ' —— 把赋值移到 appendChild 之后'
          );
        }
      }
      n['_layoutSizing' + axis] = v;
    },
    enumerable: false,
  });
  n._layoutSizingHorizontal = 'HUG';
  n._layoutSizingVertical = 'HUG';
  Object.defineProperty(n, 'layoutSizingHorizontal', layoutSizingGuard('Horizontal'));
  Object.defineProperty(n, 'layoutSizingVertical', layoutSizingGuard('Vertical'));

  n.appendChild = function (child) {
    // 必须让【旧父】也重算：Figma 里节点被移走后，原父级会立刻收缩。
    // 首版漏了这步，导致 detachAnnotations 移出口径卡后 body 高度不下降，
    // 探针据此误报「移出无效」——探针自身的错，不是被测代码的错。
    let oldParent = null;
    if (child.parent) {
      const i = child.parent.children.indexOf(child);
      if (i >= 0) child.parent.children.splice(i, 1);
      oldParent = child.parent;
    }
    child.parent = n;
    n.children.push(child);
    if (oldParent) oldParent._bubble();
    n._bubble();
  };

  n.insertChild = function (idx, child) {
    let oldParent = null;
    if (child.parent) {
      const i = child.parent.children.indexOf(child);
      if (i >= 0) child.parent.children.splice(i, 1);
      oldParent = child.parent;
    }
    child.parent = n;
    n.children.splice(idx, 0, child);
    if (oldParent) oldParent._bubble();
    n._bubble();
  };

  n.remove = function () {
    if (n.parent) {
      const i = n.parent.children.indexOf(n);
      if (i >= 0) n.parent.children.splice(i, 1);
      const p = n.parent;
      n.parent = null;
      p._bubble();
    }
  };

  n.resize = function (w, h) {
    n._w = w;
    n._h = h;
    n._resizedW = true;
    n._resizedH = true;
    n._bubble();
  };

  n.resizeWithoutConstraints = n.resize;

  /**
   * 模拟 Figma 的 rescale：按比例缩放自身与整棵子树。
   *
   * 必须与 resize 区分开：resize 只改外框（1024 的图形会被裁在小框里），
   * rescale 连内部几何一起缩。duckSymbol 与 svgIcon 都依赖后者。
   *
   * @param {number} k 缩放系数
   * @returns {void}
   */
  n.rescale = function (k) {
    const walk = (node) => {
      node._w *= k;
      node._h *= k;
      node.x *= k;
      node.y *= k;
      for (const c of node.children) walk(c);
    };
    walk(n);
    n._bubble();
  };

  n.findAll = function (pred) {
    const out = [];
    const walk = (node) => {
      for (const c of node.children) {
        if (!pred || pred(c)) out.push(c);
        walk(c);
      }
    };
    walk(n);
    return out;
  };

  n.findOne = function (pred) {
    return n.findAll(pred)[0] || null;
  };

  n.setBoundVariable = function (field, v) {
    if (!v) return;
    n.boundVariables[field] = v;
  };

  n.setRelaunchData = function () {};
  // pluginData 必须如实存取（2026-08-27 补）：annotation() 把 severity/target
  // 存进 pluginData，detachAnnotations 再读出来落节点级标注。原先 set 是空实现、
  // get 恒返回空串 —— 离线跑时节点级标注**一条都不会落**，而断言看不出来。
  n._pluginData = {};
  n.setPluginData = function (k, v) { n._pluginData[k] = v; };
  n.getPluginData = function (k) { return n._pluginData[k] || ''; };
  // Dev Mode annotation：真 API 是可读写数组属性，mock 只需如实存取。
  // 要判定的是「标注落到了哪个节点、内容对不对、分类对不对」。
  n.annotations = [];
  // 原型连线（2026-08-27 补）：批次 5 全靠 setReactionsAsync 落跳转，而 mock
  // 此前完全没实现它 —— 于是离线跑批次 5 时，24 条连线**每一条都静默失败**，
  // 被 batchFlow 内的 try/catch 收进 skipped 后只体现为返回字符串里的文字，
  // 没有任何断言在看。这是本探针最大的一处假绿：连线全断也照样全绿。
  //
  // 只做「如实存取」：reaction 的语义（转场动画、缓动）不影响可判定性，
  // 要判定的是「触发点找对了没、目标画框存在没、有没有漏条」。
  n.reactions = [];
  n.setReactionsAsync = async function (rs) { n.reactions = rs; };
  n.clone = function () {
    const c = makeNode(n.type);
    Object.assign(c, { name: n.name, _w: n._w, _h: n._h });
    return c;
  };
  n.createInstance = function () {
    const inst = makeNode('INSTANCE');
    inst.name = n.name;
    inst._w = n._w;
    inst._h = n._h;
    // Instance 复制 master 的子树。
    //
    // 2026-08-27：字段清单从「只结构与尺寸」扩到「凡断言会读的都复制」。
    // 起因是「字体一致性」那条新断言一开就报 183 处 fontName 为空，逐一查下去
    // 发现 183 处**全部**落在 INSTANCE 内部（inInstance=183 / notInInstance=0）——
    // 真机上 Instance 是继承 master 字体的，空 fontName 是这里漏抄造成的假阳性。
    // 教训：mock 少抄一个字段，就等于给读该字段的断言批量注入假数据。
    const deepCopy = (src, dst) => {
      for (const c of src.children) {
        const cc = makeNode(c.type);
        cc.name = c.name;
        cc._w = c._w;
        cc._h = c._h;
        cc.characters = c.characters;
        cc.fontSize = c.fontSize;
        cc.fontName = c.fontName;
        cc.lineHeight = c.lineHeight;
        cc.textTruncation = c.textTruncation;
        cc.textAutoResize = c.textAutoResize;
        cc.fills = c.fills;
        cc.strokes = c.strokes;
        cc.strokeWeight = c.strokeWeight;
        cc.cornerRadius = c.cornerRadius;
        cc.opacity = c.opacity;
        cc.clipsContent = c.clipsContent;
        cc.layoutMode = c.layoutMode;
        cc.itemSpacing = c.itemSpacing;
        cc.layoutGrow = c.layoutGrow;
        cc.layoutPositioning = c.layoutPositioning;
        cc.x = c.x;
        cc.y = c.y;
        cc.paddingTop = c.paddingTop;
        cc.paddingBottom = c.paddingBottom;
        cc.paddingLeft = c.paddingLeft;
        cc.paddingRight = c.paddingRight;
        cc.primaryAxisSizingMode = c.primaryAxisSizingMode;
        cc.counterAxisSizingMode = c.counterAxisSizingMode;
        cc.primaryAxisAlignItems = c.primaryAxisAlignItems;
        cc.counterAxisAlignItems = c.counterAxisAlignItems;
        // 变量绑定要浅拷一份而非共引：Instance 上再绑会污染 master
        cc.boundVariables = Object.assign({}, c.boundVariables);
        dst.appendChild(cc);
        // layoutSizing* 必须在 appendChild 之后抄：它带「父级须是 Auto Layout」
        // 的前置约束（见 makeNode 里的 layoutSizingGuard），
        // 在挂上父级前赋值会抛错 —— 与真机同规则。
        cc.layoutSizingHorizontal = c.layoutSizingHorizontal;
        cc.layoutSizingVertical = c.layoutSizingVertical;
        deepCopy(c, cc);
      }
    };
    deepCopy(n, inst);
    // Instance 尺寸由 master 决定，不随子树重算
    inst._w = n._w;
    inst._h = n._h;
    inst._reflow = function () {};
    return inst;
  };

  return n;
}

/**
 * 创建 mock 文本节点：字符数 × 字宽估算宽度，行高估算高度。
 *
 * 为什么用估算：Figma 的文本测量依赖真实字体度量，Node 里没有。
 * 估算系数 0.62 取「中文全宽、西文半宽」的混合近似（中文按 1.0 倍字号，
 * ASCII 按 0.5 倍），只用于判断「有没有明显溢出」，不用于精确对齐。
 *
 * @returns {Object} mock TEXT 节点
 */
function makeText() {
  const t = makeNode('TEXT');
  let chars = '';
  Object.defineProperty(t, 'characters', {
    get: () => chars,
    set: (v) => {
      chars = String(v);
      t._remeasure();
    },
    enumerable: true,
  });
  t._remeasure = function () {
    let w = 0;
    for (const ch of chars) {
      // 中日韩全宽字符按 1.0 倍字号，其余按 0.53 倍
      w += /[\u2E80-\u9FFF\uFF00-\uFFEF\u3000-\u303F]/.test(ch) ? 1.0 : 0.53;
    }
    t._w = Math.ceil(w * t.fontSize);
    const lh = t.lineHeight && t.lineHeight.value ? t.lineHeight.value : t.fontSize * 1.4;
    t._h = Math.ceil(lh);
    t._bubble();
  };
  t._reflow = function () {};
  return t;
}

// ============================================================
// 二、Mock figma 全局对象
// ============================================================

const mockPages = [];

/**
 * 解析 SVG 字符串的宽高，供 createNodeFromSvg 返回正确尺寸的节点。
 *
 * 为什么要真解析：duckSymbol 依赖返回节点的 resize 来落尺寸，若尺寸永远是
 * 默认 100，符号档位相关的断言就全部失去意义。
 *
 * @param {string} svg SVG 全文
 * @returns {Object} mock 节点，children 对应 SVG 内的图元
 */
function nodeFromSvg(svg) {
  const n = makeNode('FRAME');
  n.name = 'svg';
  const mw = /width="([\d.]+)"/.exec(svg);
  const mh = /height="([\d.]+)"/.exec(svg);
  n._w = mw ? parseFloat(mw[1]) : 100;
  n._h = mh ? parseFloat(mh[1]) : 100;
  n._reflow = function () {};
  // 逐个图元建子节点，且**保持文档顺序** —— duckSymbol 的染色依赖这个顺序
  const elems = svg.match(/<(rect|circle|path|ellipse)\b[^>]*>/g) || [];
  for (const e of elems) {
    const c = makeNode('VECTOR');
    c.name = /^<(\w+)/.exec(e)[1];
    c._reflow = function () {};
    // 记下占位填充色，便于验证染色是否真的改绑
    const mf = /fill="([^"]+)"/.exec(e);
    c._svgFill = mf ? mf[1] : null;
    n.appendChild(c);
  }
  n._w = mw ? parseFloat(mw[1]) : 100;
  n._h = mh ? parseFloat(mh[1]) : 100;
  return n;
}

const createdVariables = [];

const figma = {
  root: { children: mockPages, name: 'mock' },
  currentPage: null,
  base: null,
  createFrame: () => makeNode('FRAME'),
  createText: () => makeText(),
  createRectangle: () => makeNode('RECTANGLE'),
  createNodeFromSvg: (svg) => nodeFromSvg(svg),
  createComponentFromNode: (node) => {
    const c = makeNode('COMPONENT');
    c.name = node.name;
    // 真 API 里 ComponentNode.description 是可写字符串，未设时为空串。
    // 这里必须显式给初值：不给的话 describeComponents() 的赋值会静默创建一个
    // 全新属性，断言读到的是探针自己造出来的东西 ——「写没写」和「有没有这个
    // 字段」就分不清了，也验不出「漏写」这种失败（同 I1 那轮 pluginData 的坑）。
    c.description = '';
    // 尺寸必须在搬走子节点【之前】就锁定。
    //
    // 2026-08-27 修：原实现在 for 循环之后又读了一次 node.width/height，
    // 而子节点此时已全被 appendChild 搬到 c 上、原 node 触发 _bubble 后
    // hug 成「只剩 padding」的空壳（buttonRaw 的按钮 44 高 → 塌成 24）。
    // 于是所有走 COMP_CACHE 的按钮 Instance 全部继承到 24 高，
    // 「触控区 ≥44」那条断言据此报出成批假阳性（btn/primary/* 358×24）。
    const w0 = node.width;
    const h0 = node.height;
    // 布局属性一并复制：Component 在真机上保留原 Frame 的 Auto Layout，
    // 不复制会让 Instance 的 padding/间距全部归零，量出的尺寸失真
    c.layoutMode = node.layoutMode;
    c.itemSpacing = node.itemSpacing;
    c.paddingTop = node.paddingTop;
    c.paddingBottom = node.paddingBottom;
    c.paddingLeft = node.paddingLeft;
    c.paddingRight = node.paddingRight;
    c.primaryAxisSizingMode = node.primaryAxisSizingMode;
    c.counterAxisSizingMode = node.counterAxisSizingMode;
    c.primaryAxisAlignItems = node.primaryAxisAlignItems;
    c.counterAxisAlignItems = node.counterAxisAlignItems;
    for (const ch of node.children.slice()) c.appendChild(ch);
    c._w = w0;
    c._h = h0;
    return c;
  },
  createImage: () => ({ hash: 'mockhash' }),
  // 真 API 返回 Uint8Array（Plugin API Update 42 起）。这里只需返回一个
  // 能被 createImage 接住的对象即可，内容不参与布局计算。
  base64Decode: () => new Uint8Array(8),
  createPage: () => {
    const p = makeNode('PAGE');
    p._reflow = function () {};
    p.loadAsync = async function () {};
    mockPages.push(p);
    return p;
  },
  createSection: () => {
    const s = makeNode('SECTION');
    s._reflow = function () {};
    return s;
  },
  getNodeById: () => null,
  loadFontAsync: async () => {},
  loadAllPagesAsync: async () => {},
  setCurrentPageAsync: async (p) => { figma.currentPage = p; },
  showUI: () => {},
  ui: { onmessage: null, postMessage: () => {} },
  viewport: { scrollAndZoomIntoView: () => {} },
  variables: {
    getLocalVariablesAsync: async (type) =>
      createdVariables.filter((v) => v.resolvedType === type),
    getLocalVariableCollectionsAsync: async () => [],
    createVariableCollection: (name) => ({
      id: 'C1',
      name,
      modes: [{ modeId: 'm1', name: 'Mode 1' }],
      defaultModeId: 'm1',
    }),
    createVariable: (name, coll, type) => {
      // valuesByMode 必须真存值：ensureVariables 的幂等分支会读
      // v.valuesByMode[modeId] 与目标色比对（code.js:299「幂等的含义是值对齐」）。
      // 首版 mock 没有这个字段，于是第一次调用能过（走 created 分支），
      // 第二次调用就崩在 reading 'm1' —— 而批次 1 正是第二次调用者。
      const v = {
        id: 'V' + (createdVariables.length + 1),
        name,
        resolvedType: type,
        valuesByMode: {},
        setValueForMode(modeId, value) { this.valuesByMode[modeId] = value; },
      };
      createdVariables.push(v);
      return v;
    },
    setBoundVariableForPaint: (paint, field, v) =>
      Object.assign({}, paint, { boundVariables: { [field]: v } }),
  },
};

global.figma = figma;
global.__html__ = '';

// ============================================================
// 三、加载 code.js（剥掉插件入口，只取纯函数）
// ============================================================

const raw = fs.readFileSync(path.join(BASE, 'code.js'), 'utf8');

// figma.showUI 与 ui.onmessage 是插件入口，在 Node 里不该执行副作用。
// mock 已把它们做成空实现，故可直接整体 eval。
const sandboxKeys = [];
const wrapped = new Function(
  'figma',
  '__html__',
  raw + '\n;return { ' +
    ['buildSplash', 'buildLogin', 'buildDetail', 'buildContact',
      'detachAnnotations', 'layout', 'ensureVariables', 'hydrateVariables',
      'registerComponents', 'CANVAS', 'SPACING', 'RADIUS', 'TYPE_SCALE',
      'field', 'button', 'annotation', 'duckSymbol', 'checkRow',
      // 六个批次入口：box() 轴向修复是全局改动，只验 splash/login 不够，
      // 必须把全部画框都真跑一遍才算回归（见「八、全批次回归」）
      'batchSetup', 'batchMap', 'batchCore', 'batchModal', 'batchFlow',
      // 连线表与变体标记（2026-08-27）：「原型连线完整性」那条断言必须拿
      // code.js 的真源表去逐条核，不能在探针里手抄一份副本 —— 抄的那份
      // 与真源脱节时，断言验的是副本自己，永远绿
      'FLOW_LINKS', 'VARIANT_TAG', 'PAGE_NAMES',
      // 产出规模自报（2026-08-27，I4）：ui.html 首屏计数改为运行时回填后，
      // 「回填的数是不是真的」必须由断言守住，否则 planStats 自己算错就没人能发现
      'planStats', 'MAIN_SCREENS', 'CORE_PAGES', 'screen',
      'SEMANTIC_COLORS', 'CATEGORY_COLORS', 'CATEGORY_DEEP', 'SHELL_TABS', 'BUTTON_VARIANTS',
      // 标注分级与节点级引用（2026-08-27，I1）：severity 配色、pluginData 传值、
      // 节点级 annotation 落点全部要能被断言直接查真源，不能只看画布卡还在不在
      'SEVERITY', 'ANNO_CATEGORY', 'attachNodeAnnotation', 'paintOf', 'box',
      // 组件契约（2026-08-27，条目 [51] 第 5 步）：description 里写的规格值必须
      // 与 BUTTON_SPECS 等真源逐项对齐，故两者都要能被断言直接取到 —— 在探针里
      // 手抄一份期望文本，验的就是抄本自己（原则㊾）
      'describeComponents', 'BUTTON_SPECS', 'CAT_LIST',
      // 动效规格（2026-08-27，条目 [51] 第 6 步 / I5）：TIMING/EASING 进不了
      // Variables，动效唯一的机读承载体就是 annotation 的 pluginData。断言必须
      // 拿 MOTION 与 motionLine 现算出期望文本去核对画布，不能手抄
      'MOTION', 'MOTION_PX_PER_MS', 'motionLine', 'motionSpecLines',
      // 像素精修（2026-08-27，条目 [61]）：三条不变量要真跑 markerInfoCard 与
      // listHintRow 去量左缘，不能只做源码正则 —— 写了容器却忘挂子节点时，
      // 正则全绿而画面照旧参差
      'markerInfoCard', 'listHintRow', 'TIGHT_GAP', 'CHECKBOX_SIZE',
      // 条目 [70]（2026-08-29，P1–P5 修复）：新增的六个构造器必须能被断言直接
      // 真跑。尤其 completenessTag/doneTag —— 它们替掉的是 emoji，而 emoji 的
      // 危害（三端字形不一、色值不受 paintOf 控制）在离线与实机都看不出来，
      // 只有「画布零 emoji」这条断言拦得住下一次随手写 🟢
      'completenessTag', 'doneTag', 'selectField', 'flexSpacer', 'pushToBottom',
      'ICON_PATHS', 'CONTENT', 'buildPublish', 'buildProfile', 'buildTrust', 'listRow',
      // 条目 [70] 后补的四页（notification / my-favorite / my-publish / settings）：
      // 这四页的病根是「PRD 明列的条目没画全」，判据必须真跑构造器去数条目，
      // 源码正则数不出「五种触发种类是否齐备」这类语义完整性
      'buildNotification', 'buildMyFavorite', 'buildMyPublish', 'buildSettings',
      'notifyRow', 'groupTitle', 'certRow',
      // 条目 [71]：card 供「改 layoutMode 后卡高是否装得下」的反向断言直接构造用
      'card',
      // 条目 [70] 第八段（2026-08-31）：detail-offline / ai-confirm 两页改贴底，
      // contact 页按 PRD §7.4.2 稿图补全三块内容。两页必须真跑才能量出
      // 「_spacer 在不在、尾部节点排没排在它后面」，源码正则看不出贴底是否成立
      'buildDetailOffline', 'buildAiConfirm',
      // 条目 [70] 第三段（2026-08-30）：分页收尾条，三个「我的」列表页 + list 页共用
      'listEndRow']
      .map((k) => k + ': typeof ' + k + " !== 'undefined' ? " + k + ' : undefined')
      .join(', ') +
    ' };'
);

const M = wrapped(figma, '');

// ============================================================
// 四、断言框架
// ============================================================

const passed = [];
const failed = [];

/**
 * 记录一项校验结果。
 * @param {string} label 校验项名称
 * @param {boolean} ok 是否通过
 * @param {string} detail 实测值或失败原因
 * @returns {void}
 */
function check(label, ok, detail) {
  (ok ? passed : failed).push(label + (detail ? ' | ' + detail : ''));
  console.log((ok ? 'PASS  ' : 'FAIL  ') + label + (detail ? '  [' + detail + ']' : ''));
}

/**
 * 递归打印节点树，供人工核对结构。
 * @param {Object} n 根节点
 * @param {number} depth 当前缩进层级
 * @param {Array<string>} out 输出累加数组
 * @returns {Array<string>} 树形文本行
 */
function dumpTree(n, depth, out) {
  out = out || [];
  depth = depth || 0;
  const size = Math.round(n.width) + '×' + Math.round(n.height);
  const txt = n.type === 'TEXT' ? '  "' + n.characters + '"' : '';
  out.push('  '.repeat(depth) + n.name + ' <' + n.type + '> ' + size + txt);
  for (const c of n.children) dumpTree(c, depth + 1, out);
  return out;
}

/**
 * 取某节点子树内第一个名字匹配的节点。
 * @param {Object} root 根节点
 * @param {string} needle 名字包含的子串
 * @returns {Object|null} 命中节点
 */
function byName(root, needle) {
  return root.findOne((n) => n.name.indexOf(needle) >= 0);
}

/**
 * 收集子树内所有 TEXT 节点的文案。
 * @param {Object} root 根节点
 * @returns {Array<string>} 文案数组
 */
function allText(root) {
  return root.findAll((n) => n.type === 'TEXT').map((n) => n.characters);
}

// ============================================================
// 五、准备：建变量并载入缓存（绑定要靠它，否则全静默跳过）
// ============================================================

(async function main() {
  await M.ensureVariables();
  await M.hydrateVariables();
  // 期望数从 code.js 的三张色表 + 三张数值表实际长度算出，不写死（2026-08-26 改）：
  // 原先硬编码 38，新增 5 个 category/*-deep 后这条会失败，但失败信息只说
  // 「实建 43」，读的人无从判断 43 是对还是错。改为按真源计数后，这条断言
  // 验的是「注册环节没漏表」而不是「总数恰好等于某个历史数字」。
  // 只数「顶层键」，用大括号配平取表体，并跳过行注释。三处坑都踩过：
  //
  // ① 正则 `\{([\s\S]*?)\};` 在 SPACING / RADIUS 这类**整表写在一行**的表上会
  //    跨过表尾继续匹配到后面某张多行表的 `\n};`，body 里混进好几张表
  //   （实测 FLOAT 数到 78）；
  // ② TYPE_SCALE 的值本身是对象（h1: { size, weight, lineHeight }），不按深度
  //    过滤会把内层键一起算进去；
  // ③ SEMANTIC_COLORS 表体内有大段 `//` 注释，里面的「4.5:1」「2.54–4.23:1」
  //    等冒号会被当成键（实测 COLOR 数到 36，比实建多 10）。
  //
  // 表体内没有含 `//` 的字符串字面量（全是 HEX 与数字），故直接遇 `//` 跳到行尾。
  const tableLen = (name) => {
    const at = raw.indexOf('var ' + name + ' = {');
    if (at < 0) return 0;
    let depth = 0, count = 0;
    for (let i = raw.indexOf('{', at); i < raw.length; i++) {
      if (raw[i] === '/' && raw[i + 1] === '/') {
        i = raw.indexOf('\n', i);
        if (i < 0) break;
        continue;
      }
      const ch = raw[i];
      if (ch === '{') depth++;
      else if (ch === '}') { depth--; if (depth === 0) break; }
      else if (ch === ':' && depth === 1) count++;
    }
    return count;
  };
  const wantColor = tableLen('SEMANTIC_COLORS') + tableLen('CATEGORY_COLORS')
    + tableLen('CATEGORY_DEEP');
  const wantFloat = tableLen('TYPE_SCALE') + tableLen('SPACING') + tableLen('RADIUS');
  const gotColor = createdVariables.filter((v) => v.resolvedType === 'COLOR').length;
  const gotFloat = createdVariables.filter((v) => v.resolvedType === 'FLOAT').length;
  check(
    '变量表已建立（COLOR ' + wantColor + ' + FLOAT ' + wantFloat + ' = ' + (wantColor + wantFloat) + '）',
    gotColor === wantColor && gotFloat === wantFloat,
    '实建 COLOR ' + gotColor + ' / FLOAT ' + gotFloat +
      '（真源表期望 COLOR ' + wantColor + ' / FLOAT ' + wantFloat + '）'
  );

  console.log('\n=== splash-screen 实跑 ===');
  const splash = M.buildSplash();
  const splashTree = dumpTree(splash);
  console.log(splashTree.join('\n'));

  // ① 画框尺寸必须是 390×844，内容不得把 FIXED 画框顶大
  check(
    'splash 画框 390×844',
    Math.round(splash.width) === 390 && Math.round(splash.height) === 844,
    Math.round(splash.width) + '×' + Math.round(splash.height)
  );

  // ② 符号档位：132.6 ≥ 96 应落 full 档（两道环 = 4 个图元：rect + 2 path + disc-path + eye）
  const sym = byName(splash, '_duck-symbol');
  check(
    'splash 符号落 full 档（≥96px）',
    sym !== null && sym.name === '_duck-symbol-full',
    sym ? sym.name : '未找到符号节点'
  );
  check(
    'splash 符号实测尺寸 = 132.6',
    sym !== null && Math.abs(sym.width - 132.6) < 0.5,
    sym ? sym.width + '×' + sym.height : 'n/a'
  );

  // ③ 这是本轮真正要防的错：duckSymbol 第二参是染色 role，不是布尔反相位。
  //    full 档结构为「圆角色块 + 2 环 + 盘鸭头 + 眼点」共 5 个图元
  check(
    'splash 符号为 full 档 5 图元结构（未被误传参数破坏）',
    sym !== null && sym.children.length === 5,
    sym ? sym.children.length + ' 个图元' : 'n/a'
  );

  // ④ 品牌色底上文案必须反白
  const splashTexts = splash.findAll((n) => n.type === 'TEXT');
  check(
    'splash 文案取 PRD §3.4.1 原文 slogan',
    allText(splash).indexOf('用就近的资源解决本地的需求') >= 0,
    JSON.stringify(allText(splash).slice(0, 3))
  );

  // ⑤ 口径卡此刻还在画框内（移出发生在 layout 阶段），先记数
  const splashCardsBefore = splash.findAll(
    (n) => n.name.indexOf('_annotation/') === 0
  ).length;
  check('splash 构造后画框内有 1 张口径卡（待 layout 移出）',
    splashCardsBefore === 1, splashCardsBefore + ' 张');

  console.log('\n=== login-screen 实跑 ===');
  const login = M.buildLogin();
  console.log(dumpTree(login).join('\n'));

  check(
    'login 画框 390×844',
    Math.round(login.width) === 390 && Math.round(login.height) === 844,
    Math.round(login.width) + '×' + Math.round(login.height)
  );

  // ⑥ 最关键：内容总高不得溢出 844。
  //
  // 判定的是【扣掉口径卡之后的净高】，不是构造时刻的裸高度。理由：
  // 口径卡在画框内只是过渡态 —— detachAnnotations() 的设计前提就是「卡最终
  // 必被 layout() 提到画框右侧外」。若拿含卡的裸高度去判 844，等于逼着
  // buildLogin 为一个注定被移走的临时节点腾地方，那是跟 detachAnnotations
  // 的设计意图直接对着干。
  //
  // 但也不能把这条降级成纯信息输出：真正的内容溢出（比如再补两个字段）
  // 必须在这里就被拦下。所以扣的是「卡自身高 + 它占的那一段 itemSpacing」，
  // 剩下的净高仍照 844 严格判。终态高度另有一条断言在 layout() 之后复核
  //（见「移出口径卡后 login 内容高进一步下降且不溢出」），两条互为交叉验证。
  const body = login.children.find((c) => c.name === '_body');
  check('login 有 _body 容器', !!body);
  if (body) {
    const statusH = login.children[0] ? login.children[0].height : 0;
    const inBodyCards = body.children.filter(
      (c) => c.name.indexOf('_annotation/') === 0
    );
    const cardsH = inBodyCards.reduce(
      (sum, c) => sum + c.height + body.itemSpacing,
      0
    );
    const total = statusH + body.height - cardsH;
    check(
      'login 净内容不溢出 844（状态栏 + body − 待移出的口径卡）',
      total <= CANVAS_H,
      '实测 ' + Math.round(statusH) + ' + ' + Math.round(body.height) +
        ' − ' + Math.round(cardsH) + '（' + inBodyCards.length + ' 张卡）= ' +
        Math.round(total) + ' / 844，余 ' + Math.round(CANVAS_H - total)
    );

    // ⑦ 字段溢出 bug：body 可用宽 = 390 - xl*2 = 342，所有直接子节点不得超
    const innerW = 390 - M.SPACING.xl * 2;
    const tooWide = body.children
      .filter((c) => c.width > innerW + 0.5)
      .map((c) => c.name + '(' + Math.round(c.width) + ')');
    check(
      'login body 内无子节点超出可用宽 ' + innerW,
      tooWide.length === 0,
      tooWide.length ? '超宽：' + tooWide.join(', ') : '全部 ≤ ' + innerW
    );

    // ⑧ 横排行内部也要装得下（图形码行、短信码行）
    for (const rowName of ['_captcha-row', '_code-row']) {
      const row = byName(login, rowName);
      if (!row) {
        check(rowName + ' 存在', false, '未找到');
        continue;
      }
      const sum = row.children.reduce((a, c) => a + c.width, 0) +
        row.itemSpacing * Math.max(0, row.children.length - 1);
      check(
        rowName + ' 内部宽度合计 ≤ ' + innerW,
        sum <= innerW + 0.5,
        '合计 ' + Math.round(sum) + '，子项 ' +
          row.children.map((c) => Math.round(c.width)).join('+')
      );
    }
  }

  // ⑨ PRD §3.4.1 五项补齐，逐项在实跑结果里找得到
  const lt = allText(login);
  const need = [
    ['图形验证码', '图形验证码'],
    ['短信验证码', '短信验证码'],
    ['协议勾选文案', '我已阅读并同意《用户协议》与《隐私政策》'],
    ['自动注册说明', '未注册手机号验证后自动注册'],
    ['密码登录入口', '用密码登录'],
    ['第三方微信', '微信'],
    ['第三方 QQ', 'QQ'],
    ['第三方 Apple', 'Apple'],
    ['slogan 原文', '用就近的资源解决本地的需求'],
  ];
  for (const [label, s] of need) {
    check('login 实跑含「' + label + '」', lt.indexOf(s) >= 0);
  }

  // ⑩ 主按钮：胶囊 + 312 宽
  const mainBtn = byName(login, 'btn/capsule/登录');
  check('login 主按钮走 capsule 变体', !!mainBtn, mainBtn ? mainBtn.name : '未找到');
  if (mainBtn) {
    check(
      'login 主按钮宽 = 312（390 × 80%）',
      Math.round(mainBtn.width) === 312,
      Math.round(mainBtn.width) + 'px'
    );
  }

  // ⑪ 协议勾选默认未勾：checkRow 未勾时 _checkbox 内不该有对勾图标
  const cbx = byName(login, '_checkbox');
  check(
    'login 协议勾选框默认未勾（框内无对勾）',
    cbx !== null && cbx.children.length === 0,
    cbx ? cbx.children.length + ' 个子节点' : '未找到勾选框'
  );

  // ⑫ 第三方三枚必须是 disabled 变体且半透明
  const thirdRow = byName(login, '_third-party');
  if (thirdRow) {
    const allDisabled = thirdRow.children.every(
      (c) => c.name.indexOf('/disabled/') >= 0
    );
    check('login 第三方三枚全走 disabled 变体', allDisabled,
      thirdRow.children.map((c) => c.name).join(', '));
  } else {
    check('login 有 _third-party 行', false, '未找到');
  }

  // ============================================================
  // 八之二、实机验收（2026-08-26）暴露的三类缺陷，各配一条静态断言。
  //
  // 这三条都不是「量尺寸」能发现的，靠的是「查属性 / 查取色」，故与上面
  // 的布局断言分开。共同点是：错了画面照样生成、看着也正常，只有对着
  // PRD 逐条核或在实机上量才现形 —— 正是最需要探针钉住的那一类。
  // ============================================================
  console.log('\n--- 八之二、实机验收补回的三类断言 ---');

  // ① Accent 必须能承载白字（PRD §1.8 的 4.5:1）
  //
  // Accent 的两处用途（「AI 猜」角标、「AI 帮我发」FAB）都是白字压橙底。
  // 原值 #FF8A3D 实测仅 2.345:1，2026-08-26 压深至 #B4531A（5.01:1）。
  // 这条钉住色值本身，防止后来人凭「原来的橙更活泼」把它调回去。
  function lumOf(hex) {
    const v = [1, 3, 5].map((i) => parseInt(hex.substr(i, 2), 16) / 255);
    const f = (x) => (x <= 0.03928 ? x / 12.92 : Math.pow((x + 0.055) / 1.055, 2.4));
    return 0.2126 * f(v[0]) + 0.7152 * f(v[1]) + 0.0722 * f(v[2]);
  }
  const accentHex = (raw.match(/'accent':\s*'(#[0-9A-Fa-f]{6})'/) || [])[1];
  const accentRatio = accentHex ? 1.05 / (lumOf(accentHex) + 0.05) : 0;
  check(
    'Accent 白字对比度 ≥ 4.5:1（PRD §1.8）',
    accentRatio >= 4.5,
    accentHex
      ? accentHex + ' 实测 ' + (Math.round(accentRatio * 100) / 100) + ':1'
      : '未能从源码解析出 accent 色值'
  );

  // ② primary-light 底上禁用 primary 作文字（PRD §1.4.2 表内明文 ❌，4.42:1）
  //
  // 实机在级联选择器第三列抓到唯一一处。PRD 同表给了正确取法 primary-dark
  //（6.70:1）。这条同时钉住 PRD 那句话还在、code.js 照做了两端 —— 只钉一端
  // 的话，顺手改 PRD 就能让断言变绿。
  const prdText = fs.readFileSync(
    path.join(__dirname, '..', 'docs', 'PRD.md'), 'utf8'
  );
  check(
    'PRD 仍禁用「primary 压 primary-light」（下一条的依据）',
    /`primary` 作文字在 primary-light 上[^\n]*4\.42:1[^\n]*❌[^\n]*禁用此组合/.test(prdText),
    'PRD §1.4.2 表内该行仍在'
  );
  check(
    '级联选择器选中项按底色取 primary-dark（不在浅青底上用 primary）',
    /colFills\[c\] === 'color\/primary-light'\s*\n?\s*\?\s*'color\/primary-dark'/.test(raw),
    '已按列区分取色'
  );

  // ③ 可点控件触控区 ≥ 44×44（PRD §1.8）
  //
  // 只查纵向：横向命中区由文案长度决定，PRD 已用同一理由豁免过搜索框的
  // 32 高（§1.4.1「横向命中区宽达 150px 以上，实际可点面积远超 44×44
  // 的等效值」）。故此处断言底部 Tab 单元格与通知铃的**高**达到 44。
  const tabCellH = (raw.match(/box\('_tab-' \+ items\[i\]\[1\][\s\S]{0,120}?h:\s*(\d+)/) || [])[1];
  check(
    '底部 Tab 单元格高 = 44（原 hug 到 41，差 3px）',
    Number(tabCellH) >= 44,
    tabCellH ? '实测 h: ' + tabCellH : '未解析到 _tab- 单元格的 h'
  );
  const bellH = (raw.match(/stack\('_nav-bell',\s*(\d+),\s*(\d+)\)/) || [])[2];
  check(
    '通知铃命中区 = 44×44（图形仍 24，靠 inset 保持视觉位置不变）',
    Number(bellH) >= 44,
    bellH ? '实测 ' + bellH + '×' + bellH : '未解析到 _nav-bell 尺寸'
  );
  check(
    '通知铃内部图标带 inset 补偿（否则图形会随外壳变大而偏移）',
    /var inset = 10;/.test(raw) && /icon\.x = 2 \+ inset;/.test(raw),
    '已按 (44-24)/2 = 10 补偿'
  );

  // ④ 无右侧动作时不建空的 _nav-action 容器
  //
  // 实机查到 5 个宽 0 的 `_nav-action/` 空壳。它们不可见不可点，但会污染
  // FLOW_LINKS 的按名查找与触控区体检。
  check(
    'navBar 无右侧动作时不建空 _nav-action 容器',
    /if \(opt\.right\) \{\s*\n[\s\S]{0,600}?box\('_nav-action\/' \+ opt\.right/.test(raw),
    '已加 if (opt.right) 守卫'
  );

  // ⑤ 分类色深色变体必须能承载白字，且选中态标签必须取它（PRD §1.4.2 / §1.8）
  //
  // 白字压五个分类原色实测只有 2.54–4.23:1（工作 3.68 / 房屋 4.23 / 车辆 2.80 /
  // 生活 2.54 / 服务 3.53），**五类全不达标**。实机上此前只有「房屋」暴露 ——
  // T3 三级树那三屏恰好选中房屋；其余四类被选中时同样违规。这类「只有当前
  // 数据恰好命中的那一支才现形」的错，必须靠遍历全表的断言钉住，靠看画面
  // 一定会漏掉另外四支。
  //
  // 两端都钉：① CATEGORY_DEEP 五个色值本身够深；② 取色处真的用了 -deep。
  // 只钉前者的话，把 fill 改回原色仍然全绿。
  const deepBody = (raw.match(/var CATEGORY_DEEP = \{([\s\S]*?)\};/) || [])[1] || '';
  const deepPairs = [...deepBody.matchAll(/'([\w-]+)':\s*'(#[0-9A-Fa-f]{6})'/g)];
  const deepBad = deepPairs
    .map(([, k, hx]) => ({ k, hx, r: 1.05 / (lumOf(hx) + 0.05) }))
    .filter((x) => x.r < 4.5);
  check(
    '五个 category/*-deep 白字对比度均 ≥ 4.5:1（原色 2.54–4.23 全不达标）',
    deepPairs.length === 5 && deepBad.length === 0,
    deepPairs.length !== 5
      ? '只解析到 ' + deepPairs.length + ' 个深色变体，应为 5 个'
      : deepBad.length
        ? deepBad.map((x) => x.k + ' ' + x.hx + ' ' + (Math.round(x.r * 100) / 100)).join('; ')
        : deepPairs.map((p) => Math.round((1.05 / (lumOf(p[2]) + 0.05)) * 100) / 100).join(' / ')
  );
  check(
    '五个深色变体都会被注册成 Figma 变量（否则取色处静默回退）',
    /for \(key in CATEGORY_DEEP\) all\['category\/' \+ key \+ '-deep'\]/.test(raw),
    'ensureColorVariables 已纳入 CATEGORY_DEEP'
  );
  check(
    'paintOf 的 fallback 表认 -deep 后缀（否则变量缺失时回退成纯黑）',
    /ck\.indexOf\('-deep'\) > 0\s*\n?\s*\?\s*CATEGORY_DEEP\[ck\.replace\('-deep', ''\)\]/.test(raw),
    'fallback 已分支到 CATEGORY_DEEP'
  );
  check(
    '_lv1-cat-* 选中态底色取 -deep（内含白色文字与白色图标）',
    /fill: on \? 'category\/' \+ CAT_LIST\[i\]\[0\] \+ '-deep' : 'color\/background'/.test(raw),
    '已改为深色变体'
  );

  // ============================================================
  // 五之二、像素精修的三条不变量（2026-08-27，条目 [61]）
  //
  // 为什么必须落成断言而不是「改完看图确认」：本轮三处改动全是**结构性**的 ——
  // 改对了画面和改错了画面都可能看着正常（原则 58：结构断言查不出可读性，
  // 反过来「看图」也查不出结构退化）。三条各自钉一件事：
  //  ① 非阶梯间距只许有 TIGHT_GAP 一个出口，且用量锁定 9 处；
  //  ② marker 信息卡四行必须真的同左缘（真跑量像素，不看源码）；
  //  ③ catTreeSheet 的左内缘只许在 sheet 上声明一次。
  // ============================================================
  console.log('\n--- 像素精修不变量（条目 [61]）---');

  // ① 间距裸值收口：bindNum() 对不在 SPACING 阶梯上的值是**静默不绑变量也不
  // 报错**（code.js:672 `if (!name) return false;`）。也就是说随手写个
  // gap: 3 会让那个容器悄悄脱离 Variables 而画面毫无异样，是最难人工发现的
  // 一类漂移。本轮把 9 处字面 2 收成具名常量 TIGHT_GAP 并写明豁免理由，
  // 这条断言负责让「新增非阶梯裸值」当场变红。
  //
  // 两端都钉：常量在不在（含豁免说明），以及全文有没有绕过它的裸值。
  //
  // ⚠️ 首跑踩到的坑：直接拿 raw 扫会把**注释里的反例文字**当成真代码。
  // code.js:2981 与 :3218 两处注释恰恰在解释「为什么不用 padLeft: 36 /
  // padLeft: 26」，被正则原样抓出来报了两处假违规。所以扫描前必须剥掉注释。
  // 不能用 raw.replace(/\/\/.*$/gm, '') 这种糙办法：文件里有
  // 'http://www.w3.org/2000/svg'（:1030）这类字符串，会被从 // 处截断。
  /**
   * 剥除 JS 源码中的行注释与块注释，保留字符串字面量原样。
   *
   * 逐字符扫描并跟踪三种状态（单引号串 / 双引号串 / 模板串），只在「不在字符串
   * 内」时才认 // 与 /*。用等长空白替换注释内容而不是直接删除，这样剥后文本与
   * 原文**行号一一对应**，报错位置仍可直接定位到 code.js 的真实行。
   *
   * @param {string} src JS 源码
   * @returns {string} 注释被替换为空白后的等长源码
   */
  const stripJsComments = (src) => {
    let out = '';
    let i = 0;
    let quote = null;      // 当前所处字符串的引号字符，null 表示不在字符串内
    while (i < src.length) {
      const ch = src[i];
      const next = src[i + 1];
      if (quote) {
        out += ch;
        if (ch === '\\') { out += next === undefined ? '' : next; i += 2; continue; }
        if (ch === quote) quote = null;
        i += 1;
        continue;
      }
      if (ch === '\'' || ch === '"' || ch === '`') { quote = ch; out += ch; i += 1; continue; }
      if (ch === '/' && next === '/') {
        while (i < src.length && src[i] !== '\n') { out += ' '; i += 1; }
        continue;
      }
      if (ch === '/' && next === '*') {
        while (i < src.length && !(src[i] === '*' && src[i + 1] === '/')) {
          out += src[i] === '\n' ? '\n' : ' ';   // 换行原样保留，行号才不漂
          i += 1;
        }
        out += '  ';
        i += 2;
        continue;
      }
      out += ch;
      i += 1;
    }
    return out;
  };
  const code = stripJsComments(raw);

  const spacingStep = new Set(Object.values(M.SPACING));
  check(
    'TIGHT_GAP 常量存在且写明豁免理由（唯一获准的非阶梯间距值 = 2）',
    /唯一获准豁免值[\s\S]{0,900}?var TIGHT_GAP = 2;/.test(raw) && M.SPACING.xs === 4,
    'TIGHT_GAP = 2；SPACING 最小阶 xs = ' + M.SPACING.xs
  );
  // 扫 box() 调用里的间距字面量：gap / padTop / padBottom / padLeft /
  // padRight / pad 六个键，凡直接写数字且不在阶梯上的一律列出。
  // 已声明豁免的两类不计入：TIGHT_GAP（具名）与 0（gap: 0 走 falsy 分支，
  // box():779 本就不尝试绑定，见 code.js 注释）。
  const bareSpacing = [];
  const spacingKeyRe = /\b(gap|pad|padTop|padBottom|padLeft|padRight):\s*(\d+)\b/g;
  for (const m of code.matchAll(spacingKeyRe)) {
    const val = Number(m[2]);
    if (val === 0) continue;                 // gap:0 / pad:0 不绑，已豁免
    if (spacingStep.has(val)) continue;      // 阶梯上的值（直写数字也无妨）
    const lineNo = code.slice(0, m.index).split('\n').length;
    bareSpacing.push(m[1] + ':' + val + '@L' + lineNo);
  }
  check(
    '间距字面量不绕过 SPACING 阶梯与 TIGHT_GAP（新增非阶梯裸值会静默脱离 Variables）',
    bareSpacing.length === 0,
    bareSpacing.length ? '发现 ' + bareSpacing.length + ' 处：' + bareSpacing.join(', ') : '零裸值'
  );
  // 用量锁定 9 处：豁免的前提是「只用于单元内两行贴合」这一窄用途。
  // 若哪天涨到十几处，说明它已被当成通用间距在用，豁免理由就不成立了 ——
  // 那时该重新评审，而不是让数字默默变大。
  //
  // ⚠️ 口径必须是「调用处数」而非「字符出现次数」：_radius-<档>（code.js:2826）
  // 与 _ai-tag（:4372）两处各在 padTop + padBottom 里各用一次，字符数为 11 而
  // 调用处只有 9。首跑用字符数得 11、误判为超量。改成按行去重计数 ——
  // 一处 box() 调用写在一行内，行数即调用处数。
  const tightLines = code
    .split('\n')
    .map((ln, idx) => ({ ln, no: idx + 1 }))
    .filter((x) => x.ln.indexOf('TIGHT_GAP') >= 0 && !/var TIGHT_GAP\s*=/.test(x.ln));
  check(
    'TIGHT_GAP 用量锁定 9 处（涨了说明它被当通用间距用，豁免理由需重新评审）',
    tightLines.length === 9,
    '实测 ' + tightLines.length + ' 处调用（行号 ' + tightLines.map((x) => x.no).join('/') + '）'
  );

  // ② marker 信息卡四行同左缘：真跑一遍量绝对 x，不查源码。
  //
  // 改前实测 36 / 0 / 18 / 0（标题被圆标推开、摘要挂在卡上、完整度被色点
  // 推开、动作行又回到 0）。四条参差的起笔线会让同一层级读成多个层级。
  // 量像素而不是查「有没有写 body 容器」：写了容器但忘了把某行挂进去，
  // 源码断言全绿而画面照旧参差。
  {
    const card = M.markerInfoCard('cat-house', '房屋', '朝南两居转租',
      '2200 元/月 · 押一付一 · 8 月起租', 'resource', 'yellow');
    // mock 不做真实坐标分配（x 恒为 0），故改量「文字节点到卡左缘之间累计的
    // padding + 前置兄弟宽度」这一确定性口径 —— 与 Figma 的实际左缘等价，
    // 且不依赖 mock 的坐标分配能力。
    const offsetOf = (node) => {
      let off = 0;
      let cur = node;
      while (cur && cur !== card) {
        const p = cur.parent;
        if (!p) break;
        off += p.paddingLeft;
        if (p.layoutMode === 'HORIZONTAL') {
          const idx = p.children.indexOf(cur);
          for (let i = 0; i < idx; i++) off += p.children[i].width + p.itemSpacing;
        }
        cur = p;
      }
      return off;
    };
    // ⚠️ 口径收窄（首跑教训）：直接量「卡内所有 TEXT」会把**行内元素**也算进来，
    // 首跑得到 48 / 66 / 121 三个值 —— 66 是完整度行里色点之后的文案
    // （48 + 10 色点 + 8 间距），121 是动作行里 spacer 之后的「查看详情 ›」。
    // 这两个本就该在行内偏右，不属于「行首起笔线」。所以要量的是
    // **_mi-body 每一行的起笔位置**，而不是每个文本的位置。
    const bodyCol = byName(card, '_mi-body');
    const rowOffs = [...new Set(bodyCol.children.map((r) => offsetOf(r)))];
    check(
      'marker 信息卡各行起笔线一致（改前为 36/0/18/0 四条参差起笔线）',
      bodyCol.children.length >= 5 && rowOffs.length === 1,
      bodyCol.children.length + ' 行，起笔线取值 ' + rowOffs.join(' / ')
    );
    // 同左缘也可能是「全都 0」（把圆标删了就成立），故再钉住基准值：
    // 起笔线 = 卡自身内缘 SPACING.md + 圆标宽 28 + SPACING.sm，
    // 即「正文左缘对齐到圆标右边缘」。首跑期望值漏算了卡自身的 pad。
    const expectLead = M.SPACING.md + 28 + M.SPACING.sm;
    check(
      'marker 卡起笔线 = 卡内缘 md + 圆标宽 28 + SPACING.sm（对齐圆标右缘，非退化为 0）',
      rowOffs.length === 1 && rowOffs[0] === expectLead,
      '实测 ' + rowOffs[0] + '，期望 ' + expectLead
    );
    // 行首就是文本的那些行（标题块 / 摘要 / 动作行），文本不得被行内 padding
    // 再推开一次 —— 否则「行容器对齐了、字还是参差」。
    // 取法：从每一行沿**长子**一路下钻，钻到的第一个节点若是 TEXT 就纳入比对；
    // 若是色点那样的图形（完整度行），说明该行首元素本就不是文字，跳过。
    const firstLeafOf = (row) => {
      let cur = row;
      while (cur.children && cur.children.length) cur = cur.children[0];
      return cur;
    };
    const leadTextOffs = [...new Set(
      bodyCol.children
        .map(firstLeafOf)
        .filter((n) => n.type === 'TEXT')
        .map((t) => offsetOf(t))
    )];
    check(
      'marker 卡行首文本未被行内 padding 二次推开（行对齐了字也必须对齐）',
      leadTextOffs.length === 1 && leadTextOffs[0] === expectLead,
      '行首文本左缘 ' + leadTextOffs.join(' / ') + '，期望 ' + expectLead
    );
    // 分隔线与动作行必须跟右列同宽，否则「同左缘」是靠缩窄内容换来的
    const divider = byName(card, '_mi-divider');
    check(
      'marker 卡分隔线与右列等宽（同左缘不是靠缩窄内容换来的）',
      !!divider && !!bodyCol && Math.round(divider.width) === Math.round(bodyCol.width),
      divider && bodyCol ? divider.width + ' vs ' + bodyCol.width : '取不到节点'
    );
  }

  // ③ catTreeSheet 左内缘单一来源：改前 padLeft: SPACING.lg 在四个子容器里
  // 各写一遍，任一处漏写即整行错位，而错位在结构断言里零征兆。
  // 这条钉「sheet 自己有左右内缘」+「子容器不再各自声明」两端。
  {
    const sheetBody = (code.match(/function catTreeSheet[\s\S]*?\n\}/) || [''])[0];
    const sheetDecl = (sheetBody.match(/box\('_cat-tree-sheet'[\s\S]*?\}\);/) || [''])[0];
    check(
      'catTreeSheet 左右内缘声明在弹层自身上（单一来源）',
      /padLeft: SPACING\.lg, padRight: SPACING\.lg/.test(sheetDecl),
      sheetDecl ? '已提到 _cat-tree-sheet' : '取不到弹层声明'
    );
    // ⚠️ 两处首跑误判都出在取样窗口上：
    // ① 旧写法用 [\s\S]{0,200}? 定长窗口，会**跨过本次 box() 调用的结尾**匹配到
    //    紧随其后的下一个 box() 的 padLeft（_sheet-action 被 _sheet-reset 连坐）。
    //    改为只截到本次调用的 `});` 为止。
    // ② _lv1-<cat> 的 padLeft: SPACING.sm 是**胶囊自身的左内边距**（它是个独立
    //    的圆角标签，与「弹层左内缘」不是同一件事），和 _tree-lv3 的层级缩进
    //    同属刻意差异，一并列入豁免。
    const OWN_PADDING_OK = ['_cat-tree-sheet', '_tree-lv3', '_sheet-reset', '_sheet-confirm'];
    const childPadLeft = [...sheetBody.matchAll(/box\('(_[\w-]+)'[\s\S]*?\}\);/g)]
      .filter((m) => /padLeft:/.test(m[0]))
      .map((m) => m[1])
      .filter((nm) => OWN_PADDING_OK.indexOf(nm) < 0 && nm.indexOf('_lv1-') !== 0);
    check(
      'catTreeSheet 子容器不再各自重复声明 padLeft（层级缩进与胶囊自身内边距例外）',
      childPadLeft.length === 0,
      childPadLeft.length ? '仍有：' + childPadLeft.join(', ') : '四处重复声明已消除'
    );
  }

  // ④ 树内说明文字与勾选项同左缘：走 listHintRow 的等宽占位实现。
  // 若有人把它改回 text(...)，左缘立刻差 CHECKBOX_SIZE + SPACING.sm。
  {
    const hint = M.listHintRow('二级类目（按最近 7 天发布数排序）');
    const row = M.checkRow('房屋租赁', false, 'color/primary', false);
    const offIn = (container) => {
      const t = container.findOne((n) => n.type === 'TEXT');
      const idx = container.children.indexOf(
        container.children.find((c) => c === t || c.findOne?.((n) => n === t))
      );
      let off = container.paddingLeft;
      for (let i = 0; i < idx; i++) off += container.children[i].width + container.itemSpacing;
      return off;
    };
    check(
      '树内说明文字与 checkRow 标签同左缘（改前差 26px，读成两个层级）',
      offIn(hint) === offIn(row),
      '说明 ' + offIn(hint) + ' / 勾选项 ' + offIn(row)
    );
  }

  // ============================================================
  // 六、layout 移出口径卡：真跑一遍，验画框内确实清零
  // ============================================================
  console.log('\n=== layout 移出口径卡实跑 ===');
  const page = figma.createPage();
  const frames = [M.buildSplash(), M.buildLogin()];
  const beforeTotal = frames.reduce(
    (a, f) => a + f.findAll((n) => n.name.indexOf('_annotation/') === 0).length,
    0
  );
  // 必须在 layout() 之前采样：layout 会把卡全部提到画框外，之后再数逐框数恒为 0
  const cardsPerFrame = frames.map(
    (f) => f.findAll((n) => n.name.indexOf('_annotation/') === 0).length
  );
  M.layout(page, frames, 5, 0);
  const afterInFrames = frames.reduce(
    (a, f) => a + f.findAll((n) => n.name.indexOf('_annotation/') === 0).length,
    0
  );
  const onPage = page.children.filter(
    (n) => n.name.indexOf('_annotation/') === 0
  ).length;

  // 基线数改为逐画框判定（2026-08-27，条目 [51] 第 6 步 / I5）：
  // 原先写死 beforeTotal === 2，I5 给登录页主按钮补挂 motion/press 档标注后
  // 变成 3，断言即失败。但不能简单把 2 改成 3 —— 那只是把一个魔数换成另一个，
  // 下次再加一张还得再改，且「总数对了」并不说明卡挂在了该挂的画框上。
  // 逐画框判定同时守住两件事：卡数没少（漏挂 press 档会失败）、卡没跑错画框。
  check('layout 前 splash 画框内 1 张口径卡', cardsPerFrame[0] === 1,
    cardsPerFrame[0] + ' 张');
  check('layout 前 login 画框内 2 张（页面口径 + motion/press 交互档）',
    cardsPerFrame[1] === 2, cardsPerFrame[1] + ' 张');
  check('layout 后画框内口径卡清零', afterInFrames === 0, afterInFrames + ' 张残留');
  check('layout 后口径卡挂到了 page 上', onPage === beforeTotal,
    onPage + ' / ' + beforeTotal);

  // 移出后 opacity 必须复位
  const opacities = page.children
    .filter((n) => n.name.indexOf('_annotation/') === 0)
    .map((n) => n.opacity);
  check('移出的口径卡 opacity 全为 1', opacities.every((o) => o === 1),
    JSON.stringify(opacities));

  // 落点必须在画框右侧、且不与下一列画框重叠
  const cards = page.children.filter((n) => n.name.indexOf('_annotation/') === 0);
  if (cards.length) {
    const f0 = frames[0];
    const c0 = cards.find((c) => c.x >= f0.x + f0.width);
    check('口径卡落在画框右侧外部', !!c0,
      c0 ? 'x=' + Math.round(c0.x) + ' 画框右缘=' + Math.round(f0.x + f0.width) : '无一张在右侧');

    // 逐列判定，不能跨列取 max：每张卡只可能压到「它自己那一列的下一列」。
    // 首版用 Math.max(所有卡右缘) 对比 frames[1].x，把第 2 列的卡也拿去跟
    // 第 2 列自己的左缘比，必然误报 —— 探针自身的错。
    const overlaps = [];
    for (const f of frames) {
      const right = f.x + f.width;
      // 归属本画框的卡：落在本画框右缘之后、下一列画框左缘之前的区间起点
      const mine = cards.filter((c) => Math.abs(c.x - (right + 24)) < 1);
      if (!mine.length) continue;
      const nextLeft = f.x + f.width + 320;   // gapX
      const maxRight = Math.max(...mine.map((c) => c.x + c.width));
      if (maxRight > nextLeft) {
        overlaps.push(f.name.slice(0, 12) + ' 卡右缘 ' + Math.round(maxRight) +
          ' > 下列左缘 ' + Math.round(nextLeft));
      }
    }
    check(
      '口径卡未压到下一列画框（逐列判定）',
      overlaps.length === 0,
      overlaps.length ? overlaps.join('; ') : '各列均在 gap 内'
    );
  }

  // 移出后 _body 高度应下降（口径卡不再占位），且仍不溢出
  const login2 = frames[1];
  const body2 = login2.children.find((c) => c.name === '_body');
  if (body2) {
    const total2 = (login2.children[0] ? login2.children[0].height : 0) + body2.height;
    check(
      '移出口径卡后 login 内容高进一步下降且不溢出',
      total2 <= CANVAS_H,
      '实测 ' + Math.round(total2) + ' / 844，余 ' + Math.round(CANVAS_H - total2)
    );
  }

  // ============================================================
  // 七、反向用例：确认上面的断言不是永真
  // ============================================================
  console.log('\n--- 反向用例（确认断言不是永真） ---');

  // 造一个内容超高的页面，验「溢出断言」真会报
  const fake = M.buildLogin();
  const fbody = fake.children.find((c) => c.name === '_body');
  for (let i = 0; i < 20; i++) {
    fbody.appendChild(M.field('填充' + i, '占位', 342));
  }
  const fakeTotal = (fake.children[0] ? fake.children[0].height : 0) + fbody.height;
  check(
    '[反向] 塞 20 个字段后溢出断言确实触发',
    fakeTotal > CANVAS_H,
    '实测 ' + Math.round(fakeTotal) + ' > 844'
  );

  // 造一个超宽子节点，验「超宽断言」真会报
  const fake2 = M.buildLogin();
  const f2body = fake2.children.find((c) => c.name === '_body');
  f2body.appendChild(M.field('超宽', '占位', 999));
  const innerW2 = 390 - M.SPACING.xl * 2;
  const over = f2body.children.filter((c) => c.width > innerW2 + 0.5);
  check(
    '[反向] 塞 999 宽字段后超宽断言确实触发',
    over.length > 0,
    '检出 ' + over.length + ' 个超宽'
  );

  // 验档位断言：传 40px 应落 mini 档（结构只有 3 图元）
  const miniSym = M.duckSymbol(40);
  check(
    '[反向] duckSymbol(40) 应落 mini 档 3 图元（证明档位断言有区分力）',
    miniSym.name === '_duck-symbol-mini' && miniSym.children.length === 3,
    miniSym.name + ' / ' + miniSym.children.length + ' 图元'
  );

  // 验勾选断言：checked=true 时框内应有对勾
  const checkedRow = M.checkRow('测试', true, 'color/primary', true);
  const checkedBox = byName(checkedRow, '_checkbox');
  check(
    '[反向] checkRow(checked=true) 框内应有对勾（证明未勾断言有区分力）',
    checkedBox !== null && checkedBox.children.length > 0,
    checkedBox ? checkedBox.children.length + ' 个子节点' : 'n/a'
  );

  // ============================================================
  // 八、全批次回归：box() 轴向修复是全局改动，必须把全部画框真跑一遍
  //
  // 为什么非做不可：本轮改的是 box() 对 HORIZONTAL 的轴向映射，凡是
  // 「横排 + 传了 w」的容器行为都变了 —— _seg-tab / _check-row / _tags /
  // _third-party / btn/* / _nav-* 全在射程内。只验 splash 与 login 等于
  // 拿两页给全局改动背书，改坏了别的页当场看不出来。
  //
  // 判定标准只取三条【机械可判定】的：
  // ① 画框自身尺寸不被内容顶变形（screen() 建的都是 FIXED 390×844）；
  // ② 画框内所有横排容器的子项宽度合计不超其可用宽（轴向错的直接症状）；
  // ③ layout() 之后画框内不残留口径卡。
  // 观感（配色/字号/留白是否好看）不在此列，那要实机看。
  // ============================================================
  console.log('\n=== 全批次回归（box 轴向修复的影响面）===');

  // 清掉前面第六节 layout 实跑留在 mock 文档里的临时页。
  //
  // 2026-08-27：这是探针自污染。第六节 figma.createPage() 建了一页并往里放了
  // buildSplash/buildLogin 的产物，页名为空、也没人清。批次 5 的
  // indexMainFrames 扫的是 figma.root.children 全部页面，于是把那页里的
  // login-screen 当成真页收进索引；它与 proto 页的 home-screen 不同页，
  // 触发 batchFlow 的「跨 Page 无法跳转」守卫，唯一那条登录跳转被 skip。
  // 报出来的「reactions=0」看着像画面 bug，实际是我的临时页在捣鬼。
  //
  // 只删「非批次生成」的页：批次自己会用 ensurePage 幂等复用 PAGE_NAMES 的页。
  const keepPages = [M.PAGE_NAMES.setup, M.PAGE_NAMES.proto];
  for (const p of figma.root.children.slice()) {
    if (keepPages.indexOf(p.name) === -1) {
      const i = figma.root.children.indexOf(p);
      if (i >= 0) figma.root.children.splice(i, 1);
    }
  }

  const batches = [
    ['批次 1 setup', M.batchSetup],
    ['批次 2 map', M.batchMap],
    ['批次 3 core', M.batchCore],
    ['批次 4 modal', M.batchModal],
    ['批次 5 flow', M.batchFlow]
  ];

  let allFrames = [];
  // 批次的返回消息也要留存下来供断言查：批次 5 把连线失败收进 skipped 后
  // 只在这个字符串里留一行文字，不看它就等于不知道有几条断链（2026-08-27）。
  const batchMsg = {};
  for (const [label, fn] of batches) {
    if (typeof fn !== 'function') {
      check(label + ' 入口可调用', false, '未导出或不是函数');
      continue;
    }
    let err = null;
    try {
      batchMsg[label] = String(await fn());
    } catch (e) {
      err = e;
    }
    check(label + ' 跑通不抛异常', err === null,
      err ? String(err && err.stack || err).split('\n').slice(0, 4).join(' | ') : '正常返回');
    if (err) continue;
    // 收集本批次落到画布上的所有画框（含 Section 里的）。
    //
    // 必须排掉 `_annotation/`、`board/`、`_components`：口径卡被 layout() 提出
    // 画框后就直接挂在 page / Section 上，它本身也是 FRAME，不过滤会被当成
    //「画框变形」报一堆假失败（探针自身的错，首跑就撞上了）；批次 1 的规格板与
    // component master 宿主容器宽高本就由内容撑开，从来不是 390×844。
    const isScreenFrame = (n) =>
      n.type === 'FRAME' &&
      n.name.indexOf('_annotation/') !== 0 &&
      n.name.indexOf('board/') !== 0 &&
      n.name.indexOf('_components') !== 0;
    const got = [];
    for (const pg of figma.root.children) {
      for (const top of pg.children) {
        if (isScreenFrame(top)) got.push({ batch: label, frame: top, host: pg });
        else if (top.type === 'SECTION') {
          for (const c of top.children) {
            if (isScreenFrame(c)) got.push({ batch: label, frame: c, host: top });
          }
        }
      }
    }
    allFrames = got;

    // ① 画框不被内容顶变形
    const deformed = got
      .filter((g) => Math.round(g.frame.width) !== 390 || Math.round(g.frame.height) !== 844)
      .map((g) => g.frame.name + '(' + Math.round(g.frame.width) + '×' + Math.round(g.frame.height) + ')');
    check(
      label + ' 画框未被内容顶变形（应全为 390×844）',
      deformed.length === 0,
      got.length + ' 个画框' + (deformed.length ? '，变形：' + deformed.slice(0, 6).join(', ') : '，全部合规')
    );

    // ② 横排容器子项宽度合计不得超其可用宽 —— 轴向错的直接症状。
    //
    // 只判「宽是 FIXED」的容器（2026-08-26 实机验收后收窄口径）：
    // AUTO 宽容器的宽度本就由内容决定，拿子项累加去比它自己的宽没有意义 ——
    // 实机上 _mi-head（AUTO，28 宽）、_mi-actions（AUTO，56 宽）就是这样被
    // 误报的，它们的父级另有 clip 与固定宽约束，不是真溢出。
    const rowOver = [];
    for (const g of got) {
      const rows = g.frame.findAll(
        (n) => n.layoutMode === 'HORIZONTAL' &&
               n.children.length > 0 &&
               n.primaryAxisSizingMode === 'FIXED'
      );
      for (const r of rows) {
        const kids = r.children.filter((c) => c.layoutPositioning !== 'ABSOLUTE');
        if (kids.length === 0) continue;
        // 有 layoutGrow 的子项会被 Auto Layout 压缩到剩余空间，不构成溢出 ——
        // 除非容器设了 SPACE_BETWEEN 使 grow 失效（见下面 ⑤ 那条断言）。
        if (kids.some((c) => c.layoutGrow > 0) &&
            r.primaryAxisAlignItems !== 'SPACE_BETWEEN') continue;
        let sum = kids.reduce((a, c) => a + c.width, 0);
        sum += r.itemSpacing * (kids.length - 1) + r.paddingLeft + r.paddingRight;
        if (sum > r.width + 0.5) {
          rowOver.push(
            g.frame.name.slice(0, 14) + '/' + r.name + ' 合计 ' +
            Math.round(sum) + ' > 容器 ' + Math.round(r.width)
          );
        }
      }
    }
    check(
      label + ' 横排容器内容宽未溢出容器',
      rowOver.length === 0,
      rowOver.length ? '溢出 ' + rowOver.length + ' 处：' + rowOver.slice(0, 5).join('; ') : '全部合规'
    );

    // ⑥ 不得产出空文本节点（2026-08-26 第 5 轮实机验收后补）。
    //
    // 实机在 profile / settings 查到 4 个 characters === "" 、宽 0 的 TEXT，
    // 出自 listRow() 的 `text(value || '')` —— 无右值的条目照样建文本节点。
    // 与上一轮修掉的 `_nav-action/` 空壳是同一类：不可见、不影响观感，但会
    // 让图层树多出名为「Text」的废节点，交付给开发时须逐个确认才知是废的。
    //
    // 判据用「文案为空」而不是「宽为 0」：宽 0 是症状，空文案是成因，且
    // 图形节点合法地可以有 0 宽（分隔线），拿宽度判会误报。
    const emptyTexts = [];
    for (const g of got) {
      for (const t of g.frame.findAll((n) => n.type === 'TEXT' && n.characters === '')) {
        emptyTexts.push(g.frame.name.slice(0, 18) + '/' + t.parent.name);
      }
    }
    check(
      label + ' 无空文本节点（空文案不建 TEXT，避免废节点污染图层树）',
      emptyTexts.length === 0,
      emptyTexts.length
        ? emptyTexts.length + ' 个空文本：' + emptyTexts.slice(0, 5).join('; ')
        : '全部合规'
    );

    // ⑤ SPACE_BETWEEN 不得与 layoutGrow 同设。
    //
    // 这条是实机验收（2026-08-26）抓出、离线原理上抓不到的一类错，必须靠
    // 静态特征守：Figma 里 SPACE_BETWEEN 靠「均分剩余空间」推开两端，
    // layoutGrow 要「吃掉剩余空间」，两者同设时以 SPACE_BETWEEN 为准，
    // grow 静默失效。实机后果是 25 个页面的 _nav-bar 一起溢出 24px
    //（搜索框停在 274 而非被压到 250）。
    //
    // 为什么不靠「量宽度」发现它：mock 的 Auto Layout 不实现 grow 与
    // SPACE_BETWEEN 的相互作用，离线量出来的宽永远是「理想值」，这条溢出
    // 在离线永远看不见。所以这里改为直接断言这两个属性不共存 —— 这是
    // 静态特征，不依赖 mock 的布局精度。
    const conflict = [];
    for (const g of got) {
      const rows = g.frame.findAll(
        (n) => n.layoutMode !== 'NONE' &&
               n.primaryAxisAlignItems === 'SPACE_BETWEEN' &&
               n.children.some((c) => c.layoutGrow > 0)
      );
      for (const r of rows) {
        conflict.push(g.frame.name.slice(0, 14) + '/' + r.name);
      }
    }
    check(
      label + ' 无 SPACE_BETWEEN 与 layoutGrow 同设（后者会静默失效）',
      conflict.length === 0,
      conflict.length
        ? conflict.length + ' 处冲突：' + conflict.slice(0, 5).join('; ')
        : '全部合规'
    );

    // ③ 横排容器的高不得被无谓钉死后留出大片空白。
    //
    // 这条是实机验收（2026-08-26）补回来的缺口：离线探针原先只查「内容宽是否
    // 溢出容器」，查不出「容器高被钉死成 100 而内容只有 45」。而后者正是旧
    // box() 轴向 bug 的另一半症状 —— 传 w 时旧代码把交叉轴（横排的高）设成
    // FIXED，Figma createFrame 默认高 100，于是 _primary-row / _third-title /
    // _third-party 三行各撑出 100 高、内容仅 45/13/45，多出 165px，
    // 直接把 login 顶到 943 > 844。
    //
    // 判据只认「高恰好等于 createFrame 默认值 100」这一个特征，不用「空转
    // 超过 N px」的模糊阈值。原因是首版用了 24px 容差，结果把一批**故意的
    // 固定行高**全报成失败：_status-bar 高 44 而文字仅 16、_captcha-image
    // 高 44、_nav-bar 高 48 —— 这些是设计上就该留白的行高，不是 bug。
    // 阈值判定在这里区分不出「设计留白」与「默认值残留」，而 100 这个数
    // 能：它是 Figma createFrame 的默认高，横排容器出现它必然意味着
    // 「代码没打算设高，却被 FIXED 钉住了默认值」。
    //
    // 反过来说，若将来真有一处横排容器就想设成 100 高，这条会误报 ——
    // 那时应显式传 h:100，并在此处放行该节点名，而不是放宽判据。
    const stuckRows = [];
    for (const g of got) {
      const rows = g.frame.findAll(
        (n) => n.layoutMode === 'HORIZONTAL' &&
               n.children.length > 0 &&
               n.counterAxisSizingMode === 'FIXED' &&
               Math.abs(n.height - 100) < 0.5
      );
      for (const r of rows) {
        const kids = r.children.filter((c) => c.layoutPositioning !== 'ABSOLUTE');
        if (kids.length === 0) continue;
        const contentH = Math.max(...kids.map((c) => c.height)) +
          r.paddingTop + r.paddingBottom;
        stuckRows.push(
          g.frame.name.slice(0, 14) + '/' + r.name +
          ' 高卡在 createFrame 默认 100，内容仅 ' + Math.round(contentH)
        );
      }
    }
    check(
      label + ' 横排容器高未卡在 createFrame 默认 100',
      stuckRows.length === 0,
      stuckRows.length
        ? stuckRows.length + ' 处：' + stuckRows.slice(0, 5).join('; ')
        : '全部合规'
    );

    // ④ layout() 之后画框内不得残留口径卡
    const leftover = got.reduce(
      (a, g) => a + g.frame.findAll((n) => n.name.indexOf('_annotation/') === 0).length,
      0
    );
    check(label + ' 画框内无残留口径卡', leftover === 0, leftover + ' 张残留');

    // ⑬ 底部 Tab 一律贴在画框最下沿（2026-08-30 条目 [70] 第三段）。
    //
    // 为什么必须扫全部批次而不是点名某页：Tab 是全局导航，实机横扫 24 处落点
    // 只有 list 一处悬在 693px（离底 151px）—— 上一轮修 profile 时没顺手扫其余
    // 12 处 bottomTab() 调用，正是原则 110「同类缺陷必须全量横扫」的又一次命中。
    // 点名式断言下一次新增页面照样会漏，故改为「凡出现 Tab 的画框都验」。
    //
    // 判据用「Tab 是其父级的最后一个子节点，且父链上每一层都排在末位」：
    // 离线 mock 不实现 layoutGrow 的实际撑开效果（见 ⑤ 那条断言的说明），拿
    // 绝对坐标去量底边在离线永远是理想值，量不出真问题。而「排末位」是静态
    // 结构特征 —— 配合 grow=1 的 spacer 在前，就等价于贴底。
    const tabFloat = [];
    for (const g of got) {
      const tabs = g.frame.findAll(
        (n) => n.name.indexOf('bottom-tab') >= 0 && n.parent
      );
      for (const t of tabs) {
        let cur = t;
        while (cur.parent && cur.parent !== g.frame.parent) {
          const sibs = cur.parent.children.filter((c) => c.layoutPositioning !== 'ABSOLUTE');
          if (sibs.indexOf(cur) !== sibs.length - 1) {
            tabFloat.push(g.frame.name.slice(0, 22) + '：' + cur.name + ' 非 '
              + cur.parent.name + ' 末位');
            break;
          }
          if (cur.parent === g.frame) break;
          cur = cur.parent;
        }
        // 贴底还要求「内容真能到底」，否则 Tab 排末位也只是悬在内容尽头。
        // 两条路任一即可，因为稿子里确实有两种正当写法：
        // ① 前面有 grow>0 的兄弟把它顶下去（profile 的 _spacer、trust 的 _body）；
        // ② 前面兄弟的固定高合计已填满画框（home 系列的 _map-canvas 是固定高
        //    stack，layoutMode 为 NONE 不可能有 grow）。
        // 只认 ① 会把 home 系列 22 个画框全报成失败（首跑实测），那是判据错。
        const sibs = t.parent.children.filter((c) => c.layoutPositioning !== 'ABSOLUTE');
        const idx = sibs.indexOf(t);
        const before = sibs.slice(0, idx);
        const hasGrow = before.some((c) => c.layoutGrow > 0);
        const filledH = before.reduce((a, c) => a + c.height, 0) + t.height
          + t.parent.itemSpacing * Math.max(0, sibs.length - 1)
          + t.parent.paddingTop + t.parent.paddingBottom;
        if (!hasGrow && filledH < t.parent.height - 0.5) {
          tabFloat.push(g.frame.name.slice(0, 22) + '：Tab 前既无 grow>0 兄弟、'
            + '内容也只到 ' + Math.round(filledH) + ' < ' + Math.round(t.parent.height));
        }
      }
    }
    check(
      label + ' 底部 Tab 贴画框下沿（排末位 + 前有 grow 兄弟；实机曾有 list 页悬空 151px）',
      tabFloat.length === 0,
      tabFloat.length ? tabFloat.length + ' 处：' + tabFloat.slice(0, 5).join('; ') : '全部贴底'
    );

    // ⑭ 凡设了 layoutGrow 的节点，其父容器主轴方向不得是 hug（2026-08-30 条目 [71]）。
    //
    // 这是本项目第三次踩同一个坑，也是唯一能机械拦住它的判据：
    //   · :1514 searchBar 注释早写明「宽度既然由内容决定，layoutGrow 就拉不动它」；
    //   · notifyRow(:3380)、card(:1717) 都在容器上显式写了 w；
    //   · 而 certRow 漏了 —— 容器 hug、内部 main.layoutGrow = 1 无剩余宽可分，
    //     main 塌成 0 宽，三行文字与右端动作坐标重合。实机渲染图上三行全部压字，
    //     是条目 [71] 唯一的阻断级缺陷。
    //
    // 为什么此前 227 项全绿却没拦住：所有既有断言量的都是「节点自身的几何与
    // 层级」，而这里错的是**父子两级属性的组合**（父 hug × 子 grow）。单看任一
    // 级都合法，必须成对检查 —— 这类「组合非法」的缺陷是探针的结构性盲区。
    //
    // 判据只查主轴：横排父级看宽度、纵排父级看高度。副轴的 hug 与 grow 无关。
    //
    // 用 primaryAxisSizingMode === 'AUTO' 判 hug，这是 box() 真会写的字段
    // （code.js:783：横排传 w 则 FIXED，不传则 AUTO）。两条走不通的路都试过：
    //   ① 读 layoutSizingHorizontal —— mock 里初值恒为 'HUG'（:187），box() 传 w
    //      不改它，据此判定把 _nav-search 等 77–102 处正常节点全报失败；
    //   ② 量「父宽 - 固定子项宽是否还有剩余」—— hug 父级的宽本就等于内容合计，
    //      grow 子节点的内容宽也计入了父宽，算下来恒有剩余，反向验证时一个都报
    //      不出（撤掉 certRow 的 w 后仍 237 全绿，是假的绿）。
    // 这两次误判都印证原则 117：断言首跑的结果要先对照「缺陷全集应该有多大」。
    //
    // 一个必须放行的例外：父级自己也 grow（且与祖父同向）时，它的主轴尺寸由祖父
    // 供给，AUTO 只是「没显式写死」而非真 hug。detail/publish/contact 三页的
    // _body 正是此形：box(...,'VERTICAL',{w:CANVAS.w}) 只传 w，纵排下 w 走
    // counterAxis，primaryAxis 停在 AUTO，随后 body.layoutGrow = 1
    // （code.js:4423/4525/4560）从画框取高，pushToBottom 的 _spacer 因此有空间可吃。
    // 不排除这一形，⑭ 会把 pushToBottom 的每一处正当用法都报成缺陷。
    const growInHug = [];
    for (const g of got) {
      const all = g.frame.findAll(() => true);
      for (const n of all) {
        if (!(n.layoutGrow > 0)) continue;
        const p = n.parent;
        if (!p || !p.layoutMode || p.layoutMode === 'NONE') continue;
        // 父级自身沿同一轴向 grow → 主轴尺寸来自祖父，不是 hug
        if (p.layoutGrow > 0 && p.parent && p.parent.layoutMode === p.layoutMode) continue;
        if (p.primaryAxisSizingMode === 'AUTO') {
          growInHug.push(g.frame.name.slice(0, 20) + '：' + n.name
            + ' grow=' + n.layoutGrow + ' 但父 ' + p.name
            + '(' + p.layoutMode + ') 主轴 AUTO/hug');
        }
      }
    }
    check(
      label + ' 设了 layoutGrow 的节点其父级主轴不得 hug（hug 无剩余空间可分 → 子节点塌成 0 致文字重叠）',
      growInHug.length === 0,
      growInHug.length ? growInHug.length + ' 处：' + growInHug.slice(0, 5).join('; ') : '全部合规'
    );

    // ⑮ 同一横排 Auto Layout 内，相邻可见子节点的水平投影不得相交（条目 [71]）。
    //
    // 与 ⑭ 是同一缺陷的两个抓法：⑭ 抓成因（父 hug × 子 grow），本条抓现象
    // （真的压字了）。两条都留，因为重叠的成因不止 hug 一种 —— 负 itemSpacing、
    // 固定宽子节点合计超出父宽、ABSOLUTE 定位失手，都会压字而父级并非 hug。
    //
    // 离线 mock 不做真实坐标分配（x 恒为 0），所以不能量绝对坐标，改量
    // 「子节点宽度合计 + 间距 + 内边距是否超出父级可用宽」—— 超出即必然重叠或
    // 溢出。这与 ⑬ 那条用「填充高」替代「绝对底边」是同一套替代口径。
    const rowOverflow = [];
    for (const g of got) {
      const rows = g.frame.findAll((n) => n.layoutMode === 'HORIZONTAL' && n.width > 0);
      for (const r of rows) {
        const kids = r.children.filter((c) => c.layoutPositioning !== 'ABSOLUTE'
          && c.visible !== false);
        if (kids.length < 2) continue;
        // grow>0 的子节点会自行收缩，不参与溢出判定
        if (kids.some((c) => c.layoutGrow > 0)) continue;
        const sum = kids.reduce((a, c) => a + c.width, 0)
          + r.itemSpacing * (kids.length - 1) + r.paddingLeft + r.paddingRight;
        if (sum > r.width + 0.5) {
          rowOverflow.push(g.frame.name.slice(0, 20) + '：' + r.name
            + ' 子项合计 ' + Math.round(sum) + ' > 行宽 ' + Math.round(r.width));
        }
      }
    }
    check(
      label + ' 横排行内子项合计不超行宽（超出即压字或溢出；实机 trust 页曾三行全部重叠）',
      rowOverflow.length === 0,
      rowOverflow.length ? rowOverflow.length + ' 处：' + rowOverflow.slice(0, 5).join('; ') : '全部合规'
    );

    // ============================================================
    // ⑦～⑫ 一次性补齐的六个新维度（2026-08-27）
    //
    // 为什么一次补齐而不是逐轮补：前五轮每轮都冒新问题，成因不是「修一个坏
    // 两个」（衍生问题只有 2 处且当轮修掉），而是**每轮我开一个新检查维度，
    // 新维度第一次开就必然捞出一批存量**。只要还有没开的维度，就还会「又冒
    // 一个新问题」。所以把已识别的维度一次性全开，把「每轮冒一个」压成
    // 「一次冒完」，之后才有资格用「全绿」判定收敛。
    // ============================================================

    // ⑦ 字体族与字重必须统一（离线可判定，此前从未查过）。
    //
    // 风险来自 loadFonts() 的降级分支：Noto Sans SC 缺失时整体切到 Inter，
    // 且 SemiBold 在两个族里拼写不同（'SemiBold' vs 'Semi Bold'）。若将来有
    // 哪处绕过 text() 直接设 fontName，就会出现同一页混用两个族 —— 实机看
    // 只是「这行字略胖」，肉眼几乎不可能发现，但导出与交付会出问题。
    //
    // 判据取「族名全等于当轮生效的 FONT_FAMILY」而不是硬编码 'Noto Sans SC'：
    // 离线 mock 的 loadFontAsync 永不抛错，故这里生效的一定是首选族；但把
    // 判据写成「与首个 TEXT 的族一致」能同时覆盖降级后的场景，不必区分环境。
    const fontBad = [];
    let famRef = null;
    const styleAllow = ['Regular', 'Medium', 'SemiBold', 'Semi Bold', 'Bold'];
    for (const g of got) {
      for (const t of g.frame.findAll((n) => n.type === 'TEXT')) {
        const fn = t.fontName;
        // mixed 意味着一个文本节点内混了多种字体，属必须消灭的状态
        if (!fn || fn === 'MIXED' || typeof fn.family !== 'string') {
          fontBad.push(g.frame.name.slice(0, 12) + '/' + t.name + ' fontName 异常');
          continue;
        }
        if (famRef === null) famRef = fn.family;
        if (fn.family !== famRef) {
          fontBad.push(g.frame.name.slice(0, 12) + '/' + t.name + ' 族=' + fn.family);
        }
        if (styleAllow.indexOf(fn.style) < 0) {
          fontBad.push(g.frame.name.slice(0, 12) + '/' + t.name + ' 字重=' + fn.style);
        }
      }
    }
    check(
      label + ' 字体族统一且字重在允许集内（防降级分支混族）',
      fontBad.length === 0,
      fontBad.length
        ? fontBad.length + ' 处：' + fontBad.slice(0, 5).join('; ')
        : '族=' + famRef + '，全部合规'
    );

    // ⑧ 文字不得超出最近的 FIXED 宽祖先（截断风险）。
    //
    // 与②「横排容器内容宽溢出」的区别：②看的是**兄弟累加**是否超容器，
    // 这条看的是**单个文本自身**是否超容器。两者会漏掉不同的东西 ——
    // 一个纵排容器里放一行超长文字，②完全看不见（纵排不累加宽），但它在
    // 实机上就是被裁掉或撑破画框。
    //
    // 只对「宽是 FIXED」的祖先判定，并跳过三类「宽度本就不由自身决定」的节点：
    //  · textTruncation === 'ENDING'：设计允许的截断（如 _search-text 已声明）；
    //  · layoutGrow > 0：主轴上被 Auto Layout 拉伸/压缩；
    //  · layoutSizingHorizontal === 'FILL'：显式声明宽度跟随容器。
    // 后两者在真机上宽度都由父容器给定，mock 不实现拉伸算法（见文件头），
    // 量到的仍是 hug 宽，不跳过就会把已修好的地方当成溢出继续报。
    const textOver = [];
    for (const g of got) {
      for (const t of g.frame.findAll((n) => n.type === 'TEXT')) {
        if (t.textTruncation === 'ENDING') continue;
        if (t.layoutGrow > 0) continue;
        if (t.layoutSizingHorizontal === 'FILL') continue;
        // 找最近的「宽被钉死」的祖先，并沿途累减内边距得可用宽
        let p = t.parent;
        let padSum = 0;
        while (p && p.type !== 'PAGE') {
          if (p.layoutMode !== 'NONE') padSum += p.paddingLeft + p.paddingRight;
          const wFixed = p.layoutMode === 'HORIZONTAL'
            ? p.primaryAxisSizingMode === 'FIXED'
            : p.counterAxisSizingMode === 'FIXED';
          if (wFixed || p.type === 'FRAME' && Math.round(p.width) === 390) {
            const avail = p.width - padSum;
            if (t.width > avail + 0.5) {
              textOver.push(
                g.frame.name.slice(0, 12) + '/"' + t.characters.slice(0, 8) +
                '" 宽 ' + Math.round(t.width) + ' > 可用 ' + Math.round(avail)
              );
            }
            break;
          }
          p = p.parent;
        }
      }
    }
    check(
      label + ' 单个文本未超出 FIXED 宽祖先的可用宽（截断风险）',
      textOver.length === 0,
      textOver.length
        ? textOver.length + ' 处：' + textOver.slice(0, 4).join('; ')
        : '全部合规'
    );

    // ⑨ 同父级内的绝对定位节点不得两两遮挡。
    //
    // 为什么单独查 ABSOLUTE：Auto Layout 流内的节点由排布算法保证不重叠，
    // 只有 layoutPositioning='ABSOLUTE' 的节点是手工摆 x/y 的，摆错就压在
    // 别的元素上。实机看是「这个角标盖住了半个字」，但若两者颜色接近，
    // 截图上完全看不出来。
    //
    // 允许「刻意的层叠」：名字含 _mask / _overlay / _sheet / _backdrop 的
    // 是弹层遮罩，压住下层正是它的职责，放行。
    const overlapOk = (nm) => /_mask|_overlay|_sheet|_backdrop|_shadow/.test(nm);
    const overlaps = [];
    for (const g of got) {
      const hosts = [g.frame, ...g.frame.findAll((n) => n.children && n.children.length > 1)];
      for (const h of hosts) {
        const abs = h.children.filter(
          (c) => c.layoutPositioning === 'ABSOLUTE' && !overlapOk(c.name)
        );
        for (let a = 0; a < abs.length; a++) {
          for (let b = a + 1; b < abs.length; b++) {
            const p1 = abs[a];
            const p2 = abs[b];
            const hit = p1.x < p2.x + p2.width - 0.5 && p2.x < p1.x + p1.width - 0.5 &&
              p1.y < p2.y + p2.height - 0.5 && p2.y < p1.y + p1.height - 0.5;
            if (hit) {
              overlaps.push(
                g.frame.name.slice(0, 12) + '/' + h.name + ': ' + p1.name + ' × ' + p2.name
              );
            }
          }
        }
      }
    }
    check(
      label + ' 同父级内绝对定位节点未两两遮挡（遮罩类已放行）',
      overlaps.length === 0,
      overlaps.length
        ? overlaps.length + ' 处：' + overlaps.slice(0, 4).join('; ')
        : '全部合规'
    );

    // ⑩ 不得残留 Figma 默认图层名。
    //
    // 这条查的是**交付洁净度**，与第 5 轮修掉的空文本节点同源：图层树里
    // 一堆叫「Frame」「Rectangle 12」的节点，开发接手时须逐个点开才知是什么。
    // 项目已有命名规范（`btn/*` `row/*` `card/*` `_nav-*` 等前缀体系，见
    // code.js FLOW_LINKS 注释），默认名意味着有节点漏了命名。
    //
    // TEXT 节点放行：text() 不设 name 时 Figma 用文案作为图层名，这是符合
    // 直觉的默认行为，不算漏命名（第 5 轮那 4 个「Text」是因为文案为空，
    // 已由「无空文本节点」那条断言覆盖）。
    const badNames = [];
    for (const g of got) {
      for (const n of g.frame.findAll((x) => x.type !== 'TEXT')) {
        if (/^(Frame|Rectangle|Ellipse|Group|Vector|Line|Component)( \d+)?$/.test(n.name)) {
          badNames.push(g.frame.name.slice(0, 12) + '/' + n.name + '<' + n.type + '>');
        }
      }
    }
    check(
      label + ' 无 Figma 默认图层名残留（交付洁净度）',
      badNames.length === 0,
      badNames.length
        ? badNames.length + ' 个：' + badNames.slice(0, 5).join('; ')
        : '全部合规'
    );
  }

  // ============================================================
  // 八之三、原型连线与触控区（2026-08-27 新开的两个维度）
  //
  // 必须放在批次循环之后：这两条查的是「批次 5 跑完之后画布的最终状态」，
  // 循环内每跑一个批次都会清空重建，中途查到的是半成品。
  // ============================================================
  console.log('\n=== 原型连线与触控区 ===');

  // ⑪ FLOW_LINKS 必须条条落地，一条不许静默跳过。
  //
  // 这是本探针此前最大的一处假绿：mock 从来没实现 setReactionsAsync，于是
  // 离线跑批次 5 时 24 条连线**每条都抛异常**，被 batchFlow 的 try/catch
  // 收进 skipped 数组、只体现为返回字符串里的一段文字，没有任何断言在看。
  // 连线全断，探针照样全绿。（mock 已在本轮补上该方法，见 makeNode）
  //
  // 两端都钉：① 表里每条源节点都能在源画框内精确命中且唯一（findClickable
  // 的两个抛错分支）；② 命中的节点真的挂上了指向正确画框的 reaction。
  // 只钉①不够 —— 节点存在但 reaction 没落上，Present 模式里就是死链。
  const flowTable = M.FLOW_LINKS || [];

  // 先查 batchFlow 自己的口供：它把每条失败的原因写在返回消息的「跳过 N 条」
  // 段落里。这条与下面「逐条核 reaction」互补 —— 前者告诉你**为什么**断，
  // 后者证明**确实**断了。只有后者时，报错只有「reaction 未落上」，得再翻
  // 一遍源码猜原因；只有前者时，消息说成功了但 reaction 绑错节点也照样绿。
  const flowMsg = batchMsg['批次 5 flow'] || '';
  const skipMatch = /跳过 (\d+) 条/.exec(flowMsg);
  check(
    '批次 5 自报 0 条跳过（skipped 此前无人查，连线全断也不失败）',
    !skipMatch,
    skipMatch
      ? skipMatch[1] + ' 条跳过：' + flowMsg.slice(flowMsg.indexOf('跳过')).slice(0, 400)
      : (/成功连线 (\d+)/.exec(flowMsg) || [, '?'])[1] + ' / ' + flowTable.length + ' 条全部成功'
  );

  const frameIndex = {};
  for (const pg of figma.root.children) {
    for (const top of pg.children) {
      const cands = top.type === 'SECTION' ? top.children : [top];
      for (const c of cands) {
        if (c.type !== 'FRAME') continue;
        if (c.name.indexOf('board/') === 0 || c.name.indexOf('_components') === 0) continue;
        if (c.name.indexOf('_annotation/') === 0) continue;
        const pid = c.name.split(' ·')[0];
        // 变体画框不进索引，与 code.js indexMainFrames 同口径。
        // 标记取导出的真源常量而非硬写字面量：VARIANT_TAG 改了这里要跟着改，
        // 硬写会导致索引悄悄把变体也收进来、跳转连到变体画框上
        if (M.VARIANT_TAG && c.name.indexOf(M.VARIANT_TAG) > -1) continue;
        if (!frameIndex[pid]) frameIndex[pid] = c;
      }
    }
  }
  check(
    'FLOW_LINKS 表已导出且非空（否则下面两条都是空跑）',
    flowTable.length > 0,
    flowTable.length + ' 条'
  );

  const linkBad = [];
  const wiredNodes = [];
  for (const [srcId, nodeName, dstId] of flowTable) {
    const src = frameIndex[srcId];
    const dst = frameIndex[dstId];
    if (!src) { linkBad.push(srcId + ' 源画框缺失'); continue; }
    if (!dst) { linkBad.push(dstId + ' 目标画框缺失'); continue; }
    const hits = src.findAll((n) => n.name === nodeName);
    if (hits.length !== 1) {
      linkBad.push(srcId + '/' + nodeName + ' 命中 ' + hits.length + ' 个（须唯一）');
      continue;
    }
    const rs = hits[0].reactions || [];
    const act = rs[0] && rs[0].actions && rs[0].actions[0];
    if (!act || act.destinationId !== dst.id) {
      linkBad.push(
        srcId + '/' + nodeName + ' -> ' + dstId +
        ' reactions=' + rs.length +
        ' got=' + (act ? act.destinationId : 'none') +
        ' want=' + dst.id
      );
      continue;
    }
    wiredNodes.push({ frame: srcId, node: hits[0] });
  }
  check(
    'FLOW_LINKS ' + flowTable.length + ' 条全部落地（触发点唯一 + reaction 指向正确）',
    linkBad.length === 0,
    linkBad.length
      ? linkBad.length + ' 条异常：' + linkBad.slice(0, 5).join('; ')
      : '全部连通'
  );

  // ⑫ 触控区 ≥ 44×44（PRD §1.8）。
  //
  // 第 5 轮实机也查过这条，但口径是错的：当时按名前缀
  // ['_tab-','_nav-action','_nav-bell','btn/','_fab'] 匹配，把 24×24 的
  // **图标**（_tab-icon-*）也当成可点控件报了失败，而真正承载点击的外层
  // 单元格 _tab-* 是 130×44、达标。等于这个维度实际上还没验过。
  //
  // 这次改用「真的挂了 reaction 的节点」作判据 —— 这是**成因层面**的口径：
  // 能点的定义就是「挂了 reaction」，不是「名字像按钮」。名字匹配永远会
  // 在图标/文字子节点上误报，而 reaction 只挂在真正的触发点上。
  //
  // 阈值取 44：PRD §1.8 的硬指标。宽度不足 44 的窄控件（如导航栏文字动作）
  // 若在实现上加了透明扩展命中区，命中区节点本身就是挂 reaction 的那个，
  // 量的就是它，不会误判。
  //
  // 唯一豁免：导航栏文字动作 _nav-action/*。判据写进代码而不是靠人记 ——
  // PRD §1.8 的 44×44 针对**图标类**控件；文字动作（「取消」「确定」）横向
  // 命中区由文案长度决定，两字仅 28 宽，实现上已把纵向补到 44
  // （见 code.js navBar() :1163-1174 的豁免说明，同 §1.4.1 对搜索框 32 高的
  // 豁免理由）。豁免不是无条件放行：纵向仍必须满 44，横向仍须 ≥28
  // （少于两字宽就是真的点不着了），任一不满照样报失败。
  const NAV_TEXT_ACTION = /^_nav-action\//;
  const smallHits = [];
  for (const { frame, node } of wiredNodes) {
    const w = node.width;
    const h = node.height;
    const ok = NAV_TEXT_ACTION.test(node.name)
      ? h >= 43.5 && w >= 27.5
      : w >= 43.5 && h >= 43.5;
    if (!ok) {
      smallHits.push(
        frame + '/' + node.name + ' ' + Math.round(w) + '×' + Math.round(h)
      );
    }
  }
  check(
    '所有挂了 reaction 的触发点 ≥ 44×44（PRD §1.8，口径改为按 reaction 认）',
    smallHits.length === 0,
    smallHits.length
      ? smallHits.length + ' 处不达标：' + smallHits.slice(0, 6).join('; ')
      : wiredNodes.length + ' 个触发点全部达标'
  );

  // ============================================================
  // 九、反向用例：把 box() 的轴向退回旧写法，确认新断言真能抓住它
  //
  // 为什么必须有这一步：上面「横排容器高未卡在 100」是实机验收暴露缺口后
  // 补的断言，它当下是绿的。但绿有两种可能 —— ① 代码真的修好了；
  // ② 断言写歪了，永远绿。这两者必须区分开，否则等于给自己发免罪符。
  //
  // 做法是把带旧轴向逻辑的 code.js 现场重跑一遍：旧逻辑对 HORIZONTAL 会把
  // counterAxisSizingMode（横排的高）在传 w 时设成 FIXED，从而钉死默认 100。
  // 若断言有效，这里必然报出 _primary-row / _third-title / _third-party。
  // ============================================================
  console.log('\n--- 反向用例：还原旧 box() 轴向，验断言有区分力 ---');

  // 用正则按两行赋值语句本身定位，不含前面的注释块 —— 首版把整段连注释
  // 一起当字面量匹配，因中间夹着多行注释而没命中，替换静默失效。
  const rawOld = raw.replace(
    /f\.primaryAxisSizingMode = \(horiz \? opt\.w : opt\.h\) \? 'FIXED' : 'AUTO';\s*\n\s*f\.counterAxisSizingMode = \(horiz \? opt\.h : opt\.w\) \? 'FIXED' : 'AUTO';/,
    "f.primaryAxisSizingMode = opt.h ? 'FIXED' : 'AUTO';\n" +
    "  f.counterAxisSizingMode = opt.w ? 'FIXED' : 'AUTO';"
  );
  check(
    '[反向] 旧轴向代码替换成功（证明下一条测的确实是旧逻辑）',
    rawOld !== raw,
    rawOld !== raw ? '已还原为旧写法' : '替换未生效，源码片段可能已改动'
  );

  if (rawOld !== raw) {
    const oldM = new Function(
      'figma', '__html__',
      rawOld + '\n;return { buildLogin: buildLogin };'
    )(figma, '');
    const oldLogin = oldM.buildLogin();
    const oldStuck = oldLogin.findAll(
      (n) => n.layoutMode === 'HORIZONTAL' &&
             n.children.length > 0 &&
             n.counterAxisSizingMode === 'FIXED' &&
             Math.abs(n.height - 100) < 0.5
    );
    check(
      '[反向] 旧轴向下「高卡在 100」断言确实触发（实机实测同样症状）',
      oldStuck.length > 0,
      oldStuck.length
        ? '检出 ' + oldStuck.length + ' 处：' + oldStuck.map((n) => n.name).join(', ')
        : '未检出 —— 说明该断言无区分力，需重写'
    );

    // 顺带复现实机量到的 943：这个数是实机验收的实测值，能对上说明
    // mock 的高度计算在这条路径上与真机一致，不是巧合性绿灯
    const oldBody = oldLogin.children.find((c) => c.name === '_body');
    const oldTotal = (oldLogin.children[0] ? oldLogin.children[0].height : 0) +
      (oldBody ? oldBody.height : 0);
    check(
      '[反向] 旧轴向下 login 确实溢出 844（实机实测 943）',
      oldTotal > CANVAS_H,
      '实测 ' + Math.round(oldTotal) + ' > 844'
    );
  }

  // 还原 navBar 的 SPACE_BETWEEN，验「与 layoutGrow 同设」那条断言有区分力。
  // 与上面同理：该断言现在是绿的，必须证明它不是永绿。
  const rawSB = raw.replace(
    /(box\('_nav-bar', 'HORIZONTAL', \{[\s\S]*?)align: 'CENTER'(\s*\}\);)/,
    "$1align: 'CENTER', justify: 'SPACE_BETWEEN'$2"
  );
  check(
    '[反向] navBar 的 SPACE_BETWEEN 还原成功（证明下一条测的是旧写法）',
    rawSB !== raw,
    rawSB !== raw ? '已还原' : '替换未生效，源码片段可能已改动'
  );

  if (rawSB !== raw) {
    const sbM = new Function(
      'figma', '__html__',
      rawSB + '\n;return { navBar: navBar };'
    )(figma, '');
    const sbNav = sbM.navBar('鸭圈', { search: '搜索', right: '列表', bell: 3 });
    const hasConflict = sbNav.primaryAxisAlignItems === 'SPACE_BETWEEN' &&
      sbNav.children.some((c) => c.layoutGrow > 0);
    check(
      '[反向] SPACE_BETWEEN + layoutGrow 冲突断言确实触发（实机实测 25 页溢出）',
      hasConflict,
      hasConflict
        ? 'justify=' + sbNav.primaryAxisAlignItems + ' 且有 grow 子项 —— 已检出'
        : '未检出 —— 说明该断言无区分力，需重写'
    );
  }

  // 还原 _lv1-cat-* 选中态取原色（去掉 -deep），验「深色变体」那条断言有区分力。
  //
  // 这条与上面两条不同：它不必真跑布局，只要证明「把 fill 改回原色」会被
  // 断言检出即可 —— 因为那条断言查的是取色表达式本身，不是量出来的尺寸。
  const rawNoDeep = raw.replace(
    /fill: on \? 'category\/' \+ CAT_LIST\[i\]\[0\] \+ '-deep' : 'color\/background'/,
    "fill: on ? 'category/' + CAT_LIST[i][0] : 'color/background'"
  );
  check(
    '[反向] _lv1 取色还原成原色成功（证明下一条测的是旧写法）',
    rawNoDeep !== raw,
    rawNoDeep !== raw ? '已还原' : '替换未生效，源码片段可能已改动'
  );
  if (rawNoDeep !== raw) {
    const stillDeep =
      /fill: on \? 'category\/' \+ CAT_LIST\[i\]\[0\] \+ '-deep' : 'color\/background'/
        .test(rawNoDeep);
    check(
      '[反向] 选中态取原色时「须取 -deep」断言确实触发（实机实测房屋 4.23:1）',
      !stillDeep,
      !stillDeep ? '旧写法已被检出' : '未检出 —— 说明该断言无区分力，需重写'
    );
  }

  // 验前提数字：白字压五个分类原色确实全部低于 4.5:1 —— 这是 -deep 变体
  // 存在的唯一依据，依据本身必须被断言钉住而不是只写在注释里。
  // 若哪天有人把某个分类原色调深到达标，这条会失败；那时该重新评估是否还
  // 需要 -deep，而不是把这条删掉。
  const baseBody = (raw.match(/var CATEGORY_COLORS = \{([\s\S]*?)\};/) || [])[1] || '';
  const basePairs = [...baseBody.matchAll(/'([\w-]+)':\s*'(#[0-9A-Fa-f]{6})'/g)];
  const baseRatios = basePairs.map(
    ([, k, hx]) => k + ' ' + (Math.round((1.05 / (lumOf(hx) + 0.05)) * 100) / 100)
  );
  const allBaseFail = basePairs.every(([, , hx]) => 1.05 / (lumOf(hx) + 0.05) < 4.5);
  check(
    '[反向] 白字压分类原色确实全不达标（-deep 变体存在的依据）',
    basePairs.length === 5 && allBaseFail,
    baseRatios.join(' / ')
  );

  // 还原 listRow() 的无条件 text(value || '')，验「无空文本节点」那条断言有区分力。
  //
  // 这条必须真跑布局（不能只查源码字符串）：断言查的是产出的节点树里有没有
  // characters === '' 的 TEXT，所以反向用例也得把旧写法真建出来数一遍。
  // 取 buildSettings —— 实机在它上面查到 3 个空文本，是空值条目最多的一屏。
  const rawEmptyText = raw.replace(
    "if (value) right.appendChild(text(value, 'small', 'color/text-secondary'));",
    "right.appendChild(text(value || '', 'small', 'color/text-secondary'));"
  );
  check(
    '[反向] listRow 空值守卫还原成功（证明下一条测的是旧写法）',
    rawEmptyText !== raw,
    rawEmptyText !== raw ? '已还原为无条件建节点' : '替换未生效，源码片段可能已改动'
  );
  if (rawEmptyText !== raw) {
    const etM = new Function(
      'figma', '__html__',
      rawEmptyText + '\n;return { buildSettings: buildSettings };'
    )(figma, '');
    const oldSettings = etM.buildSettings();
    const oldEmpty = oldSettings.findAll(
      (n) => n.type === 'TEXT' && n.characters === ''
    );
    check(
      '[反向] 旧写法下「无空文本节点」断言确实触发（实机实测 settings 3 个）',
      oldEmpty.length > 0,
      oldEmpty.length
        ? '检出 ' + oldEmpty.length + ' 个空文本，父级：' +
          oldEmpty.map((n) => n.parent.name).join(', ')
        : '未检出 —— 说明该断言无区分力，需重写'
    );
  }

  // ============================================================
  // 九之二、六个新维度（⑦～⑫）各自的反向用例
  //
  // 规矩同上：新断言现在全绿，必须逐条证明「它会因对应的错而变红」，
  // 否则一条写错判据的断言与没写没有区别 —— 说明文档 ㊲「检查器本身也会错」。
  //
  // 这六条都不改源码字符串，而是**直接在真跑出来的节点树上注入对应缺陷**，
  // 再用与正向断言完全相同的判据重算一遍。这样验的是判据本身，
  // 不依赖某段源码的字面写法（源码一改，字符串替换法就失效）。
  // ============================================================
  console.log('\n--- 反向用例：六个新维度（⑦～⑫）---');

  const revFrame = M.buildLogin();

  // ⑦ 混族：把一个 TEXT 的族改掉，验「族统一」判据能检出
  {
    const ts = revFrame.findAll((n) => n.type === 'TEXT');
    const famRef = ts[0].fontName.family;
    ts[ts.length - 1].fontName = { family: 'Inter', style: 'Bold' };
    const bad = ts.filter((t) => t.fontName.family !== famRef);
    check(
      '[反向] 注入混族后「字体族统一」判据确实触发',
      bad.length > 0,
      bad.length ? '检出 ' + bad.length + ' 处：族=' + bad[0].fontName.family
        : '未检出 —— 判据无区分力，需重写'
    );
    // 复原，避免污染后续用例
    ts[ts.length - 1].fontName = { family: famRef, style: 'Regular' };
  }

  // ⑦ 越界字重：Light 不在允许集内，须被检出
  {
    const styleAllow = ['Regular', 'Medium', 'SemiBold', 'Semi Bold', 'Bold'];
    check(
      '[反向] 越界字重（Light）不在允许集内',
      styleAllow.indexOf('Light') < 0,
      '允许集=' + styleAllow.join('/')
    );
  }

  // ⑧ 超宽文本：往 login 的 _body 里塞一行长文案，验「超 FIXED 宽祖先」判据
  {
    const body = revFrame.children.find((c) => c.name === '_body');
    // 必须用 figma.createText() 现造，不能从既有树里捞一个 TEXT：
    // Instance 内部的 TEXT 是 deepCopy 出来的 makeNode('TEXT')，没有 makeText()
    // 的 _remeasure，改 characters 不会重算宽度（首版这么写，量出宽 24 而非 400+）。
    const longT = figma.createText();
    longT.name = '_rev-long-text';
    longT.fontSize = 16;
    longT.lineHeight = { value: 24, unit: 'PIXELS' };
    longT.characters = '这是一行刻意写得很长的中文文案用来验证超宽判据是否真的会触发不要删除';
    body.appendChild(longT);
    // 判据与正向完全一致：沿父链找最近的 FIXED 宽祖先，累减内边距
    let p = longT.parent;
    let padSum = 0;
    let hit = null;
    while (p && p.type !== 'PAGE') {
      if (p.layoutMode !== 'NONE') padSum += p.paddingLeft + p.paddingRight;
      const wFixed = p.layoutMode === 'HORIZONTAL'
        ? p.primaryAxisSizingMode === 'FIXED'
        : p.counterAxisSizingMode === 'FIXED';
      if (wFixed || (p.type === 'FRAME' && Math.round(p.width) === 390)) {
        hit = { avail: p.width - padSum, over: longT.width > p.width - padSum + 0.5 };
        break;
      }
      p = p.parent;
    }
    check(
      '[反向] 注入长文案后「单个文本超 FIXED 宽祖先」判据确实触发',
      !!hit && hit.over,
      hit ? '文本宽 ' + Math.round(longT.width) + ' vs 可用 ' + Math.round(hit.avail)
        : '未找到 FIXED 宽祖先 —— 判据的父链上溯有问题'
    );
    longT.remove();
  }

  // ⑧ 反向之二：同一个节点标上 FILL 后必须被放行（证明豁免分支也是活的，
  // 否则「跳过 FILL」写成永真跳过，整条断言就等于关掉了）。
  // 顺带验 layoutSizingGuard 本身：FILL 必须先挂进 Auto Layout 父级才能设。
  {
    const holder = figma.createFrame();
    holder.layoutMode = 'VERTICAL';
    const t = figma.createText();
    t.characters = '测试';
    let threw = false;
    try {
      t.layoutSizingHorizontal = 'FILL'; // 还没挂父级，须抛错
    } catch (e) {
      threw = true;
    }
    holder.appendChild(t);
    t.layoutSizingHorizontal = 'FILL';   // 挂上之后才合法
    check(
      '[反向] FILL 未挂 Auto Layout 父级时抛错、挂上后可设，且被超宽判据放行',
      threw && t.layoutSizingHorizontal === 'FILL',
      '无父级赋值' + (threw ? '已抛错' : '未抛错（约束失效）') +
      '；挂父后取值=' + t.layoutSizingHorizontal
    );
  }

  // ⑨ 遮挡：造两个同父级的 ABSOLUTE 节点并让它们相交，验 AABB 判交
  {
    const host = M.buildLogin();
    const a = M.button('甲', 'primary', 100);
    const b = M.button('乙', 'primary', 100);
    for (const n of [a, b]) {
      n.layoutPositioning = 'ABSOLUTE';
      host.appendChild(n);
    }
    a.x = 10; a.y = 10;
    b.x = 50; b.y = 20;   // 与 a 相交
    const overlap = !(b.x >= a.x + a.width || a.x >= b.x + b.width ||
      b.y >= a.y + a.height || a.y >= b.y + b.height);
    check(
      '[反向] 注入相交的两个 ABSOLUTE 节点后遮挡判据确实触发',
      overlap,
      overlap ? 'AABB 相交已检出' : '未检出 —— AABB 判交写反了'
    );
    // 遮罩类必须被放行，证明豁免分支不是永真放行
    const overlapOk = (nm) => /_mask|_overlay|_sheet|_backdrop|_shadow/.test(nm);
    check(
      '[反向] 遮罩类命名被放行、普通命名不被放行',
      overlapOk('_mask') && overlapOk('_sheet') && !overlapOk('btn/primary/甲'),
      '_mask/_sheet 放行；btn/* 不放行'
    );
  }

  // ⑩ 默认图层名：正则须能抓 Frame/Frame 12/Rectangle，且不误伤业务命名
  {
    const defaultName = /^(Frame|Rectangle|Ellipse|Group|Vector|Line|Component)( \d+)?$/;
    const shouldHit = ['Frame', 'Frame 12', 'Rectangle', 'Group 3', 'Vector'];
    const shouldPass = ['_body', 'btn/primary/登录', '_map-caption', 'Frame内容区'];
    check(
      '[反向] 默认图层名正则命中全部默认名、且不误伤业务命名',
      shouldHit.every((s) => defaultName.test(s)) &&
      shouldPass.every((s) => !defaultName.test(s)),
      '命中 ' + shouldHit.length + ' 个默认名，放行 ' + shouldPass.length + ' 个业务名'
    );
  }

  // ⑪ 连线：把 FLOW_LINKS 某条的节点名改错，验「触发点唯一」判据会检出。
  // 这正是本轮真捞出的那个 bug 的形态（primary 写成了 capsule 的位置）。
  {
    const srcFrame = M.buildLogin();
    const realName = 'btn/capsule/登录 / 注册';
    const wrongName = 'btn/primary/登录 / 注册';
    const realHits = srcFrame.findAll((n) => n.name === realName).length;
    const wrongHits = srcFrame.findAll((n) => n.name === wrongName).length;
    check(
      '[反向] FLOW_LINKS 节点名写错时「触发点唯一」判据确实触发（本轮真 bug 的形态）',
      realHits === 1 && wrongHits === 0,
      '真名命中 ' + realHits + ' 个，错名命中 ' + wrongHits + ' 个'
    );
  }

  // ⑪ 反向之二：reaction 未落上时必须检出（mock 未实现 setReactionsAsync
  // 的那个假绿，本质就是这里恒为 0 却没人看）
  {
    const n = M.button('测试', 'primary', 100);
    const before = (n.reactions || []).length;
    await n.setReactionsAsync([{
      trigger: { type: 'ON_CLICK' },
      actions: [{ type: 'NODE', destinationId: 'X1', navigation: 'NAVIGATE' }]
    }]);
    const after = n.reactions.length;
    const got = n.reactions[0].actions[0].destinationId;
    check(
      '[反向] setReactionsAsync 真的把 reaction 存下来了（mock 曾完全没实现）',
      before === 0 && after === 1 && got === 'X1',
      '存前 ' + before + ' 条 → 存后 ' + after + ' 条，destinationId=' + got
    );
  }

  // ⑫ 触控区：造一个 24×24 的触发点，验阈值判据会检出；
  // 同时验 _nav-action/* 豁免既能放行 28×44、也不会放行 28×20
  {
    const small = M.button('小', 'primary', 24);
    small.resize(24, 24);
    const NAV = /^_nav-action\//;
    const judge = (nm, w, h) => (NAV.test(nm) ? h >= 43.5 && w >= 27.5 : w >= 43.5 && h >= 43.5);
    check(
      '[反向] 24×24 触发点被触控区判据检出，_nav-action 豁免仅放行纵向达标者',
      !judge('btn/primary/小', 24, 24) &&
      judge('_nav-action/取消', 28, 44) &&
      !judge('_nav-action/取消', 28, 20),
      'btn 24×24 报错；_nav-action 28×44 放行；_nav-action 28×20 仍报错'
    );
  }

  // ============================================================
  // 九、产出规模自报（I4）：ui.html 首屏计数改为运行时回填后，
  // 断言必须守住「回填的数就是真源的数」这件事。
  // 判据全部从 code.js 导出的真源表现算，探针内不抄任何数字副本。
  // ============================================================
  console.log('\n--- 产出规模自报（planStats 与真源一致性）---');
  {
    const st = M.planStats();
    const cnt = (o) => Object.keys(o).length;

    // COLOR/FLOAT 分项必须逐张表对齐，只验 total 会让「一项多算、另项少算」互相抵消
    const colorOk =
      st.tokens.semantic === cnt(M.SEMANTIC_COLORS) &&
      st.tokens.category === cnt(M.CATEGORY_COLORS) &&
      st.tokens.categoryDeep === cnt(M.CATEGORY_DEEP) &&
      st.tokens.color === cnt(M.SEMANTIC_COLORS) + cnt(M.CATEGORY_COLORS) + cnt(M.CATEGORY_DEEP);
    check(
      'planStats COLOR 分项逐张表对齐（含长期漏计的 CATEGORY_DEEP）',
      colorOk,
      '语义 ' + st.tokens.semantic + ' + 分类 ' + st.tokens.category
      + ' + 深色 ' + st.tokens.categoryDeep + ' = ' + st.tokens.color
    );

    const floatOk =
      st.tokens.size === cnt(M.TYPE_SCALE) &&
      st.tokens.spacing === cnt(M.SPACING) &&
      st.tokens.radius === cnt(M.RADIUS) &&
      st.tokens.float === cnt(M.TYPE_SCALE) + cnt(M.SPACING) + cnt(M.RADIUS) &&
      st.tokens.total === st.tokens.color + st.tokens.float;
    check(
      'planStats FLOAT 分项与总计对齐',
      floatOk,
      '字号 ' + st.tokens.size + ' + 间距 ' + st.tokens.spacing + ' + 圆角 ' + st.tokens.radius
      + ' = ' + st.tokens.float + '，合计 ' + st.tokens.total
    );

    // master 数以 registerComponents 真跑一遍的实际产出为准，不信 planStats 自述
    const host = M.registerComponents(figma.currentPage);
    const actualMasters = host.children.filter((n) => n.type === 'COMPONENT').length;
    check(
      'planStats master 总数 == registerComponents 实际注册数',
      st.masters.total === actualMasters &&
      st.masters.tabs === M.SHELL_TABS.length &&
      st.masters.buttons === M.BUTTON_VARIANTS.length &&
      st.masters.pins === cnt(M.CATEGORY_COLORS) * 2,
      '自报 ' + st.masters.total + '（Tab' + st.masters.tabs + '/按钮' + st.masters.buttons
      + '/Pin' + st.masters.pins + '）vs 实际 ' + actualMasters
    );

    check(
      'planStats corePages == CORE_PAGES 登记表长度，且全部构造器可用',
      st.corePages === M.CORE_PAGES.length &&
      M.CORE_PAGES.every((p) => typeof p[0] === 'function' && typeof p[1] === 'string'),
      '核心流程页 ' + st.corePages + ' 页'
    );

    check(
      'planStats flowLinks == FLOW_LINKS 长度',
      st.flowLinks === M.FLOW_LINKS.length,
      '跳转 ' + st.flowLinks + ' 条'
    );

    // FLOW_LINKS 的源与目标必须全在主态登记表内：登记表若少一项，
    // 连线就会指向一个不进跳转索引的画框，Present 模式点下去无反应
    const outsiders = [];
    for (const link of M.FLOW_LINKS) {
      if (M.MAIN_SCREENS.indexOf(link[0]) < 0) outsiders.push('源:' + link[0]);
      if (M.MAIN_SCREENS.indexOf(link[2]) < 0) outsiders.push('目标:' + link[2]);
    }
    check(
      'FLOW_LINKS 全部源/目标画框均在 MAIN_SCREENS 登记表内',
      outsiders.length === 0,
      outsiders.length ? '未登记：' + outsiders.join(', ') : '全部 ' + M.FLOW_LINKS.length + ' 条两端均已登记'
    );

    // 反向：未登记的 pageId 必须当场抛错，而不是静默产出一个错计数；
    // 同时已登记者与变体都不能被误伤（否则这道校验会挡住正常生成）
    let unregisteredThrew = false;
    try {
      M.screen('ghost-screen', '未登记页', 'PRD §0');
    } catch (e) {
      unregisteredThrew = true;
    }
    let registeredOk = true;
    let variantOk = true;
    try {
      M.screen('splash-screen', '启动页', 'PRD §2.1 U1');
    } catch (e) {
      registeredOk = false;
    }
    try {
      // 变体的 pageId 允许不在登记表内（它不参与主态计数）
      M.screen('ghost-screen', '某变体', 'PRD §0', true);
    } catch (e) {
      variantOk = false;
    }
    check(
      '[反向] screen() 未登记主态抛错，已登记主态与变体均不被误伤',
      unregisteredThrew && registeredOk && variantOk,
      '未登记抛错=' + unregisteredThrew + '，已登记放行=' + registeredOk + '，变体放行=' + variantOk
    );
  }

  // ============================================================
  // 十、规格标注分级与节点级引用（I1）
  //
  // 要守住的三件事：
  // ① severity 分档真的改了配色与前缀（否则「红线」与「留白 16px」仍视觉同构）；
  // ② spec 档与改造前**完全一致**（本轮范围红线是「不做逐页像素精修」，
  //    分级不许顺带引发全画布视觉 diff）；
  // ③ 节点级 annotation 真的落到 target 指定的那个节点上，而不是笼统挂画框 ——
  //    这是 I1 的全部意义所在（改造前 35 张卡对被标注对象零引用）。
  //
  // 判据一律从 code.js 导出的 SEVERITY / ANNO_CATEGORY / paintOf 现算，
  // 探针内不抄任何配色副本（见原则㊾：计数与配色只能有一个出处）。
  // ============================================================
  console.log('\n--- 规格标注分级与节点级引用（I1）---');
  {
    const pj = (x) => JSON.stringify(x);
    const sevKeys = Object.keys(M.SEVERITY);

    // ① 五档逐项对齐：底色/描边/文字色/前缀四项都要跟 SEVERITY 表现算的值一致
    const sevBad = [];
    for (const k of sevKeys) {
      const s = M.SEVERITY[k];
      const card = M.annotation('档位样例', ['第一条', '第二条'], { severity: k });
      const head = card.children[0];
      if (pj(card.fills) !== pj([M.paintOf(s.fill)])) sevBad.push(k + '.fill');
      if (pj(card.strokes) !== pj([M.paintOf(s.stroke)])) sevBad.push(k + '.stroke');
      if (pj(head.fills) !== pj([M.paintOf(s.ink)])) sevBad.push(k + '.ink');
      if (head.characters !== s.tag + '档位样例') sevBad.push(k + '.tag');
      // 正文行数必须等于传入条数 + 1 行标题，少一行说明循环写漏
      if (card.children.length !== 3) sevBad.push(k + '.lines(' + card.children.length + ')');
    }
    check(
      'SEVERITY 五档的底色/描边/文字色/前缀逐项与真源表对齐',
      sevBad.length === 0,
      sevBad.length ? '不一致：' + sevBad.join(', ') : sevKeys.length + ' 档全部对齐：' + sevKeys.join('/')
    );

    // ② spec 是默认档，且配色必须仍是改造前那三个 role。
    // 这里刻意写死字面 role 名 —— 它是「不引发视觉 diff」这个承诺的锚点，
    // 若哪天有人顺手改了 SEVERITY.spec 的配色，必须在这里当场亮红。
    const plain = M.annotation('无档位', ['x']);
    const asSpec = M.annotation('无档位', ['x'], { severity: 'spec' });
    check(
      'spec 为默认档且配色仍为 primary-light/primary/primary-dark（守住零视觉 diff）',
      pj(plain.fills) === pj(asSpec.fills) &&
      pj(plain.strokes) === pj(asSpec.strokes) &&
      pj(plain.children[0].fills) === pj(asSpec.children[0].fills) &&
      plain.children[0].characters === '无档位' &&
      M.SEVERITY.spec.fill === 'color/primary-light' &&
      M.SEVERITY.spec.stroke === 'color/primary' &&
      M.SEVERITY.spec.ink === 'color/primary-dark' &&
      M.SEVERITY.spec.tag === '',
      '不传 severity 与显式 spec 完全同构，且无前缀'
    );

    // ③ 未知档位不崩、不掉色：拼错 severity 只该退回 spec，不该让卡片失去配色
    const typo = M.annotation('拼错档位', ['x'], { severity: 'redlin' });
    check(
      '[反向] severity 拼错时退回 spec 而非无填充（不静默产出白卡）',
      pj(typo.fills) === pj(asSpec.fills) && typo.children[0].characters === '拼错档位',
      '退回 spec 配色'
    );

    // ④ pluginData 是两个承载体之间唯一的传值通道，必须真存真取
    const withTarget = M.annotation('带靶标', ['甲', '乙'], { severity: 'a11y', target: '_the-target' });
    let raw = null;
    try {
      raw = JSON.parse(withTarget.getPluginData('anno'));
    } catch (e) {
      raw = null;
    }
    check(
      'annotation 把 severity/target/title/lines 如实存进 pluginData',
      !!raw && raw.severity === 'a11y' && raw.target === '_the-target' &&
      raw.title === '带靶标' && pj(raw.lines) === pj(['甲', '乙']),
      raw ? pj(raw) : '读不出或非法 JSON'
    );

    /**
     * 造一个「画框 + 一个具名目标子节点 + 一张标注卡」的最小场景并跑 detachAnnotations
     * @param {string} target 卡片声明的目标节点名
     * @param {string} realName 画框内真实存在的那个子节点名
     * @returns {{frame:Object,node:Object,card:Object}} 供断言查的三个节点
     */
    const scene = (target, realName) => {
      const host = figma.createPage();
      const frame = M.box('screen/靶标场景', 'VERTICAL', { w: 390, h: 844 });
      const node = M.box(realName, 'VERTICAL', { w: 100, h: 44 });
      frame.appendChild(node);
      const card = M.annotation('节点级靶标', ['规格一', '规格二'], { severity: 'redline', target });
      frame.appendChild(card);
      host.appendChild(frame);
      M.detachAnnotations(frame, host);
      return { frame, node, card };
    };

    // ⑤ target 命中：标注必须钉在那个节点上，画框自身不该被顺带标注
    const hit = scene('_the-target', '_the-target');
    check(
      'target 命中时节点级标注落到该节点，画框自身不被标注',
      hit.node.annotations.length === 1 && hit.frame.annotations.length === 0,
      '目标节点 ' + hit.node.annotations.length + ' 条 / 画框 ' + hit.frame.annotations.length + ' 条'
    );

    // ⑥ 反向：target 写错时退回整页标注，绝不静默丢弃 ——
    // 「找不到就不标」是最坏结果：规格没了，而且没人会发现
    const miss = scene('_名字写错了', '_the-target');
    check(
      '[反向] target 写错时退回画框标注，标注不丢',
      miss.frame.annotations.length === 1 && miss.node.annotations.length === 0,
      '画框 ' + miss.frame.annotations.length + ' 条 / 目标节点 ' + miss.node.annotations.length + ' 条'
    );

    // ⑦ 两个承载体内容同源：labelMarkdown 的每一行都要能在画布卡文本里找到。
    // 只比标题会漏掉「正文改了一处、只改了一边」这种分叉。
    const md = hit.node.annotations[0].labelMarkdown;
    const cardTexts = hit.card.children.map((c) => c.characters);
    const sameSource =
      md.indexOf('**' + M.SEVERITY.redline.tag + '节点级靶标**') === 0 &&
      md.indexOf('- 规格一') > 0 && md.indexOf('- 规格二') > 0 &&
      cardTexts[0] === M.SEVERITY.redline.tag + '节点级靶标' &&
      cardTexts[1] === '· 规格一' && cardTexts[2] === '· 规格二';
    check(
      'labelMarkdown 与画布卡文本同源（标题与每条正文逐条对上）',
      sameSource,
      pj(md.slice(0, 40)) + ' ↔ ' + pj(cardTexts)
    );

    // ⑧ categoryId 必须按 SEVERITY.category 映射，不能全落到 Development 里 ——
    // 否则 Dev Mode 面板里无障碍项与实现口径混在一格，分级白做
    const catBad = [];
    for (const k of sevKeys) {
      const n = M.box('probe/cat/' + k, 'VERTICAL', {});
      M.attachNodeAnnotation(n, { severity: k, title: 'T', lines: ['L'] });
      const want = M.ANNO_CATEGORY[M.SEVERITY[k].category];
      if (!n.annotations.length || n.annotations[0].categoryId !== want) {
        catBad.push(k + '→' + (n.annotations[0] || {}).categoryId + '(应为 ' + want + ')');
      }
    }
    check(
      'categoryId 按 SEVERITY.category 逐档映射到 ANNO_CATEGORY',
      catBad.length === 0,
      catBad.length ? catBad.join(', ') : sevKeys.map((k) => k + '→' + M.ANNO_CATEGORY[M.SEVERITY[k].category]).join(' / ')
    );

    // ⑨ 降级路径：categoryId 在别的 Figma 文件里可能无效（本文件实测值）。
    // 那时必须去掉分类重写一次，而不是让标注整条丢掉。
    const strict = { name: 'strict', _anno: [] };
    Object.defineProperty(strict, 'annotations', {
      get() { return this._anno; },
      set(v) {
        if (v.some((e) => 'categoryId' in e)) throw new Error('categoryId 无效');
        this._anno = v;
      },
      enumerable: true
    });
    const degraded = M.attachNodeAnnotation(strict, { severity: 'a11y', title: 'T', lines: ['L'] });
    check(
      'categoryId 被拒时降级为不带分类重写，标注本体不丢',
      degraded === true && strict.annotations.length === 1 &&
      !('categoryId' in strict.annotations[0]) &&
      strict.annotations[0].labelMarkdown.indexOf('T') > 0,
      '降级写入成功且无 categoryId'
    );

    // ⑩ 不支持 annotations 的节点要安静跳过（返回 false），不能抛异常中断整批生成
    check(
      '[反向] 节点不支持 annotations 时返回 false 而非抛错',
      M.attachNodeAnnotation({ name: 'no-anno' }, { severity: 'spec', title: 'T', lines: ['L'] }) === false &&
      M.attachNodeAnnotation(null, { severity: 'spec', title: 'T', lines: ['L'] }) === false,
      '两种缺失形态均安静返回 false'
    );

    // ⑪ 端到端：全批次真跑之后，画布上必须真的存在节点级标注，
    // 且 batchSetup 里用 target 钉到具体 Pin 的那条必须落在那个 Pin 上。
    // 前面十条都是构造场景，这条才验真实调用链（离线 mock 的 pluginData 若是
    // 空实现，前十条照样能绿，只有这条会红 —— 本轮实际踩到过）。
    let annotatedNodes = 0;
    let pinHit = null;
    for (const pg of figma.root.children) {
      for (const n of pg.findAll(() => true)) {
        if (n.annotations && n.annotations.length) annotatedNodes++;
        if (n.name === 'pin/cat-service/resource/selected' && n.annotations && n.annotations.length) {
          pinHit = n;
        }
      }
    }
    check(
      '端到端：批次真跑后节点级标注确有落地，且 target 指定的 Pin 被钉上',
      annotatedNodes > 0 && !!pinHit &&
      pinHit.annotations[0].categoryId === M.ANNO_CATEGORY.a11y,
      '带标注节点 ' + annotatedNodes + ' 个；Pin 靶标 ' + (pinHit ? '命中，分类 ' + pinHit.annotations[0].categoryId : '未命中')
    );

    // ⑫ mapCanvas 的 note 参数已从「单张」放开为「单张或数组」。
    // 首页主态一次挂三张（主态 / 命中区 / 聚合圆），若数组分支写错，
    // 后两张会静默消失 —— 而画面看起来毫无异常。
    const wantCards = ['_annotation/主态 = 筛选收起', '_annotation/命中区与视觉区分离', '_annotation/聚合圆三档尺寸'];
    const foundCards = [];
    for (const pg of figma.root.children) {
      for (const n of pg.findAll((x) => wantCards.indexOf(x.name) >= 0)) {
        if (foundCards.indexOf(n.name) < 0) foundCards.push(n.name);
      }
    }
    check(
      'mapCanvas note 数组分支：首页主态三张卡全部落地（含 a11y 两张）',
      wantCards.every((w) => foundCards.indexOf(w) >= 0),
      '落地 ' + foundCards.length + ' / ' + wantCards.length +
      (foundCards.length < wantCards.length
        ? '，缺：' + wantCards.filter((w) => foundCards.indexOf(w) < 0).join(', ')
        : '')
    );
  }

  // ============================================================
  // 十一、组件契约（description，条目 [51] 第 5 步）
  //
  // 为什么要单独一节：description 是唯一「画布上看不见」的产出 —— 它不影响
  // 任何一个像素，所以前面 146 条断言全绿也完全不能说明它写没写、写对没写对。
  // 它偏偏又是接棒人在 Inspect 面板里第一眼读到的东西，静默为空的代价最大。
  //
  // 全部期望值一律从真源现算（BUTTON_SPECS / CATEGORY_COLORS / SHELL_TABS /
  // SPACING / RADIUS），不在探针里抄一份期望文本：抄本与 code.js 脱钩时，
  // 断言验的是抄本自己，永远绿（原则㊾）。
  // ============================================================
  console.log('\n--- 组件契约（Component description）---');
  if (typeof M.describeComponents !== 'function') {
    check('describeComponents 已导出', false, '未导出或不是函数');
  } else {
    // pj 在 I1 那节是块内局部变量，这里够不到，故自带一份
    const pj = (x) => JSON.stringify(x);
    // 期望的 20 个 master 名单由真源表派生，与 registerComponents 同源
    const wantNames = ['shell/status-bar']
      .concat(M.SHELL_TABS.map((t) => 'shell/bottom-tab/' + t))
      .concat(M.BUTTON_VARIANTS.map((v) => 'ui/button/' + v));
    for (const ck of Object.keys(M.CATEGORY_COLORS)) {
      wantNames.push('ui/pin/' + ck + '/resource', 'ui/pin/' + ck + '/demand');
    }

    // CAT_LIST 是 Pin 描述取中文分类名的来源，CATEGORY_COLORS 是 Pin master 的
    // 注册来源。两张表的 key 一旦分叉，就会有 Pin 拿不到描述 —— 这正是
    // batchSetup 里 describedCount !== compCount 抛错校验要拦的头号情形。
    const catKeys = Object.keys(M.CATEGORY_COLORS).slice().sort();
    const listKeys = (M.CAT_LIST || []).map((r) => r[0]).slice().sort();
    check(
      'CAT_LIST 与 CATEGORY_COLORS 的分类 key 完全一致（否则有 Pin 拿不到描述）',
      pj(catKeys) === pj(listKeys),
      pj(listKeys) + ' vs ' + pj(catKeys)
    );

    // 建一套干净的 master 交给 describeComponents，避免受前面批次实跑的影响
    const descPage = figma.createPage();
    descPage.name = 'probe/desc';
    const descHost = M.registerComponents(descPage);
    const cache = {};
    for (const c of descHost.children) {
      if (c.type === 'COMPONENT') cache[c.name] = c;
    }
    const written = M.describeComponents(cache);

    check(
      'describeComponents 写入数 == 真源派生的 master 数（一个不漏）',
      written === wantNames.length && Object.keys(cache).length === wantNames.length,
      '写入 ' + written + ' / master ' + Object.keys(cache).length + ' / 期望 ' + wantNames.length
    );

    // 名单逐项核对：只数个数会漏掉「多写一个、少写一个」正好抵消的情形
    const missing = wantNames.filter((n) => !cache[n] || !cache[n].description);
    check(
      '20 个 master 逐项都有非空 description（名单与真源派生一致）',
      missing.length === 0,
      missing.length ? '缺：' + missing.join(', ') : '全部 ' + wantNames.length + ' 项已写'
    );

    // 四段式结构：缺一段就意味着少了一类信息（用途/规格/不可改/判据）
    const sectionBad = [];
    for (const n of wantNames) {
      const d = (cache[n] || {}).description || '';
      for (const seg of ['【用途】', '【规格】', '【不可改】', '【判据】']) {
        if (d.indexOf(seg) < 0) sectionBad.push(n + ' 缺 ' + seg);
      }
    }
    check(
      '每条 description 四段式齐全（用途/规格/不可改/判据）',
      sectionBad.length === 0,
      sectionBad.length ? sectionBad.slice(0, 5).join('; ') : '全部 ' + wantNames.length + ' 项齐全'
    );

    // 按钮档：描述里的配色/圆角/内边距必须与 BUTTON_SPECS 现算值逐项对上。
    // 这条是「description 会不会与画布脱钩」的正面拦截 —— 手抄配色时必红。
    const btnBad = [];
    for (const v of M.BUTTON_VARIANTS) {
      const s = M.BUTTON_SPECS[v];
      const d = (cache['ui/button/' + v] || {}).description || '';
      const shape = s.radius === M.RADIUS.full ? '全圆角胶囊' : '圆角 ' + s.radius;
      const wantBits = [
        s.usage,
        s.fill || '无（透明）',
        s.textColor,
        shape,
        M.SPACING.md + '/' + M.SPACING.lg
      ];
      if (s.stroke) wantBits.push(s.stroke + ' 1px');
      for (const bit of wantBits) {
        if (d.indexOf(bit) < 0) btnBad.push(v + ' 缺「' + bit + '」');
      }
    }
    check(
      '六类按钮 description 的配色/圆角/内边距与 BUTTON_SPECS 现算值逐项对齐',
      btnBad.length === 0,
      btnBad.length ? btnBad.slice(0, 5).join('; ') : '6 档全部对齐（含 usage 与描边）'
    );

    // Pin 档：分类色十六进制取自 CATEGORY_COLORS，且必须带两段 Pin 专有约束 ——
    // 命中区豁免与「Instance 不可增删子节点」，后者是本轮实测踩到过的硬约束
    const pinBad = [];
    for (const ck of Object.keys(M.CATEGORY_COLORS)) {
      for (const sd of ['resource', 'demand']) {
        const d = (cache['ui/pin/' + ck + '/' + sd] || {}).description || '';
        if (d.indexOf(M.CATEGORY_COLORS[ck]) < 0) pinBad.push(ck + '/' + sd + ' 缺分类色');
        if (d.indexOf('【命中区】') < 0) pinBad.push(ck + '/' + sd + ' 缺命中区');
        if (d.indexOf('【结构约束】') < 0) pinBad.push(ck + '/' + sd + ' 缺结构约束');
      }
    }
    check(
      '十个 Pin description 的分类色取自 CATEGORY_COLORS，且带命中区与结构约束两段',
      pinBad.length === 0,
      pinBad.length ? pinBad.slice(0, 5).join('; ') : '10 项全部对齐'
    );

    // 无障碍声明只该出现在需要它的档位上：disabled 是刻意不达标的，
    // 不声明就会被当成可点元素复用；Tab 的 44 高来自命中区扩展，须留痕
    const a11yBad = [];
    if (((cache['ui/button/disabled'] || {}).description || '').indexOf('【无障碍】') < 0) {
      a11yBad.push('ui/button/disabled');
    }
    for (const t of M.SHELL_TABS) {
      if (((cache['shell/bottom-tab/' + t] || {}).description || '').indexOf('【无障碍】') < 0) {
        a11yBad.push('shell/bottom-tab/' + t);
      }
    }
    check(
      'disabled 档与三个 Tab 档带【无障碍】声明',
      a11yBad.length === 0,
      a11yBad.length ? '缺：' + a11yBad.join(', ') : 'disabled + 3 个 Tab 全部声明'
    );

    // 反向①：删掉一个 master 后写入数必须随之减少 ——
    // 这是 batchSetup 里 describedCount !== compCount 抛错校验的触发条件
    const cache2 = {};
    for (const k of Object.keys(cache)) cache2[k] = cache[k];
    delete cache2['ui/button/primary'];
    for (const k of Object.keys(cache2)) cache2[k].description = '';
    const written2 = M.describeComponents(cache2);
    check(
      '[反向] 少一个 master 时写入数随之减少（抛错校验的触发条件成立）',
      written2 === wantNames.length - 1,
      '写入 ' + written2 + '，期望 ' + (wantNames.length - 1)
    );

    // 反向②：非 COMPONENT 节点不该被写描述（避免把契约写到 Instance 上）
    const fakeCache = { 'ui/button/primary': M.box('not-a-component', 'VERTICAL', {}) };
    const written3 = M.describeComponents(fakeCache);
    check(
      '[反向] cache 里的非 COMPONENT 节点被跳过，不写描述',
      written3 === 0 && !fakeCache['ui/button/primary'].description,
      '写入 ' + written3 + ' 条'
    );

    // 端到端：批次真跑后画布上确有带描述的 master。
    // 前面几条都是探针自己调 describeComponents 造的场景 —— 若 batchSetup 忘了
    // 接上这个调用，它们照样全绿，只有这条会红。
    // 名单用「集合相等」而非「全部 COMPONENT 都有描述」：本探针在 planStats
    // 那节为核对数量又裸注册过一套 master（无描述），那是探针自身的临时产物。
    const describedNames = [];
    for (const pg of figma.root.children) {
      if (pg.name === 'probe/desc') continue;
      for (const n of pg.findAll((x) => x.type === 'COMPONENT')) {
        if (n.description && describedNames.indexOf(n.name) < 0) describedNames.push(n.name);
      }
    }
    check(
      '端到端：批次真跑后画布上带描述的 master 名单 == 真源派生的 20 项',
      pj(describedNames.slice().sort()) === pj(wantNames.slice().sort()),
      '画布上 ' + describedNames.length + ' 项' +
      (describedNames.length !== wantNames.length
        ? '，差集：' + wantNames.filter((n) => describedNames.indexOf(n) < 0).join(', ')
        : '')
    );
  }

  // ============================================================

  // ============================================================
  // 十二、动效规格（annotation，条目 [51] 第 6 步 / I5）
  //
  // 为什么这一节的断言比别的维度更要紧：色彩字号间距圆角都进了 Variables，
  // 有 Figma 自己的一致性机制兜着 —— 改了变量，画布上所有消费点跟着变。
  // 动效进不了 Variables（createVariable 只接受 COLOR/FLOAT/STRING/BOOLEAN），
  // 它的唯一一致性机制就是这几条断言。这里漏了，动效规格就没有任何东西守着。
  //
  // 要守住四件事：
  // ① MOTION 六档齐全且字段完整（缺一档就是漏一类动效，画布上看不出来）；
  // ② 画布文本与 annotation 正文都由 motionLine 现算，不存在第二份手抄副本；
  // ③ 四个挂到具体页面的档（page/press/fade/layer + 弹层两档）真的钉在了
  //    target 节点上，且分类是 Interaction —— 不然 Dev Mode 里读不到；
  // ④ 时长条宽度真的由 dur 派生（它是「快慢差异」在静态画布上唯一的表达）。
  // ============================================================
  console.log('\n--- 动效规格（I5）---');
  {
    const pj = (x) => JSON.stringify(x);
    const motionKeys = Object.keys(M.MOTION || {});

    // ① 六档齐全 + 字段完整。档名写死是有意的：它们是 PRD §1.4.8/§6.8 的场景
    // 枚举，少一个就是漏一类动效，而漏动效在画布上完全看不出来（这正是 I5
    // 存在的理由）。改档名必须同步改 PRD，故让它在这里亮红。
    const wantMotion = ['page', 'sheet', 'mask', 'press', 'fade', 'layer'];
    check(
      'MOTION 六档齐全（对应 PRD §1.4.8 的场景枚举 + §6.8 图层切换）',
      pj(motionKeys.slice().sort()) === pj(wantMotion.slice().sort()),
      pj(motionKeys)
    );
    const fieldBad = [];
    for (const k of motionKeys) {
      const m = M.MOTION[k];
      if (typeof m.scene !== 'string' || !m.scene) fieldBad.push(k + '.scene');
      if (typeof m.dur !== 'number' || m.dur <= 0) fieldBad.push(k + '.dur');
      if (typeof m.ease !== 'string' || !m.ease) fieldBad.push(k + '.ease');
      if (typeof m.impl !== 'string' || !m.impl) fieldBad.push(k + '.impl');
      // prd 字段是判据回标，缺了就无法核对到条款，等于规格没来源
      if (typeof m.prd !== 'string' || m.prd.indexOf('PRD §') !== 0) fieldBad.push(k + '.prd');
    }
    check(
      'MOTION 每档的 scene/dur/ease/impl/prd 五字段齐全且 prd 可回标',
      fieldBad.length === 0,
      fieldBad.length ? '缺失：' + fieldBad.join(', ') : motionKeys.length + ' 档全部齐全'
    );

    // ② motionSpecLines 必须逐档现算，不能只写一部分。
    // 「六档全列」是设计决定（动效档之间有联动，只给单档看不出配合关系），
    // 这条断言把那个决定钉死。
    const specLines = M.motionSpecLines();
    const lineMiss = motionKeys.filter(
      (k) => !specLines.some((l) => l.indexOf('motion/' + k + '：' + M.motionLine(k)) === 0)
    );
    check(
      'motionSpecLines 六档全列，且每行内容由 motionLine 现算（无手抄副本）',
      lineMiss.length === 0 && specLines.length === motionKeys.length + 2,
      lineMiss.length ? '缺档：' + lineMiss.join(', ') : specLines.length + ' 行（六档 + 承载说明 + 缓动口径）'
    );
    // 正文首行必须交代「为什么这里没有变量」：读卡的人手边只有这张卡，
    // 找不到 motion 变量时若无解释，他会自己拟一套时长，规格随即分叉。
    check(
      'motionSpecLines 正文交代了「动效无法进 Token 层」的原因（防实现侧自拟时长）',
      specLines[0].indexOf('createVariable') > 0 &&
      specLines[0].indexOf('COLOR/FLOAT/STRING/BOOLEAN') > 0,
      '首行含 API 层原因'
    );

    // ③ 画板 D 的六行文本与时长条：文本必须等于 motionLine 现算值（全等，
    // 不是包含），宽度必须等于 dur × MOTION_PX_PER_MS。前者防手抄，后者防
    // 「条画了但不表意」。比例也从被测模块取，不在这里手抄 0.5。
    let motionBoard = null;
    for (const pg of figma.root.children) {
      const hit = pg.findAll((n) => n.name === 'board/动效规格 [PRD §1.4.8]');
      if (hit.length) { motionBoard = hit[0]; break; }
    }
    check('画板 D「动效规格」已落到画布上', !!motionBoard,
      motionBoard ? '已找到' : '未找到 —— batchSetup 未 push motionBoard？');
    if (motionBoard) {
      const pxPerMs = M.MOTION_PX_PER_MS;
      const barW = (k) => Math.round(M.MOTION[k].dur * pxPerMs);
      const rowBad = [];
      for (const k of motionKeys) {
        const bar = motionBoard.findAll((n) => n.name === '_motion-bar-' + k)[0];
        const meta = motionBoard.findAll((n) => n.name === '_motion-meta-' + k)[0];
        if (!bar) { rowBad.push(k + ':无时长条'); continue; }
        if (!meta) { rowBad.push(k + ':无文本'); continue; }
        if (Math.round(bar.width) !== barW(k)) {
          rowBad.push(k + ':条宽 ' + Math.round(bar.width) + '≠' + barW(k));
        }
        const txt = meta.children[0];
        if (!txt || txt.characters !== M.motionLine(k)) {
          rowBad.push(k + ':文本≠motionLine（' + (txt ? txt.characters : 'n/a') + '）');
        }
      }
      check(
        '画板 D 六行：文本全等 motionLine 现算值，条宽全等 dur × MOTION_PX_PER_MS',
        rowBad.length === 0,
        rowBad.length ? rowBad.join('; ') : motionKeys.length + ' 行全部对齐'
      );

      // ③之二 槽位等宽（2026-08-27 实机截图发现后补的断言）：
      // 条宽各档不同，若不套等宽槽位，右侧文本左边缘会随条长参差，六档没法
      // 竖向对照扫读。这是**只有看图才发现、探针原先完全查不出**的一类错 ——
      // 六行文本内容全对、条宽也全对，唯独排布让人读不成。补两条：
      //   槽位全部等宽，且宽度等于最长档（不是某个写死的数）。
      const slotWs = motionKeys.map((k) => {
        const slot = motionBoard.findAll((n) => n.name === '_motion-slot-' + k)[0];
        return slot ? Math.round(slot.width) : -1;
      });
      const wantSlotW = Math.max(...motionKeys.map(barW));
      check(
        '画板 D 六档时长条套等宽槽位，文本左边缘对齐（六槽同宽）',
        slotWs.length === motionKeys.length && slotWs.every((w) => w === wantSlotW),
        '槽宽 ' + pj(slotWs) + '，期望全部 = 最长档 ' + wantSlotW
      );
      // 槽位不能比条还窄：那样条会被 Auto Layout 压缩，长度不再等于时长，
      // 而画面上只是「条短了一点」，看不出是错的
      const slotTooNarrow = motionKeys.filter((k, i) => slotWs[i] < barW(k));
      check(
        '无槽位窄于其内时长条（否则条被压缩、长度不再表意）',
        slotTooNarrow.length === 0,
        slotTooNarrow.length ? '过窄：' + slotTooNarrow.join(', ') : '六档槽位均 ≥ 条宽'
      );

      // 两张卡要在 page 级找，不能限定在画板内（本轮首跑即被这条捞出）：
      // 规格板同样走 layout()，detachAnnotations 已把卡提到画板右侧外部、
      // 挂到 page 上。限定在 motionBoard 内找必然为空 —— 这是探针自身的错，
      // 不是被测代码的错。判据仍是「卡确实存在且档位/靶标/正文对」。
      //
      // ⚠ 真机复核盲区（2026-08-27 实机复验时踩到）：下面 readAnno 读的
      // setPluginData 是**按插件 ID 分命名空间**的。批次脚本由 s2s 插件写入，
      // 而 figma-console-mcp 的 figma_execute 跑在 Desktop Bridge 插件里，
      // 读同一个 key 只会得到空字符串 —— 那不是数据丢了，是换了命名空间。
      // 故凡依赖 pluginData 的断言，真机侧无法用 Bridge 独立复核；真机要核
      // 只能走另两条不分插件的路径：① 节点的 annotations 属性；② 卡内 TEXT
      // 文本。两者与 pluginData 同源（见 code.js 的 annotation()），可互证。
      const findCard = (name) => {
        for (const pg of figma.root.children) {
          const hit = pg.findAll((n) => n.name === name);
          if (hit.length) return hit[0];
        }
        return null;
      };
      const readAnno = (card) => {
        if (!card) return null;
        try { return JSON.parse(card.getPluginData('anno')); } catch (e) { return null; }
      };
      // 六档总览卡挂 interact 档、钉在 sheet 档时长条上
      const ovData = readAnno(findCard('_annotation/动效规格六档'));
      check(
        '六档总览卡为 interact 档且 target 钉在 _motion-bar-sheet 上',
        !!ovData && ovData.severity === 'interact' && ovData.target === '_motion-bar-sheet' &&
        pj(ovData.lines) === pj(specLines),
        ovData ? ovData.severity + ' / ' + ovData.target : '取不到 pluginData'
      );
      // 补充口径卡必须是 info 档：它们不是判据。混成 interact/spec 会让评审
      // 把「另一节的口径」当成本板六档的一部分去实现。
      // 2026-08-27 条目 [60]：卡名由「动效规格的两处待补」改为「动效规格的三条补充
      // 口径」（前两条已回写 PRD §1.4.8），本断言随之改名。**改的是卡名不是判据**，
      // info 档与 3 条这两项要求原样保留。
      const todoData = readAnno(findCard('_annotation/动效规格的三条补充口径'));
      check(
        '「三条补充口径」卡为 info 档（补充口径不得被当成本板六档规格读）',
        !!todoData && todoData.severity === 'info' && todoData.lines.length === 3,
        todoData ? todoData.severity + ' / ' + todoData.lines.length + ' 条' : '取不到 pluginData'
      );
      // 靶标节点必须真的被钉上节点级 annotation：卡的 pluginData 对了不等于
      // Dev Mode 里读得到 —— target 拼错时 detachAnnotations 会静默退回整页。
      const barSheet = motionBoard.findAll((n) => n.name === '_motion-bar-sheet')[0];
      check(
        '_motion-bar-sheet 真的被钉上 Interaction 分类的节点级标注',
        !!barSheet && !!barSheet.annotations && barSheet.annotations.length > 0 &&
        barSheet.annotations[0].categoryId === M.ANNO_CATEGORY.interact,
        barSheet && barSheet.annotations && barSheet.annotations.length
          ? '分类 ' + barSheet.annotations[0].categoryId
          : '未钉上'
      );
    }

    // ④ 四处页面级落点：卡在不在、档位对不对、target 钉中没有。
    // 逐条列出而非只数总量：动效档漏挂一处在画面上零征兆，只有点名才拦得住。
    const wantAnchors = [
      ['_annotation/按压反馈动效', 'btn/capsule/登录 / 注册'],
      ['_annotation/图层切换动效', '_overlay-cats'],
      ['_annotation/列表加载动效', '_list-body'],
      ['_annotation/页面转场动效', '_nav-left'],
      ['_annotation/弹层进场动效', '_sheet-mask']
    ];
    const anchorBad = [];
    for (const [cardName, targetName] of wantAnchors) {
      let card = null;
      for (const pg of figma.root.children) {
        const hit = pg.findAll((n) => n.name === cardName);
        if (hit.length) { card = hit[0]; break; }
      }
      if (!card) { anchorBad.push(cardName + ':卡未落地'); continue; }
      let d = null;
      try { d = JSON.parse(card.getPluginData('anno')); } catch (e) { d = null; }
      if (!d) { anchorBad.push(cardName + ':无 pluginData'); continue; }
      if (d.severity !== 'interact') anchorBad.push(cardName + ':档位=' + d.severity);
      if (d.target !== targetName) anchorBad.push(cardName + ':target=' + d.target);
    }
    check(
      '四类动效档钉到对应页面节点上（按压/图层/列表/转场 + 弹层进场）',
      anchorBad.length === 0,
      anchorBad.length ? anchorBad.join('; ') : wantAnchors.length + ' 处全部命中'
    );

    // ⑤ 页面级卡的正文也必须走 motionLine：这是最容易退化成手抄的地方 ——
    // 挂卡时顺手把「80ms ease-out」敲进去，改 MOTION 后画布纹丝不动。
    const inlineBad = [];
    for (const [cardName] of wantAnchors) {
      let card = null;
      for (const pg of figma.root.children) {
        const hit = pg.findAll((n) => n.name === cardName);
        if (hit.length) { card = hit[0]; break; }
      }
      if (!card) continue;
      let d = null;
      try { d = JSON.parse(card.getPluginData('anno')); } catch (e) { d = null; }
      if (!d) continue;
      // 卡内至少一行须与某一档的 motionLine 现算值前缀相符
      const anyMatch = motionKeys.some((k) => d.lines.some((l) => l.indexOf(M.motionLine(k)) === 0));
      if (!anyMatch) inlineBad.push(cardName);
    }
    check(
      '页面级动效卡的正文取自 motionLine，未在挂卡处手抄时长',
      inlineBad.length === 0,
      inlineBad.length ? '疑似手抄：' + inlineBad.join(', ') : '全部现算'
    );

    // ⑥ 首页筛选展开态的画布文案也必须现算（三处手抄里唯一会渲染到画布、
    // 也就是唯一会被评审当判据读的一处，本轮已改）。这条查的是**画布文本**，
    // 与上面查 pluginData 的那几条互补。
    let expandedCard = null;
    for (const pg of figma.root.children) {
      const hit = pg.findAll((n) => n.name === '_annotation/展开态');
      if (hit.length) { expandedCard = hit[0]; break; }
    }
    const expandedTexts = expandedCard
      ? expandedCard.findAll((n) => n.type === 'TEXT').map((n) => n.characters)
      : [];
    check(
      '首页展开态卡的动效行由 motionLine 现算（画布上不再有手抄的 240ms spring）',
      expandedTexts.some((t) => t.indexOf(M.motionLine('sheet')) > 0),
      expandedCard ? pj(expandedTexts.slice(-1)) : '未找到展开态卡'
    );

    // ⑦ 反向用例：改一档 dur 后，画板行文本与 annotation 正文必须同步变。
    // 若哪天有人把 motionLine 里的现算换成常量串，这条会红。
    const savedDur = M.MOTION.press.dur;
    M.MOTION.press.dur = 999;
    const afterLine = M.motionLine('press');
    const afterSpec = M.motionSpecLines();
    M.MOTION.press.dur = savedDur;
    check(
      '[反向] 改 MOTION.press.dur 后 motionLine 与 motionSpecLines 同步变（未退化为常量）',
      afterLine.indexOf('999ms') > 0 &&
      afterSpec.some((l) => l.indexOf('999ms') > 0) &&
      M.motionLine('press').indexOf(savedDur + 'ms') > 0,
      '现算生效且已复原为 ' + savedDur + 'ms'
    );
  }

  // ============================================================
  // 十三、条目 [70]：五项图上问题的修复（P1–P5）
  //
  // 这一节守的四件事，共同点是「画布上看着都对，只有量过才知道错」：
  // ① 画布正式内容零 emoji（P3）—— 本节最要紧的一条。emoji 的危害不在离线也
  //    不在单端截图，而在三端字形不一 + 色值完全不受 paintOf(role) 控制：
  //    §1.4.2 实算的对比度对它一概无效。这类错永远是「随手写一个 🟢」引入的，
  //    源码 review 也极易放过（它就在一句正常文案里），故必须做成机读断言，
  //    与 TIGHT_GAP 用量锁定同一防护思路。
  // ② 完整度三档必须有文字通道（P3 的可访问性内核）—— 改之前颜色是三档唯一
  //    载体，色弱用户无法区分。断言查「档名文字在不在」而不是「色点在不在」：
  //    色点谁都不会漏，漏的恰恰是文字。
  // ③ 五页尾部元素真的贴底（P1+P2）—— 判据是「spacer 存在且 layoutGrow=1 且
  //    它后面还有节点」。三个条件缺一都会退回原状：有 spacer 没 grow 是死的
  //    1px；有 grow 但 spacer 排在末位，则什么都没被推下去。
  // ④ selectField 不超可用宽（P5 顺手修的几何 bug）—— listRow 写死 390 宽，
  //    塞进 lg 内边距的页面里比可用宽 358 宽出 32px，画面上只是「贴边」，
  //    看不出是溢出。
  // ============================================================
  console.log('\n--- 条目 [70]：P1–P5 修复 ---');
  {
    const pj = (x) => JSON.stringify(x);
    // 可用宽从真源现算，不写死 358：SPACING.lg 若哪天调了，这里要跟着变，
    // 而不是让断言拿一个过期数字去核（原则㊾：数字只能有一个出处）
    const CANVAS_W_AVAIL = M.CANVAS.w - M.SPACING.lg * 2;

    // ---------- P3：画布正式内容零 emoji ----------
    //
    // 扫的是**真跑出来的 TEXT 节点**而非源码：源码里的注释与 figma.notify 文案
    // 允许留 emoji（不进画布、不受三端字体影响），查源码会把它们误报成问题。
    //
    // 区间取法：用 Unicode 属性 \p{Emoji_Presentation}（「默认按彩色 emoji 呈现」
    // 的字符集）而非手写码点区间。首版手写 U+2600–27BF 等区间时踩了两头：
    //   ① 漏 —— ✨(U+2728) 在区间内但我首版没把该区间写进去，画布上漏网一处；
    //   ② 误 —— 该区间也含 ✓(U+2713)、→、‹›，它们是**标点/几何符号**，
    //      默认黑白呈现、受 paintOf 控制，正是我们用来替代 emoji 的东西。
    // Emoji_Presentation 恰好把这条线画准：✨🟢✅📞 全捕获，✓→‹› 全放过。
    // 加 \uFE0F 是因为「⚠️」那类靠变体选择符强制彩色呈现的组合，基字符本身
    // 不在该属性内。
    const EMOJI_RE = /[\p{Emoji_Presentation}\uFE0F]/u;
    const emojiHits = [];
    for (const pg of figma.root.children) {
      for (const t of pg.findAll((n) => n.type === 'TEXT')) {
        if (EMOJI_RE.test(t.characters)) {
          emojiHits.push('"' + t.characters.slice(0, 24) + '"@' + (t.parent ? t.parent.name : '?'));
        }
      }
    }
    check(
      '画布正式内容零 emoji（三端字形不一且色值不受 paintOf 控制，§1.4.2 对比度对其无效）',
      emojiHits.length === 0,
      emojiHits.length
        ? '发现 ' + emojiHits.length + ' 处：' + emojiHits.slice(0, 8).join(' | ')
        : '全部页面 TEXT 节点已扫，零命中'
    );

    // 反向：往画布上注入一个 🟢，验上面那条判据真的会红。
    // 不改源码而是直接改节点文本 —— 验的是判据本身，源码怎么写都拦得住。
    {
      const victim = figma.root.children[0].findAll((n) => n.type === 'TEXT')[0];
      const saved = victim.characters;
      victim.characters = '完整度 🟢';
      const caught = EMOJI_RE.test(victim.characters);
      victim.characters = saved;
      check(
        '[反向] 注入 🟢 后「零 emoji」判据确实触发（且已复原）',
        caught && !EMOJI_RE.test(victim.characters),
        caught ? '已检出并复原为 "' + saved.slice(0, 16) + '"' : '未检出 —— 判据区间需扩大'
      );
    }

    // ---------- P3：completenessTag 三档的色点 role 与文字通道 ----------
    //
    // 期望 role 在这里写死是有意的：它们是 PRD §9.8「完整度三档」到 §1.4.2
    // 语义色的映射本身，改映射必须同步改 PRD，故让它在此亮红。
    const wantDot = { green: 'color/success', yellow: 'color/warning', red: 'color/error' };
    const wantLabel = { green: '完整', yellow: '半完整', red: '待补充' };
    /**
     * 取一个 svgIcon 节点的实际着色。
     *
     * 必须往里钻一层：svgIcon() 把外框 fills 清空（node.fills = []），
     * 颜色落在内部 VECTOR 上。首版直接比外框 fills，三档全报「role 不符」——
     * 又一次「取值路径不对却报成内容问题」（同本轮 probe-token-vars 的 CARD_SIG）。
     * @param {Object} icon svgIcon 产出的节点
     * @returns {Array|null} 内部矢量的 fills，取不到时返回 null
     */
    const iconFills = (icon) => {
      if (!icon) return null;
      const vec = icon.findOne
        ? icon.findOne((n) => n.type === 'VECTOR' || n.type === 'BOOLEAN_OPERATION')
        : null;
      return vec ? vec.fills : null;
    };
    const ctBad = [];
    for (const lv of Object.keys(wantDot)) {
      const tag = M.completenessTag(lv);
      const dot = tag.children[0];
      const lab = tag.children[1];
      if (!dot) ctBad.push(lv + ':无色点节点');
      else if (pj(iconFills(dot)) !== pj([M.paintOf(wantDot[lv])])) {
        ctBad.push(lv + ':色点 role 不符(' + pj(iconFills(dot)) + ')');
      }
      // 文字通道是本次可访问性修正的全部内容：缺了就退回「颜色是唯一载体」
      if (!lab || lab.type !== 'TEXT' || lab.characters !== wantLabel[lv]) {
        ctBad.push(lv + ':档名文字缺失或不符(' + (lab ? lab.characters : 'n/a') + ')');
      }
    }
    check(
      'completenessTag 三档色点取 success/warning/error 且各带档名文字（颜色不再是唯一语义通道）',
      ctBad.length === 0,
      ctBad.length ? ctBad.join('; ') : '三档色点 role + 文字「完整/半完整/待补充」全部对齐'
    );

    // 色点边长必须跟随字阶派生，不许写死：写死 10px 配 h3 偏小、配 caption 会
    // 盖过档名，把刚补上的文字通道又压回次要位置
    const dotSizes = ['caption', 'small', 'h3'].map((sc) => {
      const t = M.completenessTag('green', sc);
      return Math.round(t.children[0].width);
    });
    check(
      'completenessTag 色点边长随字阶派生（写死尺寸会让文字通道被色点压回次要位置）',
      new Set(dotSizes).size === 3 && dotSizes[0] < dotSizes[2],
      'caption/small/h3 三档色点边长 = ' + pj(dotSizes)
    );

    // dot-solid 图标定义必须真存在且是实心圆：completenessTag 的三处调用全靠它，
    // 图标名拼错时 svgIcon 拿到 undefined，画面上只是「少个点」，不报错
    const dotDef = (M.ICON_PATHS || {})['dot-solid'];
    check(
      "ICON_PATHS['dot-solid'] 已定义（三档色点的唯一矢量来源，缺失时只是静默少个点）",
      !!dotDef && typeof dotDef.d === 'string' && dotDef.d.indexOf('<path') === 0 && !!dotDef.vb,
      dotDef ? 'viewBox=' + dotDef.vb : '未定义'
    );

    // doneTag：勾是矢量而非 ✅，且文字如实透传
    {
      const dt = M.doneTag('已实名');
      const tick = dt.children[0];
      const lab = dt.children[1];
      check(
        'doneTag 用矢量勾 + 文字（替掉 ✅，勾色走 success role）',
        !!tick && pj(iconFills(tick)) === pj([M.paintOf('color/success')]) &&
        !!lab && lab.characters === '已实名',
        lab ? '勾色 ' + pj(iconFills(tick)) + '，文字「' + lab.characters + '」' : '结构不符'
      );
    }

    // ---------- P4：详情页描述区 ----------
    {
      const detail = M.buildDetail();
      const desc = byName(detail, '_description');
      const body = detail.children.find((c) => c.name === '_body');
      const idxOf = (nm) => body.children.findIndex((c) => c.name === nm);
      check(
        '详情页有 _description 卡且正文非空（PRD §7.4.1 稿图要求，改前稿缺实现有）',
        !!desc && desc.children.length === 2 &&
        desc.children[1].type === 'TEXT' && desc.children[1].characters.length > 20,
        desc ? '正文 ' + desc.children[1].characters.length + ' 字' : '未找到 _description'
      );
      // 长文本必须 FILL + HEIGHT：默认 WIDTH_AND_HEIGHT 会一路 hug 撑破 390 画框，
      // 而 mock 的 HUG 计算同样会让宽度超出，故这条离线就能拦住
      check(
        '_description 正文设 textAutoResize=HEIGHT 且 layoutSizingHorizontal=FILL（否则撑破 390）',
        !!desc && desc.children[1].textAutoResize === 'HEIGHT' &&
        desc.children[1].layoutSizingHorizontal === 'FILL' &&
        Math.round(desc.width) <= CANVAS_W_AVAIL,
        desc ? 'autoResize=' + desc.children[1].textAutoResize +
          '，sizing=' + desc.children[1].layoutSizingHorizontal +
          '，卡宽 ' + Math.round(desc.width) : 'n/a'
      );
      // 次序：模板字段 → 描述 → 信任卡。「是什么 → 怎么说 → 信不信」的递进，
      // 描述挪到信任卡之后就变成了先判可信度再给内容
      check(
        '详情页次序为 模板字段 → 描述 → 信任卡（PRD §7.4.1 稿图次序）',
        idxOf('_template-fields') >= 0 &&
        idxOf('_template-fields') < idxOf('_description') &&
        idxOf('_description') < idxOf('_trust-card'),
        '模板 ' + idxOf('_template-fields') + ' / 描述 ' + idxOf('_description') +
        ' / 信任卡 ' + idxOf('_trust-card')
      );
    }

    // ---------- P5：发布页字段形态统一 ----------
    {
      const pub = M.buildPublish();
      const body = pub.children.find((c) => c.name === '_body');
      // 四个字段全部走 field/* 命名：改前「选择分类/地点」是 row/*（listRow），
      // 与另两个 field 并列时看不出哪个能输入、哪个是跳转
      const fieldNames = body.children
        .filter((c) => c.name.indexOf('field/') === 0)
        .map((c) => c.name);
      check(
        '发布页四字段同为 field/* 形态且次序为 分类→标题→薪资→地点（分类决定后续模板，须在最前）',
        pj(fieldNames) === pj(['field/选择分类', 'field/标题', 'field/薪资', 'field/地点']),
        pj(fieldNames)
      );
      // 「可输入」与「可跳转」的差异必须留住：做成一模一样，用户会去点它然后
      // 等键盘弹出。差异载体就是框内右端那个 ›
      const sel = M.selectField('地点', null, '地图选点');
      const ctrl = sel.children[1];
      const inp = M.field('标题', '一句话说清你要发什么');
      const inpCtrl = inp.children[1];
      check(
        'selectField 框内右端有 › 而 field 没有（区分可跳转与可输入，否则用户点了等键盘）',
        allText(ctrl).indexOf('›') >= 0 && allText(inpCtrl).indexOf('›') < 0,
        'select 内文本 ' + pj(allText(ctrl)) + '；field 内文本 ' + pj(allText(inpCtrl))
      );
      // 两者高度与宽度必须完全一致：形态统一的实质是同尺寸，只差那个 ›
      check(
        'selectField 与 field 同宽同高（形态统一的实质；宽须 = 可用宽 358，不是 listRow 的 390）',
        Math.round(sel.width) === CANVAS_W_AVAIL &&
        Math.round(sel.width) === Math.round(inp.width) &&
        Math.round(ctrl.height) === Math.round(inpCtrl.height),
        'select ' + Math.round(sel.width) + '×' + Math.round(ctrl.height) +
        '，field ' + Math.round(inp.width) + '×' + Math.round(inpCtrl.height) +
        '，可用宽 ' + CANVAS_W_AVAIL
      );
      // 反向：证明换掉 listRow 是必要的 —— 它写死 390 宽，塞进 lg 内边距页面
      // 会比可用宽多出 2×lg，画面上只是「贴边」，看不出是溢出
      const lr = M.listRow('地点', '地图选点');
      check(
        '[反向] listRow 宽 390 确实超出 lg 内边距下的可用宽 358（P5 换形态的几何依据）',
        Math.round(lr.width) === M.CANVAS.w &&
        Math.round(lr.width) - CANVAS_W_AVAIL === M.SPACING.lg * 2,
        'listRow ' + Math.round(lr.width) + ' - 可用 ' + CANVAS_W_AVAIL +
        ' = 超出 ' + (Math.round(lr.width) - CANVAS_W_AVAIL) + 'px'
      );
      // FLOW_LINKS 必须跟着改名走：selectField 让节点名从 row/* 变成 field/*，
      // 漏改这两条则 Present 模式点下去无反应，而画布上毫无征兆
      const renamed = M.FLOW_LINKS.filter(
        (l) => l[0] === 'publish-screen' && l[1].indexOf('field/') === 0
      ).map((l) => l[1] + '→' + l[2]);
      const stale = M.FLOW_LINKS.filter(
        (l) => l[0] === 'publish-screen' && l[1].indexOf('row/') === 0
      );
      check(
        'FLOW_LINKS 已随 row/*→field/* 改名同步（漏改则 Present 模式点击无反应且画布无征兆）',
        renamed.length === 2 && stale.length === 0,
        pj(renamed) + (stale.length ? '；仍有旧名 ' + pj(stale.map((l) => l[1])) : '')
      );
    }

    // ---------- P1+P2：四页尾部元素贴底 ----------
    //
    // 逐页点名而非只数总量：漏一页在画布上零征兆（就是「下面空着」，
    // 而空着本来也没人能判断是有意留白还是稿子没画完 —— 这恰是 P1 的病灶）。
    // 判据三件套：spacer 在、grow=1、它后面还有节点。
    // 节点名口径：button() 把 Instance 名统一拼成 'btn/' + variant + '/' + label
    //（code.js:1924），故必须带 variant 段 —— 首版写成 btn/capsule/… 五页全报
    // 「尾部缺」，而实际用的是 primary/secondary。bottomTab 则走 instanceOf，
    // 命中 master 时名为 shell/bottom-tab/我的、未命中时回落 _bottom-tab，
    // 故只匹配两者共有的 'bottom-tab' 片段，不锁定其中任一形态。
    //
    // 2026-08-29 从五页减为四页：trust 页原先靠 pushToBottom 把红线 annotation
    // 压到页脚，实机证明该修法失效（详见下方「annotation 不得作为唯一尾部元素」
    // 一条），已改为补足 §4.4 内容让页面自然填满，不再用 spacer。
    // 2026-08-31（条目 [70] 第八段）从四页增为六页：detail-offline 与 ai-confirm
    // 两页改前根本没走 pushToBottom（内容止于 555 / 795px，主按钮悬在页中间），
    // 而「四页全绿」这条断言只点了它没点的四页，所以两页漏掉时全程零告警 ——
    // 凡新增一页带底部主操作，就必须同时进这张表，否则这条断言的覆盖面会静默缩水。
    //
    // contact 的尾部节点随本轮改版换名：原先是 btn/primary/拨打电话 +
    // btn/secondary/复制微信号 两键并列（与 §7.4.2「不做双卡片并列」相反），
    // 现改为单键 btn/secondary/举报本次发布 —— 主操作「查看完整号码并外呼」
    // 刻意留在联系方式卡内不贴底（见 code.js buildContact 注释）。
    // variant 用 secondary 而非 ghost：ghost 无描边无底色，贴底后渲染成一行
    // 页脚文字链，举报是安全兜底入口，「看不出能点」的代价大于权重略高。
    const tailPages = [
      ['buildContact', '_body', ['btn/secondary/举报本次发布']],
      ['buildPublish', '_body', ['btn/primary/发布']],
      ['buildDetail', '_body', ['btn/primary/联系 TA']],
      ['buildDetailOffline', '_body', ['btn/disabled/联系 TA']],
      ['buildAiConfirm', '_body', ['btn/primary/确认发布']],
      // profile 无统一 _body，三段直接挂画框，故 spacer 插在画框层
      ['buildProfile', null, ['bottom-tab']]
    ];
    const tailBad = [];
    for (const [fn, holderName, wantTail] of tailPages) {
      const frame = M[fn]();
      const holder = holderName
        ? frame.children.find((c) => c.name === holderName)
        : frame;
      if (!holder) { tailBad.push(fn + ':无容器 ' + holderName); continue; }
      const kids = holder.children;
      const spIdx = kids.findIndex((c) => c.name === '_spacer');
      if (spIdx < 0) { tailBad.push(fn + ':无 _spacer'); continue; }
      if (kids[spIdx].layoutGrow !== 1) {
        tailBad.push(fn + ':_spacer.layoutGrow=' + kids[spIdx].layoutGrow + '（死的 1px）');
      }
      if (spIdx === kids.length - 1) { tailBad.push(fn + ':_spacer 排在末位，什么都没被推下去'); continue; }
      // 期望的尾部节点必须都排在 spacer 之后。用包含匹配而非前缀匹配：
      // bottomTab 命中 master 时名为 shell/bottom-tab/我的，前缀是 shell/
      for (const nm of wantTail) {
        const at = kids.findIndex((c) => c.name.indexOf(nm) >= 0);
        if (at < 0) tailBad.push(fn + ':尾部缺 ' + nm);
        else if (at < spIdx) tailBad.push(fn + ':' + nm + ' 仍在 spacer 之前');
      }
      // 容器本身也得 grow，否则 spacer 撑的是一个抱内容的容器，等于没撑
      if (holderName && holder.layoutGrow !== 1) {
        tailBad.push(fn + ':' + holderName + '.layoutGrow=' + holder.layoutGrow + '（容器不 grow，spacer 无空间可撑）');
      }
    }
    check(
      tailPages.length + ' 页尾部元素贴底：_spacer 存在 + grow=1 + 尾部节点排其后 + 容器自身 grow（改前空白 240–523px）',
      tailBad.length === 0,
      tailBad.length ? tailBad.join('; ') : tailPages.length + ' 页全部命中'
    );

    // ---------- contact 页：PRD §7.4.2 稿图三块内容 ----------
    //
    // 为什么必须点名：这页改前只有一句标题 + 两个按钮，机读层面「贴底」那条
    // 断言是全绿的（_spacer 在、grow=1、按钮排其后），可渲染图上中部约 600px
    // 是纯空白 —— 贴底成立不代表页面画完了，「空着」的病因是缺内容而不是布局。
    // 同 trust 页那次：内容缺失在画布上的唯一征兆就是「下面空着」，
    // 而空着永远无法自证是有意留白还是稿子没画完，只有逐块点名拦得住。
    //
    // 反向断言在此处不另造节点：本条查的是「§7.4.2 明列的块在不在」，
    // 缺任一块即报，本身已是逐项判定，构造一份缺块的假页去验它会报错
    // 只是把同一份 find 逻辑写两遍。
    {
      const frame = M.buildContact();
      const nav = frame.findOne((n) => n.type === 'TEXT'
        && n.characters.indexOf('联系 ') === 0);
      check(
        'contact 导航标题带发布者名（PRD §7.4.2 稿图「← 联系 王师傅」），不再是写死的「联系对方」',
        !!nav && nav.characters === '联系 ' + M.CONTENT.job.publisher,
        nav ? nav.characters : '未找到「联系 …」标题'
      );

      const body = frame.children.find((c) => c.name === '_body');
      const names = body ? body.children.map((c) => c.name) : [];
      const wantBlocks = ['_privacy-note', 'card/contact-channel', '_safety-tip'];
      const missBlocks = wantBlocks.filter((w) => names.indexOf(w) < 0);
      check(
        'contact 页三块内容齐备（隐私保护说明 / 联系方式卡 / 温馨提示），改前中部 600px 纯空白',
        missBlocks.length === 0,
        missBlocks.length ? '缺 ' + pj(missBlocks) : pj(names)
      );

      // 脱敏号码必须取 fixtures 真源且中段为掩码：PRD §7.4.2「号码中间 4 位脱敏」，
      // §7.7 又要求完整号码不写入前端初始状态 —— 稿子上出现真号码即违反后者
      const masked = frame.findOne((n) => n.type === 'TEXT'
        && n.characters === M.CONTENT.job.phoneMasked);
      check(
        '联系方式卡展示脱敏号码（PRD §7.4.2 中间 4 位脱敏 / §7.7 完整号码不入前端初始状态）',
        !!masked && /\*{4}/.test(M.CONTENT.job.phoneMasked),
        masked ? masked.characters : '未找到脱敏号码文本 ' + M.CONTENT.job.phoneMasked
      );

      // 单轨反向断言：§7.4.2 注「只显示该一种联系方式卡片，不做双卡片并列」。
      // 改前「拨打电话 + 复制微信号」两键并列，与同页红线卡自己写的
      // 「不并列引导」直接矛盾。此条锁的是「本页不得同时出现两条联系通道操作」
      const channelBtns = frame.findAll((n) => n.name.indexOf('btn/') === 0
        && (n.name.indexOf('号码') >= 0 || n.name.indexOf('电话') >= 0
          || n.name.indexOf('微信') >= 0));
      check(
        'contact 单轨：联系通道操作有且仅有 1 个（PRD §7.4.2 注「不做双卡片并列」）',
        channelBtns.length === 1,
        pj(channelBtns.map((b) => b.name))
      );
    }

    // ---------- detail-offline 与正常态 detail 同形（§7.8 只许三项差异） ----------
    //
    // 为什么单独锁而不靠上面那条贴底断言：贴底只管「_spacer 在不在」，
    // 管不了「两态的内容是否同一套」。§7.8 允许的差异只有红条 / disabled /
    // Opacity 60% 三项，内容或排列一旦分叉，评审对照时先看到的是「东西怎么少了」，
    // 而不是这三项 —— 这页存在的唯一目的就此落空。
    //
    // 判据取「_body 全部子节点的类别序列」而非只取 _spacer 之后的尾部：
    // 本轮首版只比尾部，结果全绿，而渲染图上失效态中部空 400px ——
    // 它缺了描述区与信任卡两块，两块都在 _spacer 之前，尾部判据一个都看不见。
    // 凡「两态必须同形」的页面，比的必须是整个内容序列，不是其中一段。
    {
      const norm = M.buildDetail();
      const off = M.buildDetailOffline();
      /** 取 _body 全部子节点的类别序列，按钮只留 'btn' 以容许 primary/disabled 差异 */
      const bodyShape = (frame) => {
        const b = frame.children.find((c) => c.name === '_body');
        if (!b) return ['无 _body'];
        return b.children.map((c) =>
          c.name.indexOf('_annotation/') === 0 ? 'anno'
            : (c.name.indexOf('btn/') === 0 ? 'btn'
              : (c.type === 'TEXT' ? 'text' : c.name)));
      };
      const sn = bodyShape(norm);
      const so = bodyShape(off);
      check(
        'detail-offline 的 _body 内容序列与正常态 detail 完全一致'
        + '（PRD §7.8 只许红条/disabled/Opacity 三项差异；只比尾部时缺两块内容仍会全绿）',
        sn.length > 1 && sn.join('>') === so.join('>'),
        '正常态 ' + sn.join('>') + '；失效态 ' + so.join('>')
      );
      // 三块内容卡必须都在：序列一致这条在「两态同时缺」时也会绿，
      // 故再点名一次 §7.4.1 稿图明列的三块
      const offNames = (off.children.find((c) => c.name === '_body') || { children: [] })
        .children.map((c) => c.name);
      const wantCards = ['_template-fields', '_description', '_trust-card'];
      const missCards = wantCards.filter((w) => offNames.indexOf(w) < 0);
      check(
        'detail-offline 含 §7.4.1 三块内容卡（模板字段/描述/信任卡），改前只有第一块',
        missCards.length === 0,
        missCards.length ? '缺 ' + pj(missCards) : pj(offNames)
      );
      // §7.8 的三项差异必须真的都在，缺任一项则本页与正常态无从区分
      const offBody = off.children.find((c) => c.name === '_body');
      const banner = off.children.find((c) => c.name === '_offline-banner');
      const disabledBtn = off.findOne((n) => n.name.indexOf('btn/disabled/') === 0);
      check(
        'detail-offline 三项差异齐备：红条 + disabled 按钮 + _body Opacity 60%（PRD §7.8）',
        !!banner && !!disabledBtn && !!offBody
        && Math.abs(offBody.opacity - 0.6) < 0.001,
        '红条 ' + !!banner + ' / disabled ' + (disabledBtn ? disabledBtn.name : '缺')
        + ' / opacity ' + (offBody ? offBody.opacity : 'n/a')
      );
    }

    // ---------- annotation 不得作为 pushToBottom 的唯一尾部元素 ----------
    //
    // 这是本轮踩到的探针盲区，必须补：离线断言全绿而实机失败。
    //
    // 机制：detachAnnotations() 会把 annotation 卡从画框里**移出去**、改挂到
    // 所在 SECTION 上（实机查得两张卡 parent 均为「02 · 核心流程<SECTION>」）。
    // 若 pushToBottom 的尾部只有 annotation，卡一移出，spacer 后面什么都不剩，
    // 页面回到「内容 293px + 空白 551px」—— 正是要修的那个病。
    //
    // 离线为何看不出：探针在 layout() 之前取节点树，那时 annotation 还在容器内，
    // 所以位置判据全部成立。这是「探针取值时机与实机不一致」的又一形态，
    // 与 CARD_SIG 那次的「取值路径不对却报成内容问题」并列记在案。
    //
    // 判据：扫全部构造器的 _spacer，凡其后节点全为 _annotation/* 的即判失败。
    {
      const annoOnlyTail = [];
      const scanned = [];
      for (const fn of Object.keys(M)) {
        if (fn.indexOf('build') !== 0 || typeof M[fn] !== 'function') continue;
        let frame;
        try { frame = M[fn](); } catch (e) { continue; }
        if (!frame || !frame.findAll) continue;
        scanned.push(fn);
        // 画框自身与所有子孙容器都要查：spacer 可能插在 _body 层也可能在画框层
        const holders = [frame].concat(
          frame.findAll((n) => n.children && n.children.length > 0)
        );
        for (const h of holders) {
          const kids = h.children;
          const spIdx = kids.findIndex((c) => c.name === '_spacer');
          if (spIdx < 0 || spIdx === kids.length - 1) continue;
          const after = kids.slice(spIdx + 1);
          const allAnno = after.every((c) => c.name.indexOf('_annotation/') === 0);
          if (allAnno) {
            annoOnlyTail.push(fn + '/' + h.name + ' 尾部仅 ' + pj(after.map((c) => c.name)));
          }
        }
      }
      check(
        'annotation 不得作为 pushToBottom 的唯一尾部元素（detachAnnotations 会把它移出画框，'
        + '离线全绿而实机仍是原空白）；已扫 ' + scanned.length + ' 个构造器',
        annoOnlyTail.length === 0,
        annoOnlyTail.length ? annoOnlyTail.join('; ') : '无一处依赖 annotation 贴底'
      );
    }

    // ---------- trust 页：PRD §4.4 的四类认证行 + 信任指标卡 ----------
    //
    // 为什么单独锁：这页的空白根子是「内容缺」而非布局。§4.3 表列四类认证、
    // §4.4 稿图逐条画了状态 + 日期 + 动作，我原先只画两张概括卡，把「哪一类过了、
    // 哪一类还没过」这个本页唯一核心信息糊掉了。缺内容在画布上的征兆就是「下面
    // 空着」，而空着从来无法自证是留白还是没画完 —— 只有点名断言拦得住。
    {
      const frame = M.buildTrust();
      const body = frame.children.find((c) => c.name === '_body');
      const names = body ? body.children.map((c) => c.name) : [];

      // 三类资质逐条列出，且三档状态各占一行（全画「已通过」等于只交付三分之一规格）
      const l2 = body && body.children.find((c) => c.name === '_layer2');
      const certs = l2 ? l2.children.filter((c) => c.name.indexOf('cert/') === 0) : [];
      check(
        'trust 页第二层逐条列出三类资质（企业/家政/车辆），不再是一张概括卡',
        certs.length === 3
        && certs.some((c) => c.name === 'cert/企业认证')
        && certs.some((c) => c.name === 'cert/家政资质')
        && certs.some((c) => c.name === 'cert/车辆认证'),
        pj(certs.map((c) => c.name))
      );

      // 三档状态色点各自走对 role：色点是状态的加速通道，走错色比没有更糟。
      // 取值口径两处易错，都踩过：① 色点要往 svgIcon 内部的 VECTOR 钻（iconFills）；
      // ② paintOf() 返回的是**单个 Paint 对象**而非数组，故比对时须包一层
      //（首版直接判 want.length 恒为 undefined，三行全报「无色点」——
      // 又是取值路径错却报成内容问题）
      const stateRole = { 'cert/企业认证': 'color/warning', 'cert/家政资质': 'color/error', 'cert/车辆认证': 'color/success' };
      const roleBad = [];
      for (const c of certs) {
        const dot = c.findOne ? c.findOne((n) => n.name === '_dot') : null;
        const got = iconFills(dot);
        if (!got || !got.length) { roleBad.push(c.name + ':取不到色点填充'); continue; }
        if (pj(got) !== pj([M.paintOf(stateRole[c.name])])) {
          roleBad.push(c.name + ' 色点非 ' + stateRole[c.name] + '(' + pj(got) + ')');
        }
      }
      check(
        'trust 页三类资质的状态色点分别走 warning/error/success（审核中/未认证/已通过）',
        roleBad.length === 0,
        roleBad.length ? roleBad.join('; ') : '三档色点全部命中'
      );

      // 状态必须有文字通道，不能只靠色点（同 completenessTag 的可访问性理由）
      const txtBad = [];
      for (const c of certs) {
        const st = c.findOne ? c.findOne((n) => n.name === '_cert-state') : null;
        const words = st ? st.children.filter((n) => n.type === 'TEXT').map((n) => n.characters) : [];
        if (!words.some((w) => ['已通过', '审核中', '未认证'].indexOf(w) >= 0)) {
          txtBad.push(c.name + ':' + pj(words));
        }
      }
      check(
        'trust 页认证状态带文字档名（已通过/审核中/未认证），颜色不是唯一载体',
        txtBad.length === 0,
        txtBad.length ? txtBad.join('; ') : '三行状态文字齐备'
      );

      // 信任指标卡在位，且三档分布齐全
      const tm = body && body.children.find((c) => c.name === '_trust-metrics');
      const dist = tm ? tm.findOne((n) => n.name === '_dist') : null;
      const cells = dist ? dist.children.map((c) => c.name) : [];
      check(
        'trust 页有 §4.4 信任指标卡，含完整度三档分布（_dist-green/yellow/red）',
        !!tm && cells.length === 3
        && cells.indexOf('_dist-green') >= 0
        && cells.indexOf('_dist-yellow') >= 0
        && cells.indexOf('_dist-red') >= 0,
        (tm ? '卡在位；' : '卡缺失；') + pj(cells)
      );

      // T4 红线：卡内不得出现发布记录数与举报率。
      // 这条不是形式检查 —— §4.2 明写「不做人的信誉评级」，一旦哪天有人往这张卡
      // 里加「发布 8 条 · 举报率 0%」，那就是产品定位漂了，而它长得跟别的指标一样无害
      const tmWords = tm ? tm.findAll((n) => n.type === 'TEXT').map((n) => n.characters).join('｜') : '';
      check(
        'trust 页信任指标卡不含发布记录数/举报率/信誉分（T4 永久红线，PRD §4.2）',
        !!tm && !/举报率|信誉分|发布记录/.test(tmWords),
        tmWords.slice(0, 90)
      );

      // 演示数据口径自洽：trust 页的条数必须与 profile 的「N 在架」一致。
      // 同一份演示数据在两页互相矛盾，评审第一眼会去追哪个对，而它其实没有对错
      const profRow = M.buildProfile().findOne((n) => n.name === 'row/我的发布');
      const profNum = profRow
        ? (profRow.findAll((n) => n.type === 'TEXT').map((n) => n.characters).join('').match(/(\d+)\s*在架/) || [])[1]
        : null;
      const trustNum = (tmWords.match(/在架的\s*(\d+)\s*条/) || [])[1];
      check(
        'trust 页条数与 profile「N 在架」口径一致（PRD §4.4 稿图的 5 条已回写为 3 条）',
        !!profNum && profNum === trustNum,
        'profile=' + profNum + '，trust=' + trustNum
      );

      // 认证行不复用 listRow：listRow 满宽 390 自带描边，塞进 358 卡内会双层边界
      check(
        'trust 页认证行不是 listRow（后者满宽 390 + 自带描边，卡内会出现双层边界）',
        names.indexOf('row/企业认证') < 0
        && certs.every((c) => Math.round(c.width) <= M.CANVAS.w - M.SPACING.lg * 2),
        pj(certs.map((c) => Math.round(c.width)))
      );
    }

    // ============================================================
    // 条目 [70] 后补：四页留白（notification 577 / my-favorite 541 /
    // my-publish 479 / settings 460）的内容补齐
    //
    // 为什么这一批要单独立断言而不是只看图：这四页的病根不是「排版没贴底」，
    // 而是「PRD 明列的条目没画全」—— 前者看图就看出来了，后者要拿 PRD 逐条对
    // 才发现。而一旦补齐后有人为了「精简」再删回去，页面照样能渲染、照样全绿，
    // 只是又变回半页空白。故把 PRD 里逐项列举的那几处硬编成判据。
    // ============================================================
    {
      // —— notification（PRD §8.3.3）——
      const notif = M.buildNotification();
      const rows = notif.findAll((n) => n.name.indexOf('notify/') === 0);
      // §8.3.3 逐项列了系统类五种触发，缺任何一种都等于该状态在稿子上没落点。
      // 「违规下架」是唯一的负向通知，最容易在"精简"时被删掉，故单独点名
      const rowWords = rows.map((r) => r.name.slice('notify/'.length)).join('｜');
      check(
        'notification 覆盖 §8.3.3 系统类五种触发（含「违规下架」这条唯一的负向通知）',
        rows.length === 5 && /违规下架/.test(rowWords),
        rows.length + ' 条：' + rowWords
      );

      // 单条五段齐备：图标 / 标题 / 摘要 / 时间 / 未读红点。原实现用 listRow
      // 顶替，只给得出标题 + 右值两段，摘要与未读态整个缺失
      const r0 = rows[0];
      const r0kids = r0 ? r0.children.map((c) => c.name) : [];
      const r0main = r0 ? r0.findOne((n) => n.name === '_notify-main') : null;
      check(
        'notification 单条为五段式（图标+标题+摘要+时间+未读点），非 listRow 的两段',
        r0kids.indexOf('_icon') >= 0 && r0kids.indexOf('_notify-right') >= 0
        && !!r0main && r0main.children.length === 2
        && !!r0.findOne((n) => n.name === '_unread'),
        pj(r0kids) + '，主区 ' + (r0main ? r0main.children.length : 0) + ' 段'
      );

      // 未读态不得只靠红点：已读标题走 text-secondary、未读走 text-primary，
      // 色阶差与红点互为冗余通道（同 completenessTag 的理由）
      const unreadCnt = rows.filter((r) => !!r.findOne((n) => n.name === '_unread')).length;
      const titleRole = (r) => {
        const m = r.findOne((n) => n.name === '_notify-main');
        const t = m ? m.children[0] : null;
        return t ? pj(t.fills) : null;
      };
      const readRow = rows.filter((r) => !r.findOne((n) => n.name === '_unread'))[0];
      check(
        'notification 未读/已读同屏且标题色阶有别（红点不是唯一通道）',
        unreadCnt > 0 && unreadCnt < rows.length
        && titleRole(rows[0]) === pj([M.paintOf('color/text-primary')])
        && titleRole(readRow) === pj([M.paintOf('color/text-secondary')]),
        '未读 ' + unreadCnt + ' / 共 ' + rows.length + ' 条，两态标题色不同='
        + (titleRole(rows[0]) !== titleRole(readRow))
      );

      // 行尾不得有 ›：§8.3.3 写「点击通知跳对应详情」，› 意味着展开下一级
      const chevron = rows.filter((r) => r.findAll((n) => n.type === 'TEXT')
        .some((t) => t.characters.indexOf('›') >= 0));
      check(
        'notification 行尾不带 ›（§8.3.3 是跳详情而非展开，› 会误导为可展开）',
        chevron.length === 0,
        chevron.length ? '仍带 ›：' + pj(chevron.map((r) => r.name)) : '五条均无 ›'
      );
    }

    {
      // —— my-favorite（PRD §8.3.2）——
      const fav = M.buildMyFavorite();
      const cards = fav.findAll((n) => n.name.indexOf('card/') === 0);
      // 五大分类各一张：收藏页是全稿唯一「五种分类色同屏」的真实语境，
      // 两张卡只验得到两种色，其余三种只在 T6 规格板上以脱离语境的纯色块出现过
      const catRoles = cards.map((c) => {
        const ic = c.findOne((n) => n.name.indexOf('_cat') === 0 || n.name === '_icon');
        const f = iconFills(ic) || (ic ? ic.fills : null);
        const bv = f && f[0] && f[0].boundVariables && f[0].boundVariables.color;
        return bv ? bv.name : null;
      });
      const uniqCats = catRoles.filter((v, i) => v && catRoles.indexOf(v) === i);
      check(
        'my-favorite 五张卡覆盖五大分类色（全稿唯一的五色同屏语境，PRD §8.3.2）',
        cards.length === 5 && uniqCats.length === 5,
        cards.length + ' 张卡，分类色 ' + uniqCats.length + ' 种：' + pj(uniqCats)
      );

      // 页签补「全部」：§8.3.2 明列三个页签，原实现只有两个
      const favTabs = fav.findAll((n) => n.type === 'TEXT')
        .map((n) => n.characters);
      check(
        'my-favorite 页签为「资源/需求/全部」三项（§8.3.2 明列，原缺「全部」）',
        favTabs.indexOf('资源') >= 0 && favTabs.indexOf('需求') >= 0 && favTabs.indexOf('全部') >= 0,
        '命中 ' + ['资源', '需求', '全部'].filter((t) => favTabs.indexOf(t) >= 0).join('/')
      );
    }

    {
      // —— my-publish（PRD §8.3.1 / §8.6 状态机）——
      const pub = M.buildMyPublish();
      // 条目 [71] 起，操作组下沉到卡片内部，透明的 _pub/ 中间层已取消，
      // 故按卡片节点自身计数（card() 出来的节点名以 card/ 起头）
      const blocks = pub.findAll((n) => n.name.indexOf('card/') === 0);
      // 三种发布状态同屏：§8.6 那张状态机图若在稿子上只落地「在架」一种，
      // 等于没落地。补「全部」页签正是为了让三态可以同屏
      const badges = pub.findAll((n) => n.type === 'TEXT').map((n) => n.characters);
      check(
        'my-publish 四张卡覆盖在架/已下架/草稿三种状态标（§8.6 状态机的稿面落点）',
        blocks.length === 4
        && badges.indexOf('在架') >= 0 && badges.indexOf('已下架') >= 0 && badges.indexOf('草稿') >= 0,
        blocks.length + ' 块；状态标命中 '
        + ['在架', '已下架', '草稿'].filter((t) => badges.indexOf(t) >= 0).join('/')
      );

      // 操作组必须在卡片**内部**（2026-08-30 条目 [71] 改严）：
      // §8.3.1 写的是「右：操作组」—— 操作与条目同属一个视觉单元。
      // 旧判据只要求它挂在透明的 _pub/ 容器里，而那样操作组落在两卡之间的
      // 页面底色上、左对齐悬空，渲染图上四组按钮看起来都像属于**下面**那张卡。
      // 判据因此收紧为「父节点必须是 card/ 本身」。
      const acts = pub.findAll((n) => n.name === '_pub-actions');
      const actsAllInCard = acts.every((a) => a.parent && a.parent.name.indexOf('card/') === 0);
      check(
        'my-publish 操作组落在卡片内部（游离在卡外会被读成属于下一张卡，§8.3.1）',
        acts.length === blocks.length && actsAllInCard,
        acts.length + ' 组 / ' + blocks.length + ' 张卡，全部在卡内=' + actsAllInCard
      );

      // 「在卡内」还不够，卡还得**装得下**（2026-08-30 实机复验补，条目 [71]）：
      // 上一条只查父子关系，四组操作全部命中、_pub-sep 也在，可实机渲染图上
      // 分隔线与按钮统统看不见 —— 卡高被锁死在 45px，三行内容（top 44 + sep 1
      // + acts 47）被裁掉了两行。根因是 card() 建时 layoutMode 为 HORIZONTAL，
      // box() 按主轴映射把横轴设为 FIXED、竖轴设为 AUTO；pubItem 把 layoutMode
      // 翻成 VERTICAL 后两轴语义互换，竖轴接过 FIXED 并保留了原横排 hug 出来的高。
      //
      // 教训：「节点存在」验不出「节点被裁」。凡改过 layoutMode 的容器，都要断言
      // 它的尺寸容得下子节点之和。
      const cardGeom = blocks.map((c) => {
        const sum = c.children.reduce((a, k) => a + k.height, 0)
          + (c.children.length - 1) * c.itemSpacing + c.paddingTop + c.paddingBottom;
        return { n: c.name, h: Math.round(c.height), need: Math.round(sum), w: Math.round(c.width) };
      });
      const cardFits = cardGeom.every((g) => g.h >= g.need && g.w === 358);
      check(
        'my-publish 卡片高度容得下卡内三行（改 layoutMode 后两轴 sizing 会互换，高被锁死则操作组被裁不可见）',
        cardFits,
        cardGeom.map((g) => g.h + '≥' + g.need + '/w' + g.w).join(' ')
      );

      // [反向] 退回改前写法（只翻 layoutMode、不纠正两轴 sizing），上条必须报失败，
      // 以证明它测的是真实几何而不是恒真式
      const badCard = M.card('反向卡', '副标题', 'category/cat-work', '在架');
      badCard.layoutMode = 'VERTICAL';
      const badNeed = badCard.children.reduce((a, k) => a + k.height, 0)
        + badCard.paddingTop + badCard.paddingBottom;
      check(
        '[反向] 只翻 layoutMode 不纠正 sizing 时，卡高确实装不下内容（证明上条测的是真几何）',
        badCard.height < badNeed,
        'h=' + Math.round(badCard.height) + ' < need=' + Math.round(badNeed)
      );

      // 操作组随状态变：在架给「下架」、已下架给「刷新重发」、草稿给「继续编辑」。
      // 四条卡若操作文案全一样，状态与可用操作的对应关系（本页核心规格）就丢了
      const actWords = acts.map((a) => a.findAll((n) => n.type === 'TEXT')
        .map((t) => t.characters).join('+'));
      const uniqActs = actWords.filter((v, i) => actWords.indexOf(v) === i);
      check(
        'my-publish 操作组随状态变化（下架/刷新重发/继续编辑，非四条同一套）',
        uniqActs.length >= 3
        && actWords.some((w) => /刷新重发/.test(w))
        && actWords.some((w) => /继续编辑/.test(w)),
        pj(uniqActs)
      );
    }

    {
      // —— settings（PRD §3.4.3）——
      const set = M.buildSettings();
      const titles = set.findAll((n) => n.name.indexOf('_group-title/') === 0)
        .map((n) => n.name.slice('_group-title/'.length));
      check(
        'settings 分四组（§3.4.3 本身分四组写；十余项平列是一堵没有落点的列表墙）',
        pj(titles) === pj(['账号与安全', '通用', '隐私', '关于']),
        pj(titles)
      );

      // §3.4.3 逐项列举的敏感项必须在：注销账号 / 默认范围 / 联系方式展示策略
      // 这三项恰是原 5 条平列里缺掉的，且都需要单独确认口径
      const setRows = set.findAll((n) => n.name.indexOf('row/') === 0)
        .map((n) => n.name.slice('row/'.length));
      const wantRows = ['注销账号', '默认范围', '联系方式展示策略', '位置权限说明', '清除缓存'];
      const missRows = wantRows.filter((r) => setRows.indexOf(r) < 0);
      check(
        'settings 含 §3.4.3 逐项列举的敏感项（注销账号/默认范围/联系方式展示策略等）',
        missRows.length === 0 && setRows.length >= 11,
        missRows.length ? '缺：' + pj(missRows) : setRows.length + ' 条齐备'
      );

      // 退出登录：§3.4.3 尾注写「个人中心放，设置页不放重复」。
      // 两侧都要验 —— 只验设置页没有，就会漏掉「两边都没有」这种更糟的情况
      //（本轮真实发生过：按尾注从设置页删掉后，整份稿子丢了这个元素）
      const setHasQuit = set.findAll((n) => n.type === 'TEXT')
        .some((n) => n.characters.indexOf('退出登录') >= 0);
      const profHasQuit = !!M.buildProfile().findOne((n) => n.name === 'btn/danger/退出登录');
      check(
        '退出登录只在个人中心、不在设置页（§3.4.3 尾注；两侧都验，防「两边都没有」）',
        !setHasQuit && profHasQuit,
        '设置页有=' + setHasQuit + '，个人中心有=' + profHasQuit
      );
    }

    // ---------- 分页列表页必须画「没有更多了」收尾态（PRD §6.7 :1291）----------
    //
    // 为什么点名三页而不是「凡列表页」：判据得能机械枚举。§7 接口表里标了「分页」
    // 的「我的」系列恰是这三条 GET（/notifications、/favorites、/posts/mine），
    // list 页则由 §6.7 那条交互约定直管，四处口径同源。
    //
    // 为什么必须是画框内的真元素而不是 annotation：annotation 会被
    // detachAnnotations() 移出画框（见 code.js:2314），写在那里等于稿面上没有 ——
    // 与「annotation 不得作为唯一尾部元素」是同一个坑的两种形态。
    //
    // 两段都验：鸭子在（§6.7 写的是「鸭子空状态」，只有文字等于丢了 IP 载体）、
    // 文案在（色弱/小图不可辨时文字是唯一通道，同 completenessTag 的理由）。
    {
      const endPages = [
        ['buildNotification', '通知中心 /notifications'],
        ['buildMyFavorite', '我的收藏 /favorites'],
        ['buildMyPublish', '我的发布 /posts/mine']
      ];
      const endBad = [];
      for (const [fn, label] of endPages) {
        const frame = M[fn]();
        const end = frame.findOne((n) => n.name === '_list-end');
        if (!end) { endBad.push(label + ':无 _list-end'); continue; }
        // 鸭子取 40px → mini 档，节点名带档位后缀
        if (!end.findOne((n) => n.name.indexOf('_duck-symbol') === 0)) {
          endBad.push(label + ':收尾条无鸭子符号');
        }
        const words = end.findAll((n) => n.type === 'TEXT').map((n) => n.characters);
        if (!words.some((w) => w.indexOf('没有更多了') >= 0)) {
          endBad.push(label + ':收尾条无「没有更多了」文案(' + pj(words) + ')');
        }
        // 收尾条必须排在列表条目之后，排在前面等于「一进页面就说到底了」
        const holder = end.parent;
        if (holder.children.indexOf(end) !== holder.children.length - 1) {
          endBad.push(label + ':收尾条不在 ' + holder.name + ' 末位');
        }
      }
      check(
        '三个分页列表页画出「没有更多了」收尾态（鸭子 + 文案 + 排末位；§6.7 :1291）',
        endBad.length === 0,
        endBad.length ? endBad.join('; ') : endPages.length + ' 页全部命中'
      );

      // 收尾条不得满宽塞进带 lg 内边距的容器：390 宽的条挂进 padding 16 的 _body
      // 会把容器顶到 422，画框随之变形。这是 listEndRow(width) 那个参数存在的
      // 唯一理由，故须有断言守住调用方真的传了
      const endWide = [];
      for (const [fn, label] of endPages) {
        const end = M[fn]().findOne((n) => n.name === '_list-end');
        if (!end) continue;
        const h = end.parent;
        const avail = h.width - h.paddingLeft - h.paddingRight;
        if (end.width > avail + 0.5) {
          endWide.push(label + ':收尾条 ' + Math.round(end.width) + ' > 可用 ' + Math.round(avail));
        }
      }
      check(
        '收尾条宽度不超出宿主容器可用宽（满宽条挂进带 padding 的 _body 会顶变形）',
        endWide.length === 0,
        endWide.length ? endWide.join('; ') : '三页宽度全部合规'
      );
    }

    // flexSpacer 高给 1 而非 0：宽/高为 0 的节点会被体检脚本报成异常节点，
    // 给 1px 且无填充，视觉不可见但体检认得出它是有意的占位
    {
      const sp = M.flexSpacer();
      check(
        'flexSpacer 尺寸 1×1 且无填充（0 尺寸会被体检报成异常节点，1px 则可辨识为有意占位）',
        Math.round(sp.width) === 1 && Math.round(sp.height) === 1 && sp.fills.length === 0,
        Math.round(sp.width) + '×' + Math.round(sp.height) + '，fills=' + sp.fills.length
      );
    }

    // 反向：把 pushToBottom 的 layoutGrow 赋值去掉，验上面那条判据真会红。
    // 这是最可能退化的一处 —— 「appendChild 之后再赋 grow」的顺序一旦被后来者
    // 挪动，spacer 就成了死的 1px，而画面回到改前那个样子却无人报错。
    //
    // 用正则而非字面串替换：源文件是 CRLF，字面串里写 '\n' 会匹配不到
    //（首版就栽在这里，报「替换未生效」）。正则里 \s* 同时吃掉 \r\n 与缩进。
    const rawNoGrow = raw.replace(/\n\s*sp\.layoutGrow = 1;/, '');
    check(
      '[反向] 去掉 pushToBottom 的 layoutGrow 赋值成功（证明下一条测的是退化写法）',
      rawNoGrow !== raw,
      rawNoGrow !== raw ? '已去掉' : '替换未生效，源码片段可能已改动'
    );
    if (rawNoGrow !== raw) {
      const ngM = new Function(
        'figma', '__html__',
        rawNoGrow + '\n;return { buildDetail: buildDetail };'
      )(figma, '');
      const ngBody = ngM.buildDetail().children.find((c) => c.name === '_body');
      const ngSp = ngBody.children.find((c) => c.name === '_spacer');
      check(
        '[反向] 无 layoutGrow 时「贴底」判据确实触发（spacer 退化为死的 1px，画面回到改前）',
        !!ngSp && ngSp.layoutGrow !== 1,
        ngSp ? 'layoutGrow=' + ngSp.layoutGrow + ' —— 已检出' : '未检出 —— 判据无区分力，需重写'
      );
    }
  }

  // ============================================================

  console.log('通过 ' + passed.length + ' / 失败 ' + failed.length);
  if (failed.length) {
    console.log('\n失败项：');
    for (const f of failed) console.log('  - ' + f);
    process.exit(1);
  }
})().catch((e) => {
  console.error('探针自身异常：', e);
  process.exit(2);
});
