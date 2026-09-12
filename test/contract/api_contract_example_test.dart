/// 契约测试示范：脚手架用法样例（后端开工后按此模式逐接口复制）。
///
/// 本文件用内存 Mock 服务演示「契约测试长什么样」。后端就绪后，
/// 以 `--dart-define=S2S_API_BASE_URL=<真实基址>`（如 http://localhost:8080/api/v1
/// 或测试环境域名）直指真实服务。
///
/// 断言分两层（评审 #2：mock 桩字面值与 mock 专属场景在真服务模式下
/// 必红，必须分层，不得伪装通过；复审 #5：信封形态断言下沉为两模式共用，
/// 真服务模式下它不是「是 JSON 即过」的同义反复）：
///   - 两模式共用：契约内真实只读端点（GET /categories）必须回统一信封
///     （成功或失败信封至少其一）——未登录拿到 40101 失败信封同样是合法
///     契约行为；非信封的框架默认错误体（如 Spring 默认 404 JSON）不允许。
///   - mock 专属场景（任意验证码登录成功、限额触发、免登录态幂等头
///     校验）与桩字面值（token='jwt-xxx'、post_id=2001）仅 mock 模式
///     成立：真服务模式以 markTestSkipped 记 N/A，不伪装通过。
/// 后端开工复制本模式时：凡服务端可复现的契约行为（带登录态的缺幂等
/// 键必拒 40001 等）应写成两模式共用断言，勿一概 mock-only。
///
/// 演示的三类契约校验：
///   1. 成功响应必须是统一包形态（code/message/data/request_id）；
///   2. 失败响应 code 非 0、data=null，且 429xx 必须带 Retry-After；
///   3. 写接口缺 Idempotency-Key 必须被拒（40001），带键放行。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_support.dart';

