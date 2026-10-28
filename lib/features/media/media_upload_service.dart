/// 媒体上传编排（[B2-11] 上传链路）：票据 → OSS 直传 → commit。
///
/// **为什么直传要用独立裸 dio**：App 的 `dioProvider` 挂了 Authorization、
/// 信封拆包、幂等头、gzip 等拦截器，这些对 OSS 都是污染（OSS 不认识
/// `X-Interaction-Id`，也不返回本项目的信封）。故本服务持有一个**无拦截器**
/// 的裸 dio 只做字节 PUT。
///
/// **为什么裸 dio 不设全局读取超时**：技术栈 §9「图片必须走 OSS 直传」的约束是
/// ECS 仅 3M 带宽。图已在选图阶段预缩到长边 [NfrMedia.uploadLongEdgePx]，故单次
/// PUT 只按 [kOssUploadTimeoutSec] 设上限（停滞快速失败、落到「重试」），
/// 不做自动重试循环（编码红线「前端全局唯一重试点是 RetryInterceptor」）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nfr_constants.dart';
import 'media_picker.dart';
import 'media_repository.dart';

/// 上传成功的媒体。
class UploadedMedia {
  /// 构造上传结果。
  const UploadedMedia({
    required this.mediaId,
    required this.url,
    required this.auditStatus,
  });

  /// 媒体 ID（提交发布/资质时用它组 `media_ids`）。
  final String mediaId;

  /// 带签名的临时访问地址（可直接用于缩略图预览）。
  final String url;

  /// 审核状态（`pending`/`pass`/`reject`）。
  final String auditStatus;
}

/// OSS 直传的发送/接收超时（秒）。
///
/// 图在选图阶段已预缩到长边 [NfrMedia.uploadLongEdgePx]（通常 1–3 秒传完）；
/// 30 秒仍无进展视为停滞。**此前裸 dio 不设读写超时**，一旦对象存储地址不可达
/// 或链路卡住，缩略图会无限转圈（真机表现为「分钟级等待」），故补此上限，
/// 让失败落到条目的「重试」入口，而不是永远等下去。
const int kOssUploadTimeoutSec = 30;

/// 媒体上传编排服务（无实例状态）。
class MediaUploadService {
  /// 构造上传服务。
  ///
  /// 参数：[repository] 服务端两次调用仓库；[ossDio] 无拦截器裸 dio（直传用）。
  MediaUploadService({required MediaRepository repository, required Dio ossDio})
      : _repository = repository,
        _ossDio = ossDio;

  final MediaRepository _repository;
  final Dio _ossDio;

  /// 上传一张已选媒体，返回可提交的媒体结果。
  ///
  /// 链路：`POST /media/upload/ticket` → `PUT {upload_url}`（裸 dio，带
  /// Content-Type，须与签发时一致）→ `POST /media/{id}/commit`。
  ///
  /// 参数：[media] 本地已选媒体。
  /// 返回：[UploadedMedia]。
  /// 抛出：[ApiException] 两次服务端调用的业务错误；
  ///   [DioException] OSS 直传失败（网络/签名过期/超限）。
  Future<UploadedMedia> upload(PickedMedia media) async {
    final ticket = await _repository.createUploadTicket(
      filename: media.filename,
      size: media.size,
      contentType: media.contentType,
    );

    // 直传：不带任何 App 头，Content-Type 必须与签发时一致，否则 OSS 验签失败。
    await _ossDio.put<void>(
      ticket.uploadUrl,
      data: media.bytes,
      options: Options(
        headers: {Headers.contentTypeHeader: media.contentType},
        // OSS 对 3xx 不做重定向跟随（PUT 到签名地址是终态）。
        followRedirects: false,
        // 读写超时见 [kOssUploadTimeoutSec]：正常 1–3 秒，停滞则快速失败可重试。
        sendTimeout: const Duration(seconds: kOssUploadTimeoutSec),
        receiveTimeout: const Duration(seconds: kOssUploadTimeoutSec),
      ),
    );

    final commit = await _repository.commitMedia(mediaId: ticket.mediaId);
    return UploadedMedia(
      mediaId: commit.mediaId,
      url: commit.url,
      auditStatus: commit.auditStatus,
    );
  }
}

/// OSS 直传裸 dio（**不挂拦截器**，理由见本文件头）。
final ossUploadDioProvider = Provider<Dio>(
  (ref) => Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: NfrNetwork.connectTimeoutSec),
    ),
  ),
);

/// 媒体上传服务 Provider。
final mediaUploadServiceProvider = Provider<MediaUploadService>(
  (ref) => MediaUploadService(
    repository: ref.watch(mediaRepositoryProvider),
    ossDio: ref.watch(ossUploadDioProvider),
  ),
);
