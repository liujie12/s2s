/**
 * 把 code.js 里的 Design Token 真源表导出为纯 Dart 常量文件。
 *
 * 为什么需要这个脚本（条目 [57] 第二节 I2 的落地形态）：
 * Token 的当前真源是 code.js 的六张 JS 表，Figma Variables 与 Flutter 实现都是
 * 它的下游。但 Figma 侧有一个已查明的盲区 —— `figma_diff_versions` 不追踪变量
 * 值变更，主色从 #0B7C8C 悄悄调深一档（白字对比度余量只有 0.41：实测 4.91:1
 * 对红线 4.5:1）不会触发任何机制报警。把真源表落成一份进 git 的产物后，任何
 * 取值改动都必须在 `git diff` 里现形，这是这份产物存在的**唯一理由**。
 *
 * 为什么这次留产物，与 probe-token-vars.py 的「跑完即删，不留产物」不矛盾：
 * 那句话防的是「双向副本」—— 两处都可被人编辑，就必然静默脱钩。本产物是
 * **单向出口**：只由本脚本生成、头部标了禁止手改、且 probe-token-vars.py 里
 * 有一条断言逐项比对它与真源表。脱钩当场变红，不存在需要人去同步的第二份。
 *
 * 为什么不输出 DTCG JSON 再由插件读回：插件 manifest 的
 * `networkAccess.allowedDomains: ["none"]` 且无文件系统访问，运行时读不到本地
 * JSON（条目 [57] 查明）。故只能是「code.js → 外部」的单向导出，不能反向。
 *
 * 为什么产物不 import Flutter：现在还没有 Flutter 工程，产物必须能被任何 Dart
 * 项目直接引用，故颜色用 int 存 0xFF 前缀值，由消费侧自行包 Color()。
 *
 * 为什么不导 MOTION：动效表是 annotation-only 的契约（条目 [48] 查明 TIMING/
 * EASING 进不了 Variables），其中 `ease: 'spring'` 在 Flutter 是
 * SpringSimulation、在 CSS 里无对应值。替设计师把语义词落成具体参数超出
 * 「冻结契约」的范围（条目 [51] 红线），故刻意留在画布 annotation 里。
 *
 * 用法：node prototype-figma/export-dart-tokens.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const BASE = __dirname;
const OUT = path.join(path.dirname(BASE), 'lib', 'design_tokens.dart');

/**
 * 加载 code.js 并取出六张 Token 真源表。
 *
 * 复用 probe-layout-offline.js 的加载模式：整体 eval + 最小 figma mock 消副作用。
 * code.js 的插件入口只有 `figma.showUI` 与 `figma.ui.onmessage` 两处会在顶层
 * 执行，mock 成空实现即可；其余 figma API 都在批次函数内部，不会被触及。
 *
 * 为什么不像 probe-token-vars.py 那样用正则解析：正则只能取到「写在源码里的
 * 字面量」，取不到求值结果。真跑一遍才能保证导出物与插件运行时看到的是同一份
 * 取值 —— 若哪天某张表改成由函数拼装，正则会静默取空，eval 不会。
 *
 * @returns {{SEMANTIC_COLORS:Object, CATEGORY_COLORS:Object, CATEGORY_DEEP:Object,
 *            TYPE_SCALE:Object, SPACING:Object, RADIUS:Object}} 六张真源表
 */
function loadTokenTables() {
  const figma = {
    showUI: () => {},
    ui: { onmessage: null, postMessage: () => {} }
  };
  const raw = fs.readFileSync(path.join(BASE, 'code.js'), 'utf8');
  const names = [
    'SEMANTIC_COLORS', 'CATEGORY_COLORS', 'CATEGORY_DEEP',
    'TYPE_SCALE', 'SPACING', 'RADIUS'
  ];
  const wrapped = new Function(
    'figma', '__html__',
    raw + '\n;return { ' +
      names.map((k) => k + ': typeof ' + k + " !== 'undefined' ? " + k + ' : undefined').join(', ') +
      ' };'
  );
  const tables = wrapped(figma, '');
  for (const k of names) {
    if (!tables[k]) throw new Error('真源表缺失：' + k + '（code.js 结构已变，导出脚本需同步）');
  }
  return tables;
}

