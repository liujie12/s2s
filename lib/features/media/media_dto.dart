/// media 域数据模型（[B2-11] 上传链路）：两步式直传的契约 DTO。
///
/// 对应 openapi：`POST /media/upload/ticket` 的 `UploadTicket` 与
/// `POST /media/{media_id}/commit` 的 `MediaCommitResult`。
library;

import '../../core/contract_json.dart';

/// OSS 直传票据（openapi `UploadTicket`，required = media_id/upload_url/expire_at）。
class UploadTicketDto {
  /// 构造票据。
  const UploadTicketDto({
    required this.mediaId,
    required this.uploadUrl,
    required this.expireAt,
  });

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] 信封拆出的 data。
  /// 返回：[UploadTicketDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory UploadTicketDto.fromJson(Object? json) {
    final map = requireMap(json, 'UploadTicket');
    return UploadTicketDto(
      mediaId: requireString(map, 'media_id', 'UploadTicket'),
      uploadUrl: requireString(map, 'upload_url', 'UploadTicket'),
      expireAt: requireDateTime(map, 'expire_at', 'UploadTicket'),
    );
  }

  /// 媒体 ID（**服务端生成**，客户端不可指定）。
  final String mediaId;

  /// 带签名的短时效直传地址（客户端不持有任何长期密钥）。
  final String uploadUrl;

  /// 票据到期时间。
  final DateTime expireAt;
}

/// 媒体 commit 结果（openapi `MediaCommitResult`，required = media_id/url/audit_status）。
class MediaCommitDto {
  /// 构造 commit 结果。
  const MediaCommitDto({
    required this.mediaId,
    required this.url,
    required this.auditStatus,
    this.rejectReason,
  });

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] 信封拆出的 data。
  /// 返回：[MediaCommitDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory MediaCommitDto.fromJson(Object? json) {
    final map = requireMap(json, 'MediaCommitResult');
    return MediaCommitDto(
      mediaId: requireString(map, 'media_id', 'MediaCommitResult'),
      url: requireString(map, 'url', 'MediaCommitResult'),
      auditStatus: requireString(map, 'audit_status', 'MediaCommitResult'),
      rejectReason: optString(map, 'reject_reason', 'MediaCommitResult'),
    );
  }

  /// 媒体 ID。
  final String mediaId;

  /// 带签名的临时访问地址（桶不开公共读）。
  final String url;

  /// 审核状态（`pending`/`pass`/`reject`）。
  final String auditStatus;

  /// 拒绝原因（仅 `audit_status=reject` 且本人视角时下发）。
  final String? rejectReason;
}
