/// cert 域数据模型（[149] 建；[B2-11] 扩资质；本轮资质档案化）。
///
/// 与后端 `CertService` 出参对齐：实名状态四态（none/pending/passed/rejected）；
/// **资质档案**（`GET /cert/status` 的 `qualifications`）承载 `QualificationItem`
/// 全字段（`cert_id`/`cert_type`/`cert_name`/`name_source`/`status`/
/// `expire_type`/`expire_at`/`image_url`）。
///
/// 严格解析（编码规范 F1）：必需字段缺失/类型不符抛 `ApiException.parse`，
/// 不返 null 不静默吞。
///
/// **有效期口径**（契约 `expire_at` description）：字段语义是「有效期至（含本日）」，
/// 证件只给年月时落**当月最后一天 23:59:59 +08:00**。提交侧用
/// [expireAtWireFromYearMonth] 生成该值，展示侧用 [formatYearMonth] 归一。
library;

import '../../core/contract_json.dart';
import '../../core/network/api_exception.dart';
import 'cert_type_option.dart';

/// 单条资质档案记录（openapi `QualificationItem`）。
class CertQualification {
  /// 构造资质记录。
  const CertQualification({
    required this.certId,
    required this.certType,
    this.certName,
    this.nameSource,
    required this.status,
    required this.expireType,
    this.expireAt,
    this.imageUrl,
  });

  /// 状态：审核中（本轮不写入，保留供将来重开审核）。
  static const String statusPending = 'pending';

  /// 状态：已通过（本轮提交即此态）。
  static const String statusApproved = 'approved';

  /// 状态：未通过（本轮不写入）。
  static const String statusRejected = 'rejected';

  /// 状态：已过期（每日任务写入）。
  static const String statusExpired = 'expired';

  /// 有效期类型：有到期日。
  static const String expireTypeDated = 'dated';

  /// 有效期类型：长期有效（不参与到期流转）。
  static const String expireTypePermanent = 'permanent';

  /// 证名来源：OCR 抽取（用户未改）。
  static const String nameSourceOcr = 'ocr';

  /// 证名来源：用户手工填写/改写。
  static const String nameSourceManual = 'manual';

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] `CertStatusResponse.qualifications[]` 元素。
  /// 返回：[CertQualification]。
  /// 抛出：[ApiException.parse] required 字段缺失或类型不符时。
  factory CertQualification.fromJson(Object? json) {
    final map = requireMap(json, 'QualificationItem');
    return CertQualification(
      certId: requireInt(map, 'cert_id', 'QualificationItem'),
      certType: requireString(map, 'cert_type', 'QualificationItem'),
      certName: optString(map, 'cert_name', 'QualificationItem'),
      nameSource: optString(map, 'name_source', 'QualificationItem'),
      status: requireString(map, 'status', 'QualificationItem'),
      expireType: requireString(map, 'expire_type', 'QualificationItem'),
      expireAt: optDateTime(map, 'expire_at', 'QualificationItem'),
      imageUrl: optString(map, 'image_url', 'QualificationItem'),
    );
  }

  /// 资质档案 ID（发布挂载、编辑、删除均以此为准）。
  final int certId;

  /// 资质类型（契约 `CertTypeEnum`）。
  final String certType;

  /// 证书名称；历史行或抽取失败且未填时为空。
  final String? certName;

  /// 证名来源（`ocr`/`manual`；历史行可空）。
  final String? nameSource;

  /// 状态（`pending`/`approved`/`rejected`/`expired`）。
  final String status;

  /// 有效期类型（`dated`/`permanent`）。
  final String expireType;

  /// 有效期至；`permanent` 时为 null。
  final DateTime? expireAt;

  /// 证照原件访问地址（编辑页回填用）；随资质删除失效。
  final String? imageUrl;

  /// 是否长期有效。
  bool get isPermanent => expireType == expireTypePermanent;

  /// 档案行展示名：证书名称优先，空则回落到类型展示名（不臆造）。
  String get displayName {
    final name = certName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    return CertTypeOption.fromApi(certType)?.label ?? certType;
  }

  /// 档案行状态文案（方案文案表逐字）：
  /// `有效期至 YYYY-MM` / `长期有效` / `已于 YYYY-MM 过期`。
  ///
  /// 参数：无。
  /// 返回：[String]。
  String get archiveStatusLabel {
    if (status == statusExpired) {
      final at = expireAt;
      return at == null ? '已过期' : '已于 ${formatYearMonth(at)} 过期';
    }
    if (isPermanent) return '长期有效';
    final at = expireAt;
    return at == null ? '有效期未填写' : '有效期至 ${formatYearMonth(at)}';
  }

  /// 是否可作为发布挂载候选（本轮口径：`approved` 且未过期）。
  ///
  /// 到期由每日任务写入 `expired`，故 `approved` 即「当前有效」；`permanent`
  /// 记录同样有效。
  ///
  /// 参数：无。
  /// 返回：bool。
  bool get isAttachable => status == statusApproved;
}