/**
 * 把 Token 键名转成 Dart 的 lowerCamelCase 标识符。
 *
 * 真源键名带连字符（primary-dark / cat-work / success-text），Dart 标识符不允许。
 * 转换规则只在此一处实现；产物里每个常量都带一行 `/// <Figma 变量名>` 文档注释，
 * 一致性断言按那个变量名取值比对，因此断言侧**不需要**复制这套转换规则
 * （复制就是新的手抄副本，原则㊾）。
 *
 * @param {string} key 真源表键名，如 'primary-dark'
 * @returns {string} Dart 标识符，如 'primaryDark'
 */
function toCamel(key) {
  return key.replace(/-([a-z0-9])/g, (_, c) => c.toUpperCase());
}

/**
 * 把 #RRGGBB 转成 Dart 的 0xAARRGGBB 整型字面量（不透明）。
 *
 * @param {string} hex 形如 '#0B7C8C' 的色值
 * @returns {string} 形如 '0xFF0B7C8C' 的字面量
 */
function toArgb(hex) {
  const m = /^#([0-9A-Fa-f]{6})$/.exec(hex);
  if (!m) throw new Error('非法色值：' + hex);
  return '0xFF' + m[1].toUpperCase();
}

/**
 * 生成一组颜色常量的 Dart 代码行。
 *
 * @param {Object<string,string>} table 真源色表
 * @param {string} varPrefix 对应的 Figma 变量名前缀，如 'color/'
 * @param {string} varSuffix 对应的 Figma 变量名后缀，如 '-deep'（无则传空串）
 * @returns {string} 拼好的 Dart 代码片段
 */
function colorBlock(table, varPrefix, varSuffix) {
  return Object.keys(table).map((key) => {
    const varName = varPrefix + key + varSuffix;
    const ident = toCamel(key + varSuffix);
    return '  /// ' + varName + '  ·  ' + table[key] + '\n'
      + '  static const int ' + ident + ' = ' + toArgb(table[key]) + ';\n';
  }).join('\n');
}

/**
 * 生成一组数值常量的 Dart 代码行。
 *
 * @param {Object<string,number>} table 真源数值表
 * @param {string} varPrefix 对应的 Figma 变量名前缀，如 'spacing/'
 * @returns {string} 拼好的 Dart 代码片段
 */
function numberBlock(table, varPrefix) {
  return Object.keys(table).map((key) => {
    return '  /// ' + varPrefix + key + '\n'
      + '  static const double ' + toCamel(key) + ' = ' + table[key] + ';\n';
  }).join('\n');
}

/**
 * 生成字阶常量的 Dart 代码行。
 *
 * 三个字段（size / weight / lineHeight）写在同一个 const 构造里，避免拆成三张
 * 平行表后可以单侧改动。weight 保留 PRD 原词字符串，不映射成 FontWeight 数值
 * —— 那是实现侧的选参，替它决定超出「冻结契约」的范围。
 *
 * **构造参数刻意逐行展开**（而非挤在一行）：产物会被 `dart format` 处理，
 * 而单行写法超过 80 列必被它拆成多行 —— 于是每次跑完 format，产物就与本脚本
 * 的输出不一致，`git status` 永远显示这个文件被改过，掩盖真正的 Token 变更。
 * 直接按 format 后的形态生成，两者才能稳定一致。
 *
 * @param {Object<string,{size:number,weight:string,lineHeight:number}>} table 真源字阶表
 * @returns {string} 拼好的 Dart 代码片段
 */
function typeScaleBlock(table) {
  return Object.keys(table).map((key) => {
    const s = table[key];
    return '  /// size/' + key + '  ·  ' + s.size + 'px / ' + s.weight + ' / ×' + s.lineHeight + '\n'
      + '  static const AppTextStyleToken ' + toCamel(key) + ' = AppTextStyleToken(\n'
      + '    size: ' + s.size + ',\n'
      + "    weight: '" + s.weight + "',\n"
      + '    lineHeight: ' + s.lineHeight + ',\n'
      + '  );\n';
  }).join('\n');
}

/**
 * 组装完整的 Dart 产物文本。
 *
 * @param {Object} t loadTokenTables() 的返回值
 * @returns {string} 产物文件全文
 */
