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

/// 拍后比例偏差容忍阈值（相对偏差，绝对值）。
///
/// 详情比例约 1.79（390dp 画板）：相机 16:9≈1.78 视为一致（偏差 0.7%），
/// 4:3≈1.33（偏差 26%）与竖拍 3:4≈0.75（偏差 58%）会触发「三选一」提示。
/// ⚠️ PRD/详设未覆盖此口径，属待产品裁定的临时值（不复制字面量：唯一真源在此）。
const double kAspectMismatchTolerance = 0.15;

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

/// 判断图片宽高比与目标比例的偏差是否超过容忍阈值（拍后比例体检的判定）。
///
/// 纯函数便于单测，不依赖 [BuildContext]。详情比例约 1.79：相机 16:9≈1.78 视为
/// 一致，4:3≈1.33、竖拍 3:4≈0.75、方图 1:1 视为不匹配。
///
/// 参数：
/// - [width] 图片宽；
/// - [height] 图片高；
/// - [targetAspect] 目标宽高比；
/// - [tolerance] 相对偏差容忍阈值（取 [kAspectMismatchTolerance]）。
/// 返回：true 表示偏差超阈值（需提示用户）。
bool aspectMismatchExceeds({
  required int width,
  required int height,
  required double targetAspect,
  required double tolerance,
}) {
  if (height <= 0 || targetAspect <= 0) return false;
  final deviation = (width / height - targetAspect).abs() / targetAspect;
  return deviation > tolerance;
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