/// 认证状态（`GET /cert/status` 响应 data，契约 `CertStatusResponse`）。
class CertStatus {
  /// 构造认证状态。
  const CertStatus({required this.realnameStatus, required this.qualifications});

  /// 实名状态（none/pending/passed/rejected）。
  final String realnameStatus;

  /// 本人全部资质（approved / expired）。
  final List<CertQualification> qualifications;

  /// 是否已实名通过。
  ///
  /// 参数：无。
  /// 返回：bool。
  bool get isRealnamePassed => realnameStatus == 'passed';

  /// 取某类型的资质记录（未提交返回 null）。
  ///
  /// 参数：[type] 契约类型值。
  /// 返回：[CertQualification]?。
  CertQualification? qualificationOf(String type) {
    for (final item in qualifications) {
      if (item.certType == type) return item;
    }
    return null;
  }

  /// 已通过的资质数（「我的信任指标」卡的「资质 N 项」）。
  ///
  /// 参数：无。
  /// 返回：int。
  int get passedQualificationCount =>
      qualifications.where((item) => item.status == CertQualification.statusApproved).length;

  /// 可作为发布挂载候选的资质（`approved` 且未过期）。
  ///
  /// 参数：无。
  /// 返回：[List<CertQualification>]（保持服务端顺序）。
  List<CertQualification> get attachableQualifications =>
      qualifications.where((item) => item.isAttachable).toList();

  /// 契约 DTO → 域模型。
  ///
  /// 参数：[data] 信封拆出的 data（契约 `CertStatusResponse`）。
  /// 返回：[CertStatus] 认证状态。
  /// 抛出：[ApiException.parse] 必需字段缺失/类型不符时。
  static CertStatus fromJson(Object? data) {
    final map = requireMap(data, 'CertStatusResponse');
    final realname = requireMap(map['realname'], 'CertStatusResponse.realname');
    return CertStatus(
      realnameStatus: requireString(realname, 'status', 'CertStatusResponse.realname'),
      qualifications: [
        for (final item in requireList(map, 'qualifications', 'CertStatusResponse'))
          CertQualification.fromJson(item),
      ],
    );
  }
}

/// 资质提交/编辑结果（openapi `QualificationSubmitResult`，required = cert_id/status）。
class QualificationSubmitResult {
  /// 构造提交结果。
  const QualificationSubmitResult({required this.certId, required this.status});

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] 信封拆出的 data。
  /// 返回：[QualificationSubmitResult]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory QualificationSubmitResult.fromJson(Object? json) {
    final map = requireMap(json, 'QualificationSubmitResult');
    return QualificationSubmitResult(
      certId: requireInt(map, 'cert_id', 'QualificationSubmitResult'),
      status: requireString(map, 'status', 'QualificationSubmitResult'),
    );
  }

  /// 资质档案 ID。
  final int certId;

  /// 提交后状态（本轮恒 `approved`，已过期的有效期则直接 `expired`）。
  final String status;
}

