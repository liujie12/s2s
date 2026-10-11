/// cert 域数据模型（[149] 建；[B2-11] 扩资质）。
///
/// 与后端 `CertService` 出参对齐：实名状态四态（none/pending/passed/rejected）；
/// **资质列表**（[B2-11] 起承载，`GET /cert/status` 的 `qualifications`）——
/// 契约 `QualificationItem` = `{type, status, expire_at}`。
///
/// 严格解析（编码规范 F1）：必需字段缺失/类型不符抛 `ApiException.parse`，
/// 不返 null 不静默吞。
library;

import '../../core/contract_json.dart';
import '../../core/network/api_exception.dart';

/// 单条资质认证记录（openapi `QualificationItem`）。
class CertQualification {
  /// 构造资质记录。
  const CertQualification({required this.type, required this.status, this.expireAt});

  /// 状态：审核中（契约 `QualificationItem.status` enum 成员）。
  static const String statusPending = 'pending';

  /// 状态：已通过。
  static const String statusApproved = 'approved';

  /// 状态：未通过。
  static const String statusRejected = 'rejected';

  /// 状态：已过期。
  static const String statusExpired = 'expired';

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] `CertStatusResponse.qualifications[]` 元素。
  /// 返回：[CertQualification]。
  /// 抛出：[ApiException.parse] `type`/`status` 缺失或类型不符时。
  factory CertQualification.fromJson(Object? json) {
    final map = requireMap(json, 'QualificationItem');
    return CertQualification(
      type: requireString(map, 'type', 'QualificationItem'),
      status: requireString(map, 'status', 'QualificationItem'),
      expireAt: optDateTime(map, 'expire_at', 'QualificationItem'),
    );
  }

  /// 认证类型（`personal_qualification`/`enterprise`/`vehicle`）。
  final String type;

  /// 状态（`pending`/`approved`/`rejected`/`expired`；未提交不出现）。
  final String status;

  /// 有效期（可空）。
  final DateTime? expireAt;
}

/// 认证状态（`GET /cert/status` 响应 data，契约 `CertStatusResponse`）。
class CertStatus {
  /// 构造认证状态。
  const CertStatus({required this.realnameStatus, required this.qualifications});

  /// 实名状态（none/pending/passed/rejected）。
  final String realnameStatus;

  /// 资质记录列表（本轮后端人工审核未上线，通常为空）。
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
      if (item.type == type) return item;
    }
    return null;
  }

  /// 已通过的资质数（「我的信任指标」卡的「资质 N 项」）。
  ///
  /// 参数：无。
  /// 返回：int。
  int get passedQualificationCount =>
      qualifications.where((item) => item.status == CertQualification.statusApproved).length;

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

/// 资质提交结果（openapi `QualificationSubmitResult`，required = status/sla_hours）。
class QualificationSubmitResult {
  /// 构造提交结果。
  const QualificationSubmitResult({required this.status, required this.slaHours});

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] 信封拆出的 data。
  /// 返回：[QualificationSubmitResult]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory QualificationSubmitResult.fromJson(Object? json) {
    final map = requireMap(json, 'QualificationSubmitResult');
    return QualificationSubmitResult(
      status: requireString(map, 'status', 'QualificationSubmitResult'),
      slaHours: requireInt(map, 'sla_hours', 'QualificationSubmitResult'),
    );
  }

  /// 提交后状态（契约本轮恒 `pending`）。
  final String status;

  /// 人工审核 SLA（小时）。
  final int slaHours;
}
