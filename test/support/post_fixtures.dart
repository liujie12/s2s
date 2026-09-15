/// post 域公共测试夹具（[124]/[125] 前端段 / B4 提取）。
///
/// precheck 契约桩：与 category_fixtures 同一提取纪律（编码规范 §1.1），
/// post_repository 网络链测试与 publish_screen widget 测试共用，
/// 域与文件对应不混装。
library;

import 'api_envelope.dart';
import 'mock_api_server.dart';
import 'network_chain_harness.dart';

/// 构造 precheck 通过响应 data（契约 `PrecheckResult`：required =
/// passed/blocks）。
///
/// 返回：[Map] 契约 `PrecheckResult` 形态的 data 对象（passed=true、
/// blocks 空、completeness_level 带 2 覆盖可选字段出现形态）。
Map<String, Object?> precheckPassedPayload() => {
  'passed': true,
  'blocks': <Object?>[],
  'completeness_level': 2,
};

/// 构造 precheck 阻断响应 data：默认五码全给（一次性给全的契约语义）。
///
/// 五码 message 逐字取 PRD §12.5 提示列；40901 带 field 覆盖可选字段
/// 出现形态，其余不带（覆盖出现/缺失两形态）。
///
/// 返回：[Map] 契约 `PrecheckResult` 形态的 data 对象（passed=false）。
Map<String, Object?> precheckBlockedPayload() => {
  'passed': false,
  'blocks': [
    {'code': 40901, 'message': '包含敏感词：xxx，请修改', 'field': 'title'},
    {'code': 40902, 'message': '该图未通过审核，无法发布'},
    {'code': 40303, 'message': '此类信息平台禁止发布'},
    {'code': 40302, 'message': '高敏类目未认证，禁止发布'},
    {'code': 40304, 'message': '未实名发布已达上限'},
  ],
};

/// 构造单码阻断响应 data（widget 测试聚焦单码动作入口用）。
///
/// 参数：[code] 阻断码；[message] 提示文案。
/// 返回：[Map] 契约 `PrecheckResult` 形态的 data 对象。
Map<String, Object?> precheckSingleBlockPayload(int code, String message) => {
  'passed': false,
  'blocks': [
    {'code': code, 'message': message},
  ],
};

/// 登记 `/posts/precheck` 桩：恒回 200 + 指定结果信封。
///
/// 参数：[harness] 网络链 harness；[payload] 响应 data（通常取
///   precheckPassedPayload / precheckBlockedPayload / 单码构造）。
/// 返回：void。
void stubPrecheck(
  NetworkChainHarness harness,
  Map<String, Object?> payload,
) {
  harness.stub('POST', '/api/v1/posts/precheck', (req) async {
    return MockResponse(body: ApiEnvelope.success(data: payload));
  });
}
