/// 图片上传前归一化：方向烘焙 + 长边限幅 + 透明通道白底合成 + 统一 JPEG。
///
/// **为什么需要这一步**：相机/相册原图可能带 EXIF 方向（竖拍=横像素+orientation=6），
/// 直接上传详情页会横躺；且用户照片动辄 4000px，会撞 [NfrMedia.maxSizeBytes] 上限、
/// 在 ECS 3M 带宽下传输过慢。归一化后长边不超过 [kCroppedMaxLongEdge]、统一为
/// `image/jpeg`，体积通常只有原图的十分之一。裁剪结果（[normalizeCroppedImage]）与
/// 相机/相册原图（[normalizeUploadImage]）共用同一编码核心 [_encodeForUpload]。
///
/// **为什么在 isolate 里跑**：大图解码 + 重采样 + JPEG 编码是 CPU 密集操作，
/// 放在 UI isolate 会让裁剪页/发布页卡住数百毫秒到数秒。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../nfr_constants.dart';
import 'media_picker.dart';

/// 裁剪结果长边上限（像素）。
///
/// 详情卡约 1080×600（3x 屏），1600 足够全屏查看，又不会让单张图过大。
/// 唯一真源在 [NfrMedia.uploadLongEdgePx]（选图侧平台预缩放也用同一值）。
const int kCroppedMaxLongEdge = NfrMedia.uploadLongEdgePx;

/// 裁剪结果 JPEG 质量（体积与清晰度的折中）。
///
/// 唯一真源在 [NfrMedia.uploadJpegQuality]。
const int kCroppedJpegQuality = NfrMedia.uploadJpegQuality;

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
  // 烘焙 EXIF 方向：裁剪器输出理论上方向已正，此处兜底防御（无 EXIF 时 no-op）。
  return _encodeForUpload(img.bakeOrientation(decoded), input.filename);
}

/// 把相机/相册原图归一化为可上传的 JPEG（同步版本，供 isolate 入口调用）。
///
/// 相机竖拍照片常以「横像素 + orientation=6」存储，直接上传详情页会横躺；本函数
/// 先烘焙方向再限长边、统一 JPEG，是相册与相机上传前的统一归一化入口。
///
/// 参数：[input] 原图字节与原文件名。
/// 返回：新的 [PickedMedia]（`image/jpeg`，文件名后缀改为 `.jpg`）。
/// 抛出：[MediaPickException] 解码失败，或结果仍超过 [NfrMedia.maxSizeBytes]。
PickedMedia normalizeUploadImage(CropEncodeInput input) {
  final decoded = img.decodeImage(input.bytes);
  if (decoded == null) {
    throw const MediaPickException('图片无法识别，请换一张');
  }
  return _encodeForUpload(img.bakeOrientation(decoded), input.filename);
}

/// 归一化公共核心：长边限幅 + 透明通道白底合成 + JPEG 编码 + 体积校验。
///
/// [normalizeCroppedImage]（裁剪结果）与 [normalizeUploadImage]（相机/相册原图）
/// 共用本核心：二者差异仅在解码失败文案与入口，编码部分完全一致，避免限长边/
/// 白底/编码逻辑二次复制（编码规范 §1.1）。
///
/// 参数：[image] 已解码且已烘焙方向（[img.bakeOrientation]）的图；[filename] 原文件名。
/// 返回：归一化后的 [PickedMedia]。
/// 抛出：[MediaPickException] 结果仍超过 [NfrMedia.maxSizeBytes]。
PickedMedia _encodeForUpload(img.Image image, String filename) {
  var out = image;
  final longEdge = math.max(out.width, out.height);
  if (longEdge > kCroppedMaxLongEdge) {
    final scale = kCroppedMaxLongEdge / longEdge;
    out = img.copyResize(
      out,
      width: math.max(1, (out.width * scale).round()),
      height: math.max(1, (out.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  // JPEG 不支持透明通道：PNG 的透明区域按白底合成，避免编码后出现黑块。
  if (out.hasAlpha) {
    final canvas = img.Image(width: out.width, height: out.height);
    img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(canvas, out);
    out = canvas;
  }

  final encoded = img.encodeJpg(out, quality: kCroppedJpegQuality);
  if (encoded.length > NfrMedia.maxSizeBytes) {
    final limitMb = NfrMedia.maxSizeBytes ~/ (1024 * 1024);
    throw MediaPickException('图片处理后超过 ${limitMb}MB，请换一张图片');
  }

  final baseName = filename.replaceAll(RegExp(r'\.[^.]+$'), '');
  return PickedMedia(
    filename: baseName.isEmpty ? 'image.jpg' : '$baseName.jpg',
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

/// 在后台 isolate 中执行 [normalizeUploadImage]。
///
/// 参数：[input] 原图字节与原文件名。
/// 返回：归一化后的 [PickedMedia]。
/// 抛出：[MediaPickException] 同 [normalizeUploadImage]。
Future<PickedMedia> normalizeUploadImageAsync(CropEncodeInput input) {
  return compute(normalizeUploadImage, input);
}

/// 图片像素尺寸（宽 × 高）。
typedef ImageSize = ({int width, int height});

/// 在后台 isolate 读取图片像素宽高（大图解码避免卡 UI）。
///
/// 参数：[bytes] 图片字节。
/// 返回：宽高；解码失败返回 null。
Future<ImageSize?> readImageSizeAsync(Uint8List bytes) {
  return compute(_decodeSize, bytes);
}

/// 解码并读取宽高（isolate 入口，同步）。
///
/// 参数：[bytes] 图片字节。
/// 返回：宽高；解码失败返回 null。
ImageSize? _decodeSize(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // 烘焙 EXIF 方向：竖拍照片常以「横像素 + orientation=6」存储，不烘焙读出的
  // 宽高是反的，会导致拍后比例体检误判。烘焙只用于读宽高，返回的像素随即丢弃。
  final oriented = img.bakeOrientation(decoded);
  return (width: oriented.width, height: oriented.height);
}

/// 上传前归一化启动器签名。
///
/// 与 [MediaPicker]/[MediaCropLauncher] 同一纪律：把 isolate 里的归一化收敛为
/// 可替换入口，widget 测试注入假实现，避免真实 `compute` 在 fake async 里卡住。
typedef MediaNormalizer = Future<PickedMedia> Function(CropEncodeInput input);

/// 上传前归一化 Provider：生产走 [normalizeUploadImageAsync]，测试覆盖假实现。
final mediaNormalizerProvider = Provider<MediaNormalizer>(
  (ref) => normalizeUploadImageAsync,
);

/// 图片宽高读取启动器签名。
///
/// 与 [MediaNormalizer] 同一纪律：把 isolate 里的解码读宽高收敛为可替换入口，
/// widget 测试注入假实现，避免真实 `compute` 在 fake async 里卡住。
typedef ImageSizeReader = Future<ImageSize?> Function(Uint8List bytes);

/// 图片宽高读取 Provider：生产走 [readImageSizeAsync]，测试覆盖假实现。
final imageSizeReaderProvider = Provider<ImageSizeReader>(
  (ref) => readImageSizeAsync,
);
