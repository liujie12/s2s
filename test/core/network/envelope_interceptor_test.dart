/// EnvelopeInterceptor / unwrap 测试（详细设计 §11.3，计划 R8 / KTD2 / U3）。
///
/// 覆盖信封纪律的机器断言：
///   4. code==0 且 data=null、request_id=null 均非错误（§11.3 三条易错点）；
///   5. 业务错误码经 `reject(err, true)` 到调用方时是带 requestId/
///      retryAfterSec 的 ApiException（KTD2，U5 才能在 error 向接到 40101）；
///   6. Retry-After 非整数回退 null，不抛解析异常（§11.3）；
///   7. HTML 502（网关不过 Spring 信封）→ networkFailure 且 message 含
///      HTTP 状态码；非信封 200 → parseError（R8 非 Map 分流）；
///  10. parseError message 定长截断，不含超大 body 全文（R5）。
///
/// 全部走生产同款 harness，响应经真实 HTTP 栈返回后由 EnvelopeInterceptor
/// 统一拆包 —— validateStatus: (_) => true 保证所有状态先进 onResponse。
library;

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

import '../../support/network_chain_harness.dart';
import '../../support/test_support.dart';

void main() {
  late NetworkChainHarness harness;

  setUp(() async {
    // 注入即时等待：非信封 5xx 属 autoRetry，位 5 真实化后会重试 2 次，
    // 生产默认退避会真睡 0.8–2.4s（flaky 风险，flaky 零容忍）。
    harness = NetworkChainHarness(
      retrySleeper: (duration) async {},
      retryRandomRatio: () => 0,
    );
    await harness.start();
  });

  tearDown(() => harness.dispose());

  group('code==0 成功信封（§11.3）', () {
    test('data=null 与 request_id=null 同时成立也正常返回（两条易错点合并）', () async {
      // 304 语义走 200：GET /categories/tree 版本相同 + 缓存命中无 request_id。
      harness.stub('GET', '/api/v1/categories/tree', (req) async {
        return const MockResponse(
          body: {'code': 0, 'message': 'ok', 'data': null, 'request_id': null},
        );
      });

      final resp = await harness.dio.get<Object?>('/categories/tree');
      expect(resp.statusCode, 200);
      expect(resp.data, isNull, reason: 'unwrap 返回信封 data，data=null 是合法成功态');
      expect(resp.extra[EnvelopeInterceptor.requestIdExtraKey], isNull,
          reason: 'request_id=null 透传为 null，不判异常、不用 interaction_id 顶替');
    });

    test('成功 data 原样返回，request_id/message 放 response.extra 透传 UI', () async {
      harness.stub('GET', '/api/v1/ping', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(
            data: {'ok': true},
            requestId: 'req_extra_1',
            message: 'pong',
          ),
        );
      });

      final resp = await harness.dio.get<Map<String, Object?>>('/ping');
      expect(resp.data, {'ok': true});
      expect(resp.extra[EnvelopeInterceptor.requestIdExtraKey], 'req_extra_1');
      expect(resp.extra[EnvelopeInterceptor.messageExtraKey], 'pong',
          reason: '§11.4 UI 报错文案的 message 也从信封透传，不另造口径');
    });
  });

  group('业务错误码 reject（KTD2）', () {
    test('42902 信封到调用方为 ApiException，携带 requestId 与整数秒 retryAfterSec', () async {
      harness.stubRateLimited('GET', '/api/v1/posts/1001/contact',
          code: 42902, retryAfter: '3600', requestId: 'req_429_case');

      try {
        await harness.dio.get<Object?>('/posts/1001/contact');
        fail('42902 必须经 reject(err, true) 抛到调用方');
      } on Object catch (error) {
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.contactLimit);
        expect(apiError.requestId, 'req_429_case');
        expect(apiError.retryAfterSec, 3600,
            reason: 'Retry-After 按整数秒 int.tryParse 解析（§11.3）');
        final dioError = error as DioException;
        expect(dioError.requestOptions, isNotNull,
            reason: 'reject 保留 requestOptions，U6 才能 dio.fetch 重放');
      }
    });

    test('40101 信封独立分流（401 fixture 单独造），不带 Retry-After 时为 null', () async {
      harness.stubUnauthorized('GET', '/api/v1/profile',
          requestId: 'req_401_case');

      try {
        await harness.dio.get<Object?>('/profile');
        fail('40101 必须 reject 到调用方（U5 单飞在 error 向拦截）');
      } on Object catch (error) {
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.unauthorized);
        expect(apiError.requestId, 'req_401_case');
        expect(apiError.retryAfterSec, isNull,
            reason: '40101 不在 8 个 Retry-After 码集合内，缺失为正常');
      }
    });

    test('Retry-After: abc 非整数 → retryAfterSec 回退 null，不抛解析异常', () async {
      harness.stubRateLimited('GET', '/api/v1/ai/chat',
          code: 42901, retryAfter: 'abc');

      try {
        await harness.dio.get<Object?>('/ai/chat');
        fail('42901 信封仍须 reject');
      } on Object catch (error) {
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.aiQuotaExceeded);
        expect(apiError.retryAfterSec, isNull,
            reason: 'int.tryParse 失败回退 null/默认退避，解析头本身永不抛异常（§11.3）');
      }
    });
  });

  group('非信封 body 按 HTTP 状态分流（R8：网关/502 HTML 不过 Spring 信封）', () {
    test('HTML 502 → networkFailure，message 含 HTTP 状态码', () async {
      harness.stub('GET', '/api/v1/pins-proxy', (req) async {
        return MockResponse.raw(
          502,
          utf8.encode('<html><body>Bad Gateway: upstream timeout</body></html>'),
        );
      });

      try {
        await harness.dio.get<Object?>('/pins-proxy');
        fail('非信封 5xx 必须 reject');
      } on Object catch (error) {
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.networkFailure,
            reason: '非 Map body 且 5xx：网关直出 HTML，按可重试网络失败处理（R8）');
        expect(apiError.message, contains('502'),
            reason: 'U6 位 5 真实化后自动重试 2 次仍为同一非信封 502，'
                '耗尽终局文案必须逐字保留末次诊断，message 仍须含 HTTP '
                '状态码，否则无法区分 502/503/504');
        final attempts = harness.server.received
            .where((request) => request.path == '/api/v1/pins-proxy')
            .length;
        expect(attempts, 3,
            reason: 'networkFailure 属 autoRetry：首发 + 全链路 2 次重试'
                '（§14.1），本用例经生产同款五拦截器链固化重试交互面');
      }
    });

    test('非信封 200（JSON 数组形态）→ parseError', () async {
      harness.stub('GET', '/api/v1/raw-array', (req) async {
        // 数组能过 JSON 解码，但不是 {code,message,data,request_id} 信封。
        return const MockResponse(body: ['not', 'an', 'envelope']);
      });

      try {
        await harness.dio.get<Object?>('/raw-array');
        fail('非信封 200 必须 reject');
      } on Object catch (error) {
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.parseError,
            reason: '非 Map body 且非 5xx：协议不符，不该重试（R8）');
      }
    });

    test('非信封 200（HTML 形态）→ parseError 而非 networkFailure', () async {
      harness.stub('GET', '/api/v1/login-portal', (req) async {
        return MockResponse.raw(200, utf8.encode('<html>login</html>'));
      });

      try {
        await harness.dio.get<Object?>('/login-portal');
        fail('非信封 200 必须 reject');
      } on Object catch (error) {
        expect(harness.apiErrorOf(error).code, ApiErrorCode.parseError);
      }
    });
  });

  group('parseError message 截断（R5）', () {
    test('超大非信封 body 不进 message 全文，长度不超定长上限', () async {
      final hugeHtml = '<html>${'A' * 50000}</html>';
      harness.stub('GET', '/api/v1/huge', (req) async {
        return MockResponse.raw(200, utf8.encode(hugeHtml));
      });

      try {
        await harness.dio.get<Object?>('/huge');
        fail('超大非信封 body 必须 reject');
      } on Object catch (error) {
        final apiError = harness.apiErrorOf(error);
        expect(apiError.code, ApiErrorCode.parseError);
        expect(apiError.message.length,
            lessThanOrEqualTo(ApiException.maxParseMessageLength));
        expect(apiError.message, isNot(contains('A' * 1000)),
            reason: '原始 body 全文不得灌进 message（R5：定长截断是日志/弹窗防线）');
      }
    });
  });

  group('Retry-After 解析单元行为（整数秒口径）', () {
    test('42907 fixture 带 90 秒 → retryAfterSec=90', () async {
      harness.stubRateLimited('GET', '/api/v1/posts/9/detail',
          code: 42907, retryAfter: '90');

      try {
        await harness.dio.get<Object?>('/posts/9/detail');
        fail('42907 必须 reject');
      } on Object catch (error) {
        expect(harness.apiErrorOf(error).retryAfterSec, 90);
      }
    });
  });
}
