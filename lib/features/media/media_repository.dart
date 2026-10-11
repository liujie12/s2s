/// media 域仓库（[B2-11] 上传链路）：两步式直传的两次**服务端**调用。
///
/// 走真网络而非本地替身：请求经 [dioProvider] 生产同款五拦截器链发出，
/// 信封由 EnvelopeInterceptor 拆、业务错误以 [ApiException] 抛出（编码规范 §1.2）。
///
/// **边界**：本仓库只管两次服务端调用（票据签发 + commit）；中间的 OSS 字节
/// 直传**不经本仓库**，由 [MediaUploadService] 用独立裸 dio 完成（理由见该文件）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'media_dto.dart';

/// media 域仓库。
class MediaRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（生产经 [mediaRepositoryProvider] 注入）。
  MediaRepository(this._dio);

  final Dio _dio;

  /// 申请 OSS 直传票据（两步式第 1 步，`POST /media/upload/ticket`）。
  ///
  /// 参数：[filename] 原始文件名；[size] 文件字节数；
  ///   [contentType] MIME 类型（须在服务端白名单内）；[interactionId] 交互 ID。
  /// 返回：[UploadTicketDto]（media_id + upload_url + expire_at）。
  /// 抛出：[ApiException] 信封业务错误（40001 白名单/超限）/ 解析失败。
  Future<UploadTicketDto> createUploadTicket({
    required String filename,
    required int size,
    required String contentType,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/media/upload/ticket',
      data: {
        'filename': filename,
        'size': size,
        'content_type': contentType,
      },
      options: _interactionOptions(interactionId),
    );
    return UploadTicketDto.fromJson(response.data);
  }

  /// 确认媒体上传完成（两步式第 2 步，`POST /media/{media_id}/commit`）。
  ///
  /// 参数：[mediaId] 票据返回的 media_id；[interactionId] 交互 ID。
  /// 返回：[MediaCommitDto]（media_id + url + audit_status）。
  /// 抛出：[ApiException] 信封业务错误（40001 二次校验不符/非本人）/ 解析失败。
  Future<MediaCommitDto> commitMedia({
    required String mediaId,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/media/$mediaId/commit',
      options: _interactionOptions(interactionId),
    );
    return MediaCommitDto.fromJson(response.data);
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options?]；null 时走 BaseOptions 默认，头由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// media 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => MediaRepository(ref.watch(dioProvider)),
);
