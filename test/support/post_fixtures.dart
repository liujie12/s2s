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
/// 出现形态、attributes 动态对象、author 四态实名、media 两项（他人视角仅 pass）。
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
  // [147] DEC-13：详情出参回发布时落库的脱敏值（可空字段出现形态）。
  'contact_mask': '138****8000',
  'status': 'active',
  'publish_at': '2026-09-01T04:00:00Z',
  'expire_at': '2026-09-08T04:00:00Z',
  'version': 0,
  'media': [
    {
      'media_id': 'm-1',
      'url': 'https://oss.example.com/m-1.jpg',
      'audit_status': 'pass',
      'reject_reason': null,
    },
    {
      'media_id': 'm-2',
      'url': 'https://oss.example.com/m-2.jpg',
      'audit_status': 'pass',
      'reject_reason': null,
    },
  ],
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

/// 构造 `GET /posts/mine` 成功响应 data（契约 `MyPostsResponse` 形态）。
///
/// 两个列表项刻意覆盖两形态：① 在架 + 有价 + 有封面 + 完整度 2；
/// ② 已下架 + 面议（price/price_unit 双 null）+ 无封面 + 完整度 0。
///
/// 返回：[Map] 契约 `GET /posts/mine` 的 data 对象（items/total/page/page_size）。
Map<String, Object?> myPostsPayload() => {
  'items': [
    {
      'id': 1001,
      'type': 'resource',
      'leaf_category_id': 40101,
      'title': '九成新实木餐桌转让',
      'price': 299.0,
      'price_unit': '元',
      'cover_media': {
        'media_id': 'm-1',
        'url': 'https://oss.example.com/m-1.jpg',
        'audit_status': 'pass',
        'reject_reason': null,
      },
      'completeness_level': 2,
      'status': 'active',
      'publish_at': '2026-09-01T04:00:00Z',
      'expire_at': '2026-09-08T04:00:00Z',
      // 帖主视角计数（R7/R8）：真实值形态。
      'view_count': 42,
      'favorite_count': 3,
      'contact_count': 3,
      'version': 1,
    },
    {
      'id': 1002,
      'type': 'demand',
      'leaf_category_id': 30101,
      'title': '求租一室一厅',
      'price': null,
      'price_unit': null,
      'cover_media': null,
      'completeness_level': 0,
      'status': 'offline',
      'publish_at': '2026-08-20T04:00:00Z',
      'expire_at': '2026-08-27T04:00:00Z',
      // 浏览 null = 字段缺失的防御分支；收藏 0 = 真实 0（两形态各留一条）。
      'view_count': null,
      'favorite_count': 0,
      'contact_count': 0,
      'version': 4,
    },
  ],
  'total': 2,
  'page': 1,
  'page_size': 20,
};

/// 登记 `GET /posts/mine` 成功桩（query 参数不影响路由匹配）。
///
/// 参数：[harness] 网络链 harness；[payload] 响应 data（默认 myPostsPayload）。
/// 返回：void。
void stubGetMyPosts(NetworkChainHarness harness, {Map<String, Object?>? payload}) {
  harness.stub('GET', '/api/v1/posts/mine', (req) async {
    return MockResponse(
      body: ApiEnvelope.success(data: payload ?? myPostsPayload()),
    );
  });
}

/// 构造 `POST /posts/{post_id}/repost` 成功响应 data（契约 `RepostDraft`，[B2-8]）。
///
/// 覆盖：属性对象出现形态、`address`/`address_precise` 可空、媒体为空列表、
/// 脱敏联系方式出现形态（**不含明文** —— 契约安全收窄）、`category_available=true`。
///
/// 返回：[Map] 契约 `RepostDraft` 形态的 data 对象。
Map<String, Object?> repostDraftPayload() => {
  'source_post_id': 1002,
  'type': 'resource',
  'leaf_category_id': 10101,
  'title': '九成新实木餐桌转让',
  'price': 299,
  'price_unit': '元',
  'description': '自用一年，成色好',
  'attributes': {'height': '75cm'},
  'lng': 120.15,
  'lat': 30.28,
  'address': null,
  'address_precise': false,
  'media_ids': <String>[],
  'contact_type': 'phone',
  'contact_mask': '138****8000',
  'category_available': true,
};

/// 构造 `PATCH /posts/{id}/status` 成功响应 data（契约四字段）。
///
/// 参数：[status] 变更后状态；[version] 变更后新版本号。
/// 返回：[Map] 契约响应 data 对象。
Map<String, Object?> postStatusResultPayload({
  String status = 'offline',
  int version = 2,
}) => {
  'id': 1001,
  'status': status,
  'expire_at': '2026-09-15T04:00:00Z',
  'version': version,
};

/// 登记 `PATCH /posts/{post_id}/status` 成功桩。
///
/// 参数：[harness] 网络链 harness；[postId] 帖子 ID；[payload] 响应 data。
/// 返回：void。
void stubChangePostStatus(
  NetworkChainHarness harness,
  int postId, {
  Map<String, Object?>? payload,
}) {
  harness.stub('PATCH', '/api/v1/posts/$postId/status', (req) async {
    return MockResponse(
      body: ApiEnvelope.success(data: payload ?? postStatusResultPayload()),
    );
  });
}