void main() {
  late MockApiServer server;
  late Dio dio;
  late String baseUrl;
  late bool isRealMode;

  setUp(() async {
    server = MockApiServer();
    final mockBaseUrl = await server.start();
    // baseUrl 环境开关（详设 §9 AE1）：`--dart-define=S2S_API_BASE_URL=<基址>`
    // 非空时直指真实服务，缺省或空串回退内存 mock；桩登记两模式逐字一致。
    // mock 始终启动：桩登记行不因模式切换而改动，未用时不产生任何请求。
    // 评审 #2：模式判定收敛为 isRealMode，mock 专属场景与值级断言据此分层。
    const injectedBaseUrl = String.fromEnvironment('S2S_API_BASE_URL');
    isRealMode = injectedBaseUrl.isNotEmpty;
    baseUrl = isRealMode ? injectedBaseUrl : mockBaseUrl;
    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      // 契约错误码用非 2xx 承载，dio 默认会抛 DioException；
      // 契约测试要自己断言状态码与响应体，故关掉状态码异常。
      validateStatus: (_) => true,
      headers: {
        'X-Interaction-Id': TestFixtures.interactionId,
        'X-Device-Id': TestFixtures.deviceId,
      },
    ));
  });

  tearDown(() => server.stop());

  /// mock 专属场景的跳过守卫（复审 #6：唯一承载处，原三份复制收编——
  /// §1.1：同一逻辑出现第 2 次前必须提取为共享实现）。
  ///
  /// 真服务模式下 mock 专属场景不可复现，按评审 #2 记 N/A（markTestSkipped）
  /// 而不伪装通过。参数：[scenario] 场景说明（为何真服务不可复现）。
  /// 返回：`bool`——真服务模式返回 true（用例已标记跳过），调用方应立即 return。
  bool skipMockOnlyInRealMode(String scenario) {
    if (!isRealMode) return false;
    markTestSkipped('$scenario——mock 专属场景，真实服务模式不适用（N/A），'
        '不伪装通过。');
    return true;
  }

  test('成功响应为统一包形态（code=0 且四字段齐全）', () async {
    // mock 专属场景（评审 #2）：mock 接受任意验证码即登录成功，真实服务
    // 不可复现——真服务模式记 N/A，不伪装通过。
    if (skipMockOnlyInRealMode('任意验证码登录成功')) return;
    // 样例：POST /auth/login 成功。
    server.stub('POST', '/api/v1/auth/login', (req) async {
      return MockResponse(
        status: 200,
        body: ApiEnvelope.success(
          data: {
            'token': 'jwt-xxx',
            'expire_at': TestFixtures.rfc3339,
            'is_new_user': true,
          },
          requestId: 'req_demo_1',
        ),
      );
    });

    final resp = await dio.post<Map<String, Object?>>(
      '/auth/login',
      data: {'phone': '13800008000', 'code': '123456'},
    );

    expect(resp.statusCode, 200);
    expect(resp.data, isSuccessEnvelope);
    expect(resp.data?['data'], containsPair('token', 'jwt-xxx'));
  });

  test('42902 失败响应：data=null 且携带 Retry-After 剩余秒数', () async {
    // 触发依赖服务端当日限额状态，真实服务模式不可复现（评审 #2：记 N/A，
    // 不伪装通过）；本条仅 mock 模式判定。
    if (skipMockOnlyInRealMode('42902 触发依赖服务端当日限额状态')) return;
    // 样例：GET /posts/{id}/contact 触发每日联系限额。
    server.stub('GET', '/api/v1/posts/1001/contact', (req) async {
      return MockResponse(
        status: 429,
        headers: {'Retry-After': '3600'},
        body: ApiEnvelope.failure(
          42902,
          '今日查看联系方式次数已达上限',
          requestId: 'req_demo_2',
        ),
      );
    });

    final resp = await dio.get<Map<String, Object?>>('/posts/1001/contact');

    expect(resp.statusCode, 429);
    expect(resp.data, isFailureEnvelope(42902));
    expect(resp.data, hasCodeAlignedWithHttp(429));
    expect(resp.headers.value('retry-after'), '3600',
        reason: '42901–42907 必须回 Retry-After 整数秒');
  });

  test('写接口缺 Idempotency-Key 回 40001，带键放行', () async {
    // mock 专属场景（评审 #2）：本用例不带登录态，真实服务端鉴权链先于
    // 幂等拦截（缺 Token 回 40101 而非 40001），两个分支的响应都是 mock
    // 桩值——真服务模式记 N/A，不伪装通过。
    if (skipMockOnlyInRealMode('缺/带幂等键的响应码依赖 mock 桩与免登录前提')) {
      return;
    }
    // 样例：POST /posts 发布。mock 模拟服务端幂等头校验。
    server.stub('POST', '/api/v1/posts', (req) async {
      final key = req.header('idempotency-key');
      if (key == null || key.isEmpty) {
        return MockResponse(
          status: 400,
          body: ApiEnvelope.failure(40001, '缺少必填参数 Idempotency-Key'),
        );
      }
      return MockResponse(
        status: 200,
        body: ApiEnvelope.success(data: {'post_id': 2001}),
      );
    });

    // 不带幂等键 → 必须被拒。
    final rejected = await dio.post<Map<String, Object?>>(
      '/posts',
      data: {'title': 'test'},
      options: Options(headers: {'Idempotency-Key': null}),
    );
    expect(rejected.statusCode, 400);
    expect(rejected.data, isFailureEnvelope(40001));

    // 带合法 UUID v4 幂等键 → 放行。
    final accepted = await dio.post<Map<String, Object?>>(
      '/posts',
      data: {'title': 'test'},
      options: Options(headers: {'Idempotency-Key': TestFixtures.idempotencyKey}),
    );
    expect(accepted.statusCode, 200);
    expect(accepted.data, isSuccessEnvelope);
    expect(accepted.data?['data'], containsPair('post_id', 2001));
  });

  test('契约内真实只读端点回统一信封（两模式共用，复审 #5 裁决 a）', () async {
    // 两模式共用的最低断言面：打契约中真实存在的只读端点 GET /categories，
    // 响应必须是统一信封（成功或失败信封至少其一；未登录拿到 40101 失败
    // 信封同样是合法契约行为）。非信封的框架默认错误体（如 Spring 默认
    // 404 JSON）不允许——真服务模式下本条是对真实服务的实质契约断言，
    // 取代原「是 JSON 即过」的同义反复冒烟（复审 #5）。
    if (!isRealMode) {
      server.stub('GET', '/api/v1/categories', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {'items': <Object?>[]}),
        );
      });
    }
    // 以 String 接收再手动解码：真服务返回非 JSON（网关 HTML 错误页等）时
    // 给出可读失败，而不是 dio 解码异常。
    final resp = await dio.get<String>('/categories');
    Object? decoded;
    try {
      decoded = jsonDecode(resp.data ?? '');
    } on FormatException {
      decoded = null; // 非 JSON 响应体：下方信封断言给出可读失败
    }
    expect(decoded, anyOf(isSuccessEnvelope, isFailureEnvelope()),
        reason: 'GET /categories 的响应必须是统一信封（成功或失败信封其一）：\n'
            '实际响应（HTTP ${resp.statusCode}）：${resp.data}');
  });
}
