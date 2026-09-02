/**
 * 交付目录生成器：把当前版交付物汇总到仓库根的 delivery/。
 *
 * 为什么需要它，而不是手工拷一遍：
 *   `prototype-figma/assets/render/` 下累计 216 个文件，只有 `r76-*` 那 50 张
 *   是当前版，其余是 r62–r75 的过程留痕。手工拷出来的目录在下一轮改稿后必然
 *   与真源脱节，**而脱节了外观上看不出来** —— r75 那批图过期整整两轮画布改动
 *   才被发现，成因正是「产物一旦离开生成链就没人再校验它」。
 *   故此处让交付目录也变成产物：改稿后重跑本脚本即可，且它会报 updated。
 *
 * 与另两个生成器（export-spec-doc.js / export-dart-tokens.js）同口径：
 * 自报 created / updated / unchanged，不静默覆盖。
 *
 * 用法：node prototype-figma/build-delivery.js
 */
const fs = require('fs');
const path = require('path');

const BASE = __dirname;                       // prototype-figma/
const ROOT = path.dirname(BASE);              // 仓库根
const OUT = path.join(ROOT, 'delivery');

/** 当前交付轮次的渲染图前缀。改版重出图后只需改这一处。 */
const ROUND = 'r76';

/**
 * Figma 源文件坐标。交付说明里要给出可点链接 ——
 * 渲染图只是快照，真正的交付主体是可量取、可复制样式的源文件。
 */
const FIGMA_URL = 'https://www.figma.com/design/4IoeGlLWkYt76wzo4QkV95/sds-app';

/**
 * 单文件交付物清单：[源路径, 目标相对路径]。
 * 用显式清单而非「拷整个目录」—— 后者会把生成脚本、探针、历史散图一并带走。
 */
const FILES = [
  [path.join(ROOT, 'docs', '设计系统与组件规范.md'), path.join('02-设计规范', '设计系统与组件规范.md')],
  [path.join(ROOT, 'lib', 'design_tokens.dart'), path.join('03-开发资产', 'design_tokens.dart')]
];

/**
 * 渲染图的区段划分。序号前缀取自出图时的命名口径
 * （b=规格板 / m=地图与列表 / c=核心流程 / t=模态与 T6），
 * 分子目录是为了让收件人能按「我要找哪一类画面」直接定位，
 * 而不是在 50 个平铺文件里翻。
 */
const RENDER_GROUPS = [
  ['b', '00-规格板'],
  ['m', '01-地图与列表'],
  ['c', '02-核心流程'],
  ['t', '03-模态与组件']
];

/**
 * 递归删除目录。
 *
 * 交付目录每次全量重建而非增量覆盖：增量的话，上一轮有、这一轮已删除的画框
 * 会作为孤儿文件永久留在交付目录里，收件人无从分辨它是否还有效。
 * @param {string} dir 待删目录
 * @returns {void}
 */
function rmrf(dir) {
  if (!fs.existsSync(dir)) return;
  for (const name of fs.readdirSync(dir)) {
    const p = path.join(dir, name);
    if (fs.statSync(p).isDirectory()) rmrf(p);
    else fs.unlinkSync(p);
  }
  fs.rmdirSync(dir);
}

/**
 * 把源文件拷到目标路径，自动建父目录。
 * @param {string} src 源文件绝对路径
 * @param {string} dest 目标文件绝对路径
 * @returns {number} 拷入的字节数
 */
function copyInto(src, dest) {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const buf = fs.readFileSync(src);
  fs.writeFileSync(dest, buf);
  return buf.length;
}

/**
 * 收集本轮渲染图，按区段前缀归组。
 *
 * 归组校验在**拷贝之前**做（先分组、验完整、再落盘）：若边拷边验，
 * 校验失败时目录已被清空且只拷了一半 —— 交付目录处于半空状态而脚本已退出，
 * 下次跑又报 created，看不出上一次是失败中断的。
 * @param {string} srcDir 渲染图源目录
 * @returns {{groups: Array<{dir: string, files: string[]}>, total: number}}
 *          分组结果与总张数
 */
function planRenders(srcDir) {
  const all = fs.readdirSync(srcDir).filter((f) => f.indexOf(ROUND + '-') === 0);
  const groups = [];
  let total = 0;
  for (const [prefix, dirName] of RENDER_GROUPS) {
    // 命名形如 r76-m01-首页主态.png，故区段字母在第二段的首位
    const files = all
      .filter((f) => f.slice(ROUND.length + 1, ROUND.length + 2) === prefix)
      .sort();
    total += files.length;
    groups.push({ dir: dirName, files: files });
  }
  // 归组遗漏检查：新增区段字母若没在 RENDER_GROUPS 登记，会被静默丢掉，
  // 而交付目录里少了几张图是极难发现的（没人会去数）
  if (total !== all.length) {
    throw new Error(
      '有 ' + (all.length - total) + ' 张图未被归组（RENDER_GROUPS 缺登记）：'
      + all.filter((f) => !RENDER_GROUPS.some(
        ([p]) => f.slice(ROUND.length + 1, ROUND.length + 2) === p
      )).join(', ')
    );
  }
  return { groups, total };
}

/**
 * 渲染交付说明正文。
 *
 * 刻意写成收件人视角而非开发日志视角：读这份文件的人要的是
 * 「我拿到了什么、该从哪读起、有什么我必须处理」，不是改动史。
 * @param {{groups: Array, total: number}} r collectRenders 的结果
 * @returns {string} Markdown 正文
 */
