/// 裁剪入口抽象：把「打开裁剪页」与「媒体段」解耦，便于 widget 测试注入假实现。
///
/// 与 `MediaPicker` 同一纪律：平台/导航相关能力收敛到可替换的入口，媒体段只
/// 关心「给我裁剪后的媒体或 null」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'image_crop_screen.dart';
import 'media_picker.dart';

/// 裁剪启动器签名。
///
/// 参数：`context` 用于导航；`source` 待裁剪图片；`aspectRatio` 裁剪框比例。
/// 返回：裁剪后的媒体；用户取消/返回时为 null。
typedef MediaCropLauncher = Future<PickedMedia?> Function(
  BuildContext context, {
  required PickedMedia source,
  required double aspectRatio,
});

/// 生产实现：打开 [ImageCropScreen]。
///
/// 参数同 [MediaCropLauncher]。
/// 返回：裁剪结果或 null。
Future<PickedMedia?> pushImageCropScreen(
  BuildContext context, {
  required PickedMedia source,
  required double aspectRatio,
}) {
  return Navigator.of(context).push<PickedMedia>(
    MaterialPageRoute<PickedMedia>(
      builder: (_) => ImageCropScreen(source: source, aspectRatio: aspectRatio),
    ),
  );
}

/// 裁剪启动器 Provider（测试用假实现覆盖）。
final mediaCropLauncherProvider = Provider<MediaCropLauncher>(
  (ref) => pushImageCropScreen,
);
