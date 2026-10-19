/// 本地选图（[B2-11] 上传链路）：把 `image_picker` 收敛为可测的抽象。
///
/// 设计理由：`image_picker` 依赖平台通道，widget 测试无法驱动；故本文件把
/// 「选图」收敛为 [MediaPicker] 接口，生产用 [ImagePickerMediaPicker]，
/// 测试注入假实现（同 `dioProvider` 的替换纪律）。
///
/// **本轮仅图片**（用户 2026-10-11 裁定）：§5.8 图片 ≤ 9，视频 ≤ 3 待单列条目
/// （视频封面/播放/上传耗时均不同）。故白名单只收 `image/*`（openapi
/// `content_type` enum 三种），HEIC 等未入白名单的格式会被明确拒绝而非静默转换。
library;

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../nfr_constants.dart';

/// 选图/校验失败（本域自有的用户可见错误，不套 API 异常）。
class MediaPickException implements Exception {
  /// 构造选图异常。
  ///
  /// 参数：[userMessage] 面向用户的提示文案。
  const MediaPickException(this.userMessage);

  /// 面向用户的提示文案。
  final String userMessage;

  @override
  String toString() => 'MediaPickException($userMessage)';
}

/// 本地已选中的媒体（尚未上传）。
class PickedMedia {
  /// 构造已选媒体。
  const PickedMedia({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  /// 原始文件名（仅用于记录与后缀推断，不作为对象名）。
  final String filename;

  /// 文件字节。
  final Uint8List bytes;

  /// MIME 类型（必在 [NfrMedia.allowedContentTypes] 内）。
  final String contentType;

  /// 文件字节数。
  int get size => bytes.length;
}

/// 选图器抽象。
abstract interface class MediaPicker {
  /// 从系统图库选图（多选）。
  ///
  /// 参数：[limit] 本次最多可选张数（剩余可上传额度）。
  /// 返回：已选媒体列表（用户取消时为空列表）。
  /// 抛出：[MediaPickException] 格式不在白名单 / 单文件超限时。
  Future<List<PickedMedia>> pickImages({required int limit});

  /// 从系统相机拍摄一张照片（相机优先的默认入口）。
  ///
  /// 返回：拍摄结果；用户取消返回 null。
  /// 抛出：[MediaPickException] 拍摄产物格式不在白名单 / 超限时。
  ///   （相机权限被拒、无摄像头等平台异常不在此收敛，由调用方降级到相册。）
  Future<PickedMedia?> pickFromCamera();
}

/// 基于 `image_picker` 的生产实现。
class ImagePickerMediaPicker implements MediaPicker {
  /// 构造生产选图器。
  ///
  /// 参数：[picker] 可注入的 `ImagePicker`（测试可省略，默认新建）。
  ImagePickerMediaPicker({ImagePicker? picker}) : _picker = picker ?? ImagePicker();

  final ImagePicker _picker;

  @override
  Future<List<PickedMedia>> pickImages({required int limit}) async {
    final files = await _picker.pickMultiImage(limit: limit);
    final result = <PickedMedia>[];
    for (final file in files) {
      result.add(await _toPickedMedia(file));
    }
    return result;
  }

  @override
  Future<PickedMedia?> pickFromCamera() async {
    final file = await _picker.pickImage(source: ImageSource.camera);
    if (file == null) return null;
    return _toPickedMedia(file);
  }

  /// 校验单文件并转为 [PickedMedia]（格式白名单 + 单文件上限）。
  ///
  /// 参数：[file] 选中的文件。
  /// 返回：[PickedMedia]。
  /// 抛出：[MediaPickException] 格式不在白名单 / 单文件超限时。
  Future<PickedMedia> _toPickedMedia(XFile file) async {
    final contentType = _contentTypeOf(file);
    if (contentType == null) {
      throw const MediaPickException('仅支持 JPG / PNG / WebP 图片');
    }
    final bytes = await file.readAsBytes();
    if (bytes.length > NfrMedia.maxSizeBytes) {
      // 文案里的上限由常量算出，不写死数字（编码红线「不复制字面量」）。
      final limitMb = NfrMedia.maxSizeBytes ~/ (1024 * 1024);
      throw MediaPickException('单张图片不能超过 ${limitMb}MB');
    }
    return PickedMedia(filename: file.name, bytes: bytes, contentType: contentType);
  }

  /// 推断 MIME 类型（优先平台声明值，回退文件后缀），不在白名单则返回 null。
  ///
  /// 参数：[file] 选中的文件。
  /// 返回：String? MIME 类型；不可识别/不在白名单时为 null。
  String? _contentTypeOf(XFile file) {
    final declared = file.mimeType;
    if (declared != null && NfrMedia.allowedContentTypes.contains(declared)) {
      return declared;
    }
    final name = file.name.toLowerCase();
    if (name.endsWith('.png')) return 'image/png';
    if (name.endsWith('.webp')) return 'image/webp';
    if (name.endsWith('.jpg') || name.endsWith('.jpeg')) return 'image/jpeg';
    return null;
  }
}

/// 选图器 Provider（测试用假实现覆盖）。
final mediaPickerProvider = Provider<MediaPicker>((ref) => ImagePickerMediaPicker());
