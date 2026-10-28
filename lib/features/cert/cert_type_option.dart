/// 资质类型选项（[B2-11]）：契约 `CertTypeEnum` 的三类资质与展示名。
///
/// 抽公共件的理由（编码规范 §1.1）：同一组「契约值 ↔ 展示名」映射同时被
/// 信任与认证页（三行）与资质提交表单（类型选择）消费，第二处出现即上浮。
///
/// **不含 `personal_realname`**：实名是「第一层」，走 `POST /cert/realname`
/// 与独立表单，不属资质提交的选项。
library;

/// 可提交的资质类型。
enum CertTypeOption {
  /// 企业认证。
  enterprise('enterprise', '企业认证', [
    '营业执照',
    '开户许可证',
    '企业资质证书',
  ]),

  /// 家政资质（契约 `personal_qualification`）。
  personalQualification('personal_qualification', '家政资质', [
    '家政服务资质',
    '养老护理员证',
    '育婴员证',
    '月嫂证',
    '保洁员证',
  ]),

  /// 车辆认证。
  vehicle('vehicle', '车辆认证', [
    '机动车行驶证',
    '机动车驾驶证',
    '道路运输经营许可证',
  ]);

  const CertTypeOption(this.apiType, this.label, this.suggestedNames);

  /// 契约类型值（`CertTypeEnum`）。
  final String apiType;

  /// 展示名。
  final String label;

  /// 该类型下的默认证件名称候选（用户仍可自由输入新名称）。
  ///
  /// **放前端的理由（2026-10-28 用户裁定）**：本轮只是输入便利，不构成业务数据；
  /// 后续有运营维护需求再迁移到服务端配置下发，届时本常量作为离线兜底。
  final List<String> suggestedNames;

  /// 由契约类型值反查（未知值返回 null，不猜默认）。
  ///
  /// 参数：[apiType] 契约类型值。
  /// 返回：[CertTypeOption]?。
  static CertTypeOption? fromApi(String? apiType) {
    for (final option in values) {
      if (option.apiType == apiType) return option;
    }
    return null;
  }
}
