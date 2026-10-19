/// 裁剪结果归一化：PNG → JPEG、限制长边、按白底合成透明通道。
///
/// **为什么需要这一步**：`crop_your_image` 的输出是 PNG；用户照片动辄 4000px，
/// 直接上传会撞 [NfrMedia.maxSizeBytes] 上限，且在 ECS 3M 带宽下传输过慢。
/// 归一化后长边不超过 [kCroppedMaxLongEdge]，体积通常只有原图的十分之一。
///
/// **为什么在 isolate 里跑**：大图解码 + 重采样 + JPEG 编码是 CPU 密集操作，
/// 放在 UI isolate 会让裁剪页在「完成」后卡住数百毫秒到数秒。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import '../../nfr_constants.dart';
import 'media_picker.dart';

/// 裁剪结果长边上限（像素）。
///
/// 详情卡约 1080×600（3x 屏），1600 足够全屏查看，又不会让单张图过大。
const int kCroppedMaxLongEdge = 1600;

/// 裁剪结果 JPEG 质量（体积与清晰度的折中）。
const int kCroppedJpegQuality = 85;

/// 编码输入（可跨 isolate 传递的纯数据）。
class CropEncodeInput {
  /// 构造编码输入。
  ///
  /// 参数：
  /// - [bytes] 裁剪器输出的图片字节；
  /// - [filename] 原文件名（仅用于生成新文件名）。
  const CropEncodeInput({required this.bytes, required this.filename});

  /// 裁剪器输出的图片字节。
  final Uint8List bytes;

  /// 原文件名。
  final String filename;
}

/// 把裁剪结果归一化为可上传的 JPEG（同步版本，供 isolate 入口调用）。
///
/// 参数：[input] 裁剪字节与原文件名。
/// 返回：新的 [PickedMedia]（`image/jpeg`，文件名后缀改为 `.jpg`）。
/// 抛出：[MediaPickException] 解码失败，或结果仍超过 [NfrMedia.maxSizeBytes]。
PickedMedia normalizeCroppedImage(CropEncodeInput input) {
  final decoded = img.decodeImage(input.bytes);
  if (decoded == null) {
    throw const MediaPickException('图片裁剪失败，请重试');
  }

  var image = decoded;
  final longEdge = math.max(image.width, image.height);
  if (longEdge > kCroppedMaxLongEdge) {
    final scale = kCroppedMaxLongEdge / longEdge;
    image = img.copyResize(
      image,
      width: math.max(1, (image.width * scale).round()),
      height: math.max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  // JPEG 不支持透明通道：PNG 的透明区域按白底合成，避免编码后出现黑块。
  if (image.hasAlpha) {
    final canvas = img.Image(width: image.width, height: image.height);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, image);
    image = canvas;
  }

  final encoded = img.encodeJpg(image, quality: kCroppedJpegQuality);
  if (encoded.length > NfrMedia.maxSizeBytes) {
    final limitMb = NfrMedia.maxSizeBytes ~/ (1024 * 1024);
    throw MediaPickException('裁剪结果超过 ${limitMb}MB，请换一张图片');
  }

  final baseName = input.filename.replaceAll(RegExp(r'\.[^.]+$'), '');
  return PickedMedia(
    filename: baseName.isEmpty ? 'cropped.jpg' : '$baseName.jpg',
    bytes: Uint8List.fromList(encoded),
    contentType: 'image/jpeg',
  );
}

/// 在后台 isolate 中执行 [normalizeCroppedImage]。
///
/// 参数：[input] 裁剪字节与原文件名。
/// 返回：归一化后的 [PickedMedia]。
/// 抛出：[MediaPickException] 同 [normalizeCroppedImage]。
Future<PickedMedia> normalizeCroppedImageAsync(CropEncodeInput input) {
  return compute(normalizeCroppedImage, input);
}
