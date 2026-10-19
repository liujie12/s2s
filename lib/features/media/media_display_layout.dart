/// 详情页媒体区的展示几何（轮播与发布页裁剪共用同一份比例）。
///
/// 单独成文件而不是塞进 `design_tokens.dart`：后者由
/// `prototype-figma/export-dart-tokens.js` 自动生成（文件头已注明「请勿手改」），
/// 且刻意不依赖 Flutter；本文件需要 `MediaQuery`，来源不同。
library;

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../design_tokens.dart';

/// 详情页媒体区块高（PRD §7.4.1）。
///
/// 与改造前的分类色占位块同值：改这个数会让详情页下方内容整体位移。
const double kDetailMediaBlockHeight = 200;

/// 详情页媒体卡的目标宽高比。
///
/// 媒体卡宽度 = 屏宽 - 左右内缩 [AppSpacing.lg]；发布页裁剪框按此比例初始化，
/// 裁剪后详情页可完整填充、不再留白。
///
/// 参数：[context] 用于读取当前屏幕宽度。
/// 返回：宽高比（媒体卡宽 ÷ 块高）。
double detailMediaAspectRatio(BuildContext context) {
  final cardWidth = MediaQuery.sizeOf(context).width - 2 * AppSpacing.lg;
  return cardWidth / kDetailMediaBlockHeight;
}

/// 裁剪框的初始矩形：在视口内按目标比例取最大，四周留出圆点安全边距。
///
/// **为什么不用库的默认初始框**：`crop_your_image` 默认按「图片适配视口后的
/// 宽度」计算，竖图时只用到屏宽约 70%；交互模式随后又把图片放大铺满视口，
/// 于是裁剪框明显窄于可见图片。这里直接按视口取最大，宽高比保持不变。
///
/// 参数：
/// - [viewportSize] 裁剪组件的可用区域；
/// - [aspectRatio] 目标宽高比（> 0）。
/// 返回：居中的裁剪矩形（宽或高至少有一边贴近 [AppSpacing.sm] 边距）。
Rect initialCropRect(Size viewportSize, double aspectRatio) {
  final maxWidth = math.max(0.0, viewportSize.width - 2 * AppSpacing.sm);
  final maxHeight = math.max(0.0, viewportSize.height - 2 * AppSpacing.sm);
  final width = math.min(maxWidth, maxHeight * aspectRatio);
  final height = aspectRatio == 0 ? 0.0 : width / aspectRatio;
  return Rect.fromCenter(
    center: Offset(viewportSize.width / 2, viewportSize.height / 2),
    width: width,
    height: height,
  );
}
