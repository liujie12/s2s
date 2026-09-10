/// 契约测试示范：脚手架用法样例（后端开工后按此模式逐接口复制）。
///
/// 本文件用内存 Mock 服务演示「契约测试长什么样」。后端就绪后，
/// 把 [MockApiServer] 换成真实基址（如 http://localhost:8080/api/v1 或
/// 测试环境域名），断言一行不用改——这正是契约测试的价值：
/// 同一份断言对 mock 与真实服务都成立。
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

  setUp(() async {
    server = MockApiServer();
    baseUrl = await server.start();
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

  test('成功响应为统一包形态（code=0 且四字段齐全）', () async {
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

  test('契约负载可被 JSON 编解码（响应体是合法 JSON）', () async {
    server.stub('GET', '/api/v1/ping', (req) async {
      return MockResponse(body: ApiEnvelope.success(data: {'ok': true}));
    });
    final resp = await dio.get<Map<String, Object?>>('/ping');
    // 能被 dio 解码为 Map 本身即证明响应体是合法 JSON；
    // 再显式编解码一次，作为后端替换时的冒烟断言。
    expect(jsonDecode(jsonEncode(resp.data)), resp.data);
  });
}
