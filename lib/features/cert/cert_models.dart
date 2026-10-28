/// cert 域数据模型（[149] 建；[B2-11] 扩资质；2026-10-28 产品口径简化）。
///
/// 与后端 `CertService` 出参对齐：实名状态四态（none/pending/passed/rejected）；
/// **资质档案**（`GET /cert/status` 的 `qualifications`）只承载
/// `cert_id`/`cert_name`/`name_source`/`status`/`image_url`。
///
/// 2026-10-28 口径：资质简化为「名称 + 图片」——不再有证件类型与有效期，
/// 提交即 `approved`，不存在 `pending`/`rejected`/`expired`。
///
/// 严格解析（编码规范 F1）：必需字段缺失/类型不符抛 `ApiException.parse`，
/// 不返 null 不静默吞。
library;

import '../../core/contract_json.dart';
import '../../core/network/api_exception.dart';

/// 单条资质档案记录（openapi `QualificationItem`）。
class CertQualification {
  /// 构造资质记录。
  ///
  /// 参数：
  ///   [certId] 资质档案 ID；
  ///   [certName] 证书名称（可空：未命名证书）；
  ///   [nameSource] 证名来源（`ocr`/`manual`，可空）；
  ///   [status] 状态（本轮恒 `approved`）；
  ///   [imageUrl] 证照原件访问地址（可空）。
  const CertQualification({
    required this.certId,
    this.certName,
    this.nameSource,
    required this.status,
    this.imageUrl,
  });

  /// 状态：已通过（本轮提交即此态，也是唯一取值）。
  static const String statusApproved = 'approved';

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
      certName: optString(map, 'cert_name', 'QualificationItem'),
      nameSource: optString(map, 'name_source', 'QualificationItem'),
      status: requireString(map, 'status', 'QualificationItem'),
      imageUrl: optString(map, 'image_url', 'QualificationItem'),
    );
  }

  /// 资质档案 ID（发布挂载、编辑、删除均以此为准）。
  final int certId;

  /// 证书名称；未填写时为空或 null。
  final String? certName;

  /// 证名来源（`ocr`/`manual`；可空）。
  final String? nameSource;

  /// 状态（本轮恒 `approved`）。
  final String status;

  /// 证照原件访问地址（编辑页回填用）；随资质删除失效。
  final String? imageUrl;

  /// 档案行展示名：证书名称优先，空则「未命名证书」（不臆造证名）。
  ///
  /// 参数：无。
  /// 返回：[String]。
  String get displayName {
    final name = certName?.trim() ?? '';
    return name.isEmpty ? '未命名证书' : name;
  }

  /// 是否可作为发布挂载候选（本轮口径：`approved`）。
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

  /// 本人全部资质（本轮恒 `approved`）。
  final List<CertQualification> qualifications;

  /// 是否已实名通过。
  ///
  /// 参数：无。
  /// 返回：bool。
  bool get isRealnamePassed => realnameStatus == 'passed';

  /// 资质数（「我的信任指标」卡的「资质 N 项」；档案均为 `approved`）。
  ///
  /// 参数：无。
  /// 返回：int。
  int get passedQualificationCount => qualifications.length;

  /// 可作为发布挂载候选的资质。
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
  ///
  /// 参数：[certId] 资质档案 ID；[status] 提交后状态。
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

  /// 提交后状态（本轮恒 `approved`）。
  final String status;
}

/// 证照图抽取结果（openapi `CertOcrResult`）。
///
/// 字段可为 null：抽取失败不是错误（仍 200/code=0），由表单提示手填。
class CertOcrResult {
  /// 构造抽取结果。
  ///
  /// 参数：[certName] 抽取到的证书名称；未读出为 null。
  const CertOcrResult({this.certName});

  /// 由契约 JSON 构造。
  ///
  /// 参数：[json] 信封拆出的 data。
  /// 返回：[CertOcrResult]。
  /// 抛出：[ApiException.parse] 字段出现但类型不符时。
  factory CertOcrResult.fromJson(Object? json) {
    final map = requireMap(json, 'CertOcrResult');
    return CertOcrResult(certName: optString(map, 'cert_name', 'CertOcrResult'));
  }

  /// 抽取到的证书名称；未读出为 null。
  final String? certName;

  /// 是否没读出证名（表单据此显示「没读出来，请手动填写」）。
  bool get isEmpty => (certName?.trim() ?? '').isEmpty;
}

/// 资质编辑载荷（openapi `QualificationUpdateRequest`，字段全部可选、至少一项）。
class QualificationUpdateRequest {
  /// 构造编辑载荷。
  ///
  /// 参数：
  ///   [mediaIds] 替换证照图（不传保留原图）；
  ///   [certName] 证书名称；
  ///   [nameSource] 证名来源。
  const QualificationUpdateRequest({
    this.mediaIds,
    this.certName,
    this.nameSource,
  });

  /// 替换证照图（不传保留原图）。
  final List<String>? mediaIds;

  /// 证书名称（可空：允许显式清空）。
  final String? certName;

  /// 证名来源。
  final String? nameSource;

  /// 是否至少传了一项（契约：全空回 40001）。
  bool get hasAny => mediaIds != null || certName != null || nameSource != null;

  /// 构造契约请求体：只出现显式赋值的键。
  ///
  /// 参数：无。
  /// 返回：[Map]，可直接作 PATCH 请求体。
  Map<String, Object?> toJson() => <String, Object?>{
        if (mediaIds != null) 'media_ids': mediaIds,
        if (certName != null) 'cert_name': certName,
        if (nameSource != null) 'name_source': nameSource,
      };
}