function renderReadme(r) {
  const groupLines = r.groups
    .map((g) => '| `01-页面渲染图/' + g.dir + '/` | ' + g.files.length + ' 张 |')
    .join('\n');
  // 画框数与规格板数由分组结果现算，不写死：手写的数字在改稿后不会自己变，
  // 而「文档说 45 个、目录里 50 张」这种对不上，读的人只会怀疑整份文档
  const boardCount = (r.groups.find((g) => g.dir === '00-规格板') || { files: [] }).files.length;
  const frameCount = r.total - boardCount;

  return `# 找鸭找 · UI 设计交付物

本目录由 \`prototype-figma/build-delivery.js\` 自动生成，请勿手工修改 ——
设计稿更新后重跑该脚本即可全量重建。

---

## 一、先看这里：设计源文件

**${FIGMA_URL}**

渲染图只是快照。**真正的交付主体是这个 Figma 文件** —— 只有在它里面才能量取
间距、复制色值、查看 Auto Layout 结构与组件变体。

文件内含：

| 内容 | 数量 |
|---|---|
| 页面画框（\`01 · 原型主页面\`） | ${frameCount} 个，分 3 个 Section |
| 规格板（\`00 · Tokens 与组件\`） | ${boardCount} 块 |
| 组件 master | 20 个 |
| 组件变体集（Component Set） | 3 组 |
| 文字样式 / 颜色样式 | 6 档 / 26 档 |
| Token 变量 | 43 个 |

---

## 二、目录内容

| 路径 | 说明 |
|---|---|
${groupLines}
| \`02-设计规范/设计系统与组件规范.md\` | 12 章完整规范，**开发前必读** |
| \`03-开发资产/design_tokens.dart\` | Flutter Token 常量，可直接引入 |

渲染图为 **@2x PNG**，共 ${r.total} 张。

---

## 三、⚠️ 两条必须处理的事项

规范文档 §11 登记了 8 条已知缺口，其中 **6 条是已裁定不做或平台限制**，
但**以下 2 条是需要实现侧动手的**，请勿当作免责声明读过：

### 1. T3 筛选弹层的两个按钮高度不足，须补到 44

\`_sheet-reset\`（重置）实测高 **36**、\`_sheet-confirm\`（确定并收起）实测高 **34**，
均低于设计规范要求的 **44px 最小触控区**。它们在三级筛选树的三层弹层中各出现一次
（见 \`01-地图与列表/\` 的 T3 三张图）。

**照稿取值会做出一个不达可用性标准的控件 —— 请直接实现为 44 高。**

Figma 侧未修的原因：改它需要重构按钮组件库结构，会牵动全部组件引用，
故选择如实标注而非交付前夜大改。

### 2. 卡片选中态、输入框五态在业务页内没有实处

这两组状态的**规格与实样**都有（见 \`00-规格板/r76-b05-组件状态实样.png\`），
但业务页面里没有画出来 —— 因为原型内没有对应的交互载体
（列表卡点击即跳详情，无多选场景；输入框 focus 是瞬时态）。

**实现这两组状态时请以规格板与规范文档 §4 / §7 的登记表为准。**

---

## 四、规范文档怎么读

§0 有导读。若时间有限，按此顺序：

1. **§1 Design Token** —— 色彩、字阶、间距、圆角的全部取值
2. **§2 对比度实测表** —— 34 组实测，**含 8 组明确禁用的组合**，照做即满足 WCAG AA
3. **§3–§9 组件规格** —— 按钮 6 档 / 卡片 / 标签四族 / 圆点 4 档 / 输入框两套 / 空态 / 动效 6 档
4. **§10 组件库** —— 20 个 master 与 Figma 内命名的对应关系
5. **§11 已知缺口** —— 上文那 2 条行动项的完整上下文

---

## 五、这份稿的校验情况

设计稿本身经两套自动化断言校验，全部通过：

- 布局与结构：**310 条**
- Token 与变量：**125 条**

校验覆盖对比度合规、Token 取值一致性、组件引用完整性（247 个实例零断链）、
触控区下限、语义色不作为唯一信息通道等。**上文那 2 条缺口是已知且已声明的例外。**
`;
}

/**
 * 主流程：全量重建 delivery/ 并自报状态。
 * @returns {void}
 */
function main() {
  // 先算出「重建后的 README 应该是什么」，再与现有的比 ——
  // 用它作为「交付目录是否需要更新」的指纹：README 内含图张数与分组，
  // 图有增减必然反映到它上面。
  const prevReadme = fs.existsSync(path.join(OUT, 'README.md'))
    ? fs.readFileSync(path.join(OUT, 'README.md'), 'utf8')
    : null;

  // 全部校验先做完再动目录：清空之后才发现缺料，会留下一个半空的交付目录
  const srcDir = path.join(BASE, 'assets', 'render');
  const r = planRenders(srcDir);
  for (const [src] of FILES) {
    if (!fs.existsSync(src)) throw new Error('交付物缺失：' + src);
  }

  rmrf(OUT);

  let bytes = 0;
  for (const g of r.groups) {
    for (const f of g.files) {
      bytes += copyInto(path.join(srcDir, f), path.join(OUT, '01-页面渲染图', g.dir, f));
    }
  }
  let docBytes = 0;
  for (const [src, rel] of FILES) docBytes += copyInto(src, path.join(OUT, rel));

  const readme = renderReadme(r);
  fs.writeFileSync(path.join(OUT, 'README.md'), readme, 'utf8');

  console.log(
    (prevReadme === null ? 'created ' : prevReadme === readme ? 'unchanged ' : 'updated ')
    + 'delivery/'
  );
  console.log(
    'RENDER ' + r.total + ' 张 (' + Math.round(bytes / 1024 / 1024) + ' MB)'
    + ' + DOC ' + FILES.length + ' 件 (' + Math.round(docBytes / 1024) + ' KB)'
  );
  for (const g of r.groups) console.log('  ' + g.dir + ': ' + g.files.length);
}

main();
