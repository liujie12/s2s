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

/// 构造 `POST /posts` 成功响应 data（契约 `PostDetail` required 8 字段）。
///
/// 返回：[Map] 契约 `PostDetail` 形态的 data 对象（id=1001、version=0、
/// status=active、completeness_level=1）。
Map<String, Object?> postCreatedPayload() => {
  'id': 1001,
  'type': 'resource',
  'leaf_category_id': 40101,
  'l2_category_id': 401,
  'title': '九成新实木餐桌转让',
  'status': 'active',
  'version': 0,
  'completeness_level': 1,
};

/// 登记 `POST /posts` 成功桩（回执帖 1001）。
///
/// 参数：[harness] 网络链 harness。
/// 返回：void。
void stubCreatePost(NetworkChainHarness harness) {
  harness.stub('POST', '/api/v1/posts', (req) async {
    return MockResponse(body: ApiEnvelope.success(data: postCreatedPayload()));
  });
}

/// 登记 `POST /posts` 失败桩（信封业务错误，如发布阻断五码/40001）。
///
/// 参数：[harness] 网络链 harness；[code] 信封错误码；[message] 提示。
/// 返回：void。
void stubCreatePostFailure(
  NetworkChainHarness harness,
  int code,
  String message,
) {
  harness.stub('POST', '/api/v1/posts', (req) async {
    return MockResponse(status: 409, body: ApiEnvelope.failure(code, message));
  });
}

/// 构造 `GET /posts/{id}` 成功响应 data（契约 `PostDetail`，详情页消费字段）。
///
/// 返回：[Map] 契约 `PostDetail` 形态的 data 对象。覆盖 price/price_unit
/// 出现形态、attributes 动态对象、author 四态实名。
Map<String, Object?> postDetailPayload() => {
  'id': 1001,
  'type': 'resource',
  'leaf_category_id': 40101,
  'l2_category_id': 401,
  'category_path': ['生活', '二手闲置转让', '家具家电'],
  'title': '九成新实木餐桌转让',
  'price': 299.0,
  'price_unit': '元',
  'description': '九成新，无破损，可小刀',
  'attributes': {'成色': '9 成新', '交易方式': '自提'},
  'lng': 120.1551,
  'lat': 30.2741,
  'address': '文三路 100 号',
  'completeness_level': 2,
  'status': 'active',
  'publish_at': '2026-09-01T04:00:00Z',
  'expire_at': '2026-09-08T04:00:00Z',
  'version': 0,
  'author': {
    'id': 7,
    'nickname': '王师傅',
    'avatar_url': null,
    'realname_status': 'passed',
    'qualification_badges': <Object?>[],
  },
};

/// 登记 `GET /posts/{post_id}` 成功桩（mock 精确路径匹配，须带 postId）。
///
/// 参数：[harness] 网络链 harness；[postId] 帖子 ID；[payload] 响应 data
///   （默认 postDetailPayload）。
/// 返回：void。
void stubGetPostDetail(
  NetworkChainHarness harness,
  int postId, {
  Map<String, Object?>? payload,
}) {
  harness.stub('GET', '/api/v1/posts/$postId', (req) async {
    return MockResponse(
      body: ApiEnvelope.success(data: payload ?? postDetailPayload()),
    );
  });
}