/// 证照图抽取结果（openapi `CertOcrResult`）。
///
/// 两个字段都可为 null：抽取失败不是错误（仍 200/code=0），由表单提示手填。
class CertOcrResult {
  /// 构造抽取结果。
  const CertOcrResult({this.certName, this.expireAt});

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] 信封拆出的 data。
  /// 返回：[CertOcrResult]。
  /// 抛出：[ApiException.parse] 字段出现但类型不符时。
  factory CertOcrResult.fromJson(Object? json) {
    final map = requireMap(json, 'CertOcrResult');
    return CertOcrResult(
      certName: optString(map, 'cert_name', 'CertOcrResult'),
      expireAt: optDateTime(map, 'expire_at', 'CertOcrResult'),
    );
  }

  /// 抽取到的证书名称；未读出为 null。
  final String? certName;

  /// 抽取到的有效期至；未读出为 null。
  final DateTime? expireAt;

  /// 是否两个字段都没读出来（表单据此显示「没读出来，请手动填写」）。
  bool get isEmpty => certName == null && expireAt == null;
}

/// 资质编辑载荷（openapi `QualificationUpdateRequest`，字段全部可选、至少一项）。
class QualificationUpdateRequest {
  /// 构造编辑载荷。
  const QualificationUpdateRequest({
    this.mediaIds,
    this.certName,
    this.nameSource,
    this.expireType,
    this.expireAt,
  });

  /// 替换证照图（只换图，不触发抽取；不传保留原图）。
  final List<String>? mediaIds;

  /// 证书名称（可空：允许显式清空）。
  final String? certName;

  /// 证名来源。
  final String? nameSource;

  /// 有效期类型。
  final String? expireType;

  /// 有效期至（wire 值，见 [expireAtWireFromYearMonth]）。
  final String? expireAt;

  /// 是否至少传了一项（契约：全空回 40001）。
  bool get isEmpty =>
      mediaIds == null && certName == null && nameSource == null && expireType == null && expireAt == null;

  /// 构造契约请求体：只出现显式赋值的键。
  ///
  /// 参数：无。
  /// 返回：[Map]，可直接作 PATCH 请求体。
  Map<String, Object?> toJson() => <String, Object?>{
        if (mediaIds != null) 'media_ids': mediaIds,
        if (certName != null) 'cert_name': certName,
        if (nameSource != null) 'name_source': nameSource,
        if (expireType != null) 'expire_type': expireType,
        // permanent 时契约忽略 expire_at，仍显式传 null 表达「清掉旧到期日」。
        if (expireType == CertQualification.expireTypePermanent) 'expire_at': null,
        if (expireType != CertQualification.expireTypePermanent && expireAt != null)
          'expire_at': expireAt,
      };
}

/// 「有效期至 某年某月」→ 契约 wire 值（当月最后一天 23:59:59 +08:00）。
///
/// 契约口径：`expire_at` 语义是「有效期至（含本日）」，「2027-06」落
/// `2027-06-30T23:59:59+08:00`，保证该月内仍有效。
///
/// 参数：[year] 年；[month] 月（1–12）。
/// 返回：[String] RFC3339 字符串（固定 +08:00 偏移，不随设备时区漂移）。
String expireAtWireFromYearMonth(int year, int month) {
  // 下月第 0 天 = 本月最后一天（Dart 月末自动溢出）。
  final lastDay = DateTime(year, month + 1, 0).day;
  final mm = month.toString().padLeft(2, '0');
  final dd = lastDay.toString().padLeft(2, '0');
  return '$year-$mm-${dd}T23:59:59+08:00';
}

/// 时间 → 「YYYY-MM」（展示口径）。
///
/// **不转本地时区**：本域时间只承载「哪个月到期」，`toLocal()` 在东十四区会把
/// `2027-06-30T23:59:59+08:00` 推到 7 月，展示出少一个月的有效期。
///
/// 参数：[time] 契约返回的时间。
/// 返回：[String]。
String formatYearMonth(DateTime time) =>
    '${time.year}-${time.month.toString().padLeft(2, '0')}';

/// 时间 → 年月元组（表单回填 OCR 结果用）。
///
/// 参数：[time] 契约返回的时间。
/// 返回：`({int year, int month})`。
({int year, int month}) yearMonthOf(DateTime time) =>
    (year: time.year, month: time.month);
