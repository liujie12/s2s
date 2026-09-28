/// 举报原因枚举（PRD §7.7 五项 / §9.10.3 风险分累计；契约
/// `POST /posts/{post_id}/report` 请求体 `reason`）。
///
/// **为什么必须独立成一个文件、且是唯一的「中文措辞 ↔ 契约值」落点**：
/// ① 契约值写错（如把 `wrong_category` 写成 `wrong-category`）服务端会回
///    `40001`，用户看到的是「举报失败」而不知道原因；
/// ② 中文措辞会进 §9.10.3 的风险分权重表，改一个词就与运营配置对不上；
/// ③ 详情页底部的举报面板与举报提交两处若各存一份措辞，改一处必漏另一处
///    （编码规范 §1.1：同一逻辑第 2 次出现前必须提取）。
library;

/// 举报原因：契约值（[apiValue]）与服务端 `report.reason` 列枚举**逐字一致**
/// （服务端由 `ReportReason` 白名单校验，不在列表内回 `40001`）。
enum ReportReason {
  /// 不实信息。
  falseInfo('false_info', '不实信息'),

  /// 诈骗。
  fraud('fraud', '诈骗'),

  /// 违规类目。
  wrongCategory('wrong_category', '违规类目'),

  /// 骚扰。
  harassment('harassment', '骚扰'),

  /// 其他。
  other('other', '其他');

  const ReportReason(this.apiValue, this.label);

  /// 传给服务端的契约值（与服务端 `report.reason` 列取值逐字一致）。
  final String apiValue;

  /// 面板上呈现给用户的中文措辞（PRD §7.7 原文顺序与用词）。
  final String label;
}
