/// cert 域数据模型（[149]）：认证状态契约 DTO → 域模型。
///
/// 与后端 `CertService` 出参对齐：实名状态四态（none/pending/passed/rejected）。
/// 资质列表本轮恒空（人工审核未上线，B2-5 落地后展开），域模型暂不承载。
library;

import '../../core/network/api_exception.dart';

/// 认证状态（`GET /cert/status` 响应 data，契约 `CertStatusResponse`）。
class CertStatus {
  const CertStatus({required this.realnameStatus});

  /// 实名状态（none/pending/passed/rejected）。
  final String realnameStatus;

  /// 契约 DTO → 域模型。
  ///
  /// 严格解析（编码规范 F1）：`realname.status` 缺失/类型不符抛
  /// [ApiException.parse]，不返 null 不静默吞。`qualifications` 本轮恒空
  /// （人工审核未上线），仅校验存在性不展开——域模型本轮无资质消费方。
  ///
  /// 参数：[data] 信封拆出的 data（契约 `CertStatusResponse`）。
  /// 返回：[CertStatus] 认证状态。
  static CertStatus fromJson(Object? data) {
    if (data is! Map) {
      throw ApiException.parse('认证状态响应 data 应为 Map，实际: ${data.runtimeType}');
    }
    final realname = data['realname'];
    if (realname is! Map || realname['status'] is! String) {
      throw ApiException.parse('认证状态响应 realname.status 缺失或非 String: $realname');
    }
    return CertStatus(realnameStatus: realname['status'] as String);
  }
}