function render(t) {
  const colorCount = Object.keys(t.SEMANTIC_COLORS).length
    + Object.keys(t.CATEGORY_COLORS).length
    + Object.keys(t.CATEGORY_DEEP).length;
  const floatCount = Object.keys(t.TYPE_SCALE).length
    + Object.keys(t.SPACING).length
    + Object.keys(t.RADIUS).length;

  return `// 由 prototype-figma/export-dart-tokens.js 自动生成，请勿手改。
//
// 真源是 prototype-figma/code.js 顶部的六张 Token 表（同时也是 Figma Variables
// 集合 "ZhaoYaZhao Tokens" 的来源），改 Token 请改那里再重跑：
//
//     node prototype-figma/export-dart-tokens.js
//
// 每个常量上方的 /// 注释是它对应的 Figma 变量名，便于设计与实现对同一个名字
// 说话。prototype-figma/probe-token-vars.py 有断言逐项比对本文件与真源表，
// 手改或忘记重跑都会当场变红。
//
// 本文件刻意不 import 'package:flutter/material.dart'：颜色以 int 存
// 0xAARRGGBB，任何 Dart 项目都能直接引用，消费侧自行包 Color()。
//
// 计数：COLOR ${colorCount} + FLOAT ${floatCount} = ${colorCount + floatCount}

/// 语义色板（PRD §1.4.2）。对应 Figma 变量 color/*。
///
/// 用法：\`Color(AppColors.primary)\`
class AppColors {
  const AppColors._();

${colorBlock(t.SEMANTIC_COLORS, 'color/', '')}}

/// 五大分类色（PRD §1.4.3）。对应 Figma 变量 category/*。
///
/// 不带后缀的是原色，只用于 Pin 填充、图例圆点、卡片圆标等**图形**用途；
/// \`*Deep\` 是深色变体，只用于**承载白色文字的底**（原色白字仅 2.54–4.23:1，
/// 五类全部不过 WCAG AA 4.5:1）。两者不可互换，详见 code.js 里 CATEGORY_DEEP
/// 的注释。
class AppCategoryColors {
  const AppCategoryColors._();

${colorBlock(t.CATEGORY_COLORS, 'category/', '')}
${colorBlock(t.CATEGORY_DEEP, 'category/', '-deep')}}

/// 一档字阶的三个属性。
///
/// weight 保留 PRD 原词（Bold / SemiBold / Regular / Medium），不预先映射成
/// FontWeight 数值 —— 具体选参由实现侧决定。
class AppTextStyleToken {
  const AppTextStyleToken({
    required this.size,
    required this.weight,
    required this.lineHeight,
  });

  /// 字号，单位逻辑像素
  final double size;

  /// 字重原词
  final String weight;

  /// 行高倍数
  final double lineHeight;

  /// 行高的像素值。
  ///
  /// 刻意只提供派生 getter 而不存字段：行高是「字号 × 倍数」的派生值，
  /// 单独存一份就是第二份副本，改了字号却忘改行高会静默不一致
  /// （同 code.js 里「行高不入 Variables」的理由）。
  double get lineHeightPx => size * lineHeight;
}

/// 字阶（PRD §1.4.4）。size 对应 Figma 变量 size/*；行高未入变量，为派生值。
class AppTypeScale {
  const AppTypeScale._();

${typeScaleBlock(t.TYPE_SCALE)}}

/// 间距阶（PRD §1.4.5）。对应 Figma 变量 spacing/*。
class AppSpacing {
  const AppSpacing._();

${numberBlock(t.SPACING, 'spacing/')}}

/// 圆角阶（PRD §1.4.5）。对应 Figma 变量 radius/*。
///
/// 类名不叫 Radius：Flutter 已有 \`dart:ui\` 的 Radius，同名会在消费侧撞车。
class AppRadius {
  const AppRadius._();

${numberBlock(t.RADIUS, 'radius/')}}
`;
}

const tables = loadTokenTables();
const text = render(tables);
fs.mkdirSync(path.dirname(OUT), { recursive: true });
const before = fs.existsSync(OUT) ? fs.readFileSync(OUT, 'utf8') : null;
fs.writeFileSync(OUT, text, 'utf8');
console.log(
  (before === null ? 'created ' : before === text ? 'unchanged ' : 'updated ')
  + path.relative(path.dirname(BASE), OUT)
);
console.log(
  'COLOR ' + (Object.keys(tables.SEMANTIC_COLORS).length
    + Object.keys(tables.CATEGORY_COLORS).length
    + Object.keys(tables.CATEGORY_DEEP).length)
  + ' + FLOAT ' + (Object.keys(tables.TYPE_SCALE).length
    + Object.keys(tables.SPACING).length
    + Object.keys(tables.RADIUS).length)
);
