/// MockApiServer 诚实性红线自证（复审 #9）。
///
/// 红线（评审 #13）：mock 自身出错（路由未登记 / handler 异常）必须返回
/// **非信封体**——若被改回合法 ApiError 信封，契约断言会把「测试写错了」
/// 当「服务端契约行为」放过，测试失去自证能力。本组是该红线的回归守护：
/// _writePlain 被改回 _writeJson 时立即变红。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/test_support.dart';

void main() {
  late MockApiServer server;
  late Dio dio;

  setUp(() async {
    server = MockApiServer();
    final baseUrl = await server.start();
    // validateStatus 全放行：本组要自己断言 4xx/5xx 状态码。
    dio = Dio(BaseOptions(baseUrl: baseUrl, validateStatus: (_) => true));
  });

  tearDown(() => server.stop());

  test('未登记路由返回 501 非信封纯文本（测试缺陷不得伪装成契约行为）', () async {
    // 刻意不 stub：直接打任意路径，触发 _writePlain(501)。
    final resp = await dio.get<String>('/anything/unregistered');

    expect(resp.statusCode, 501);
    expect(resp.headers.value('content-type'), isNot(contains('json')),
        reason: 'mock 自身错误必须是非 JSON 纯文本，信封断言才会当场失败');
    final body = resp.data ?? '';
    expect(body, contains('MOCK ERROR'));
    // 非信封红线：响应体不得出现统一信封的标志性字段。
    expect(body, isNot(contains('request_id')));
    expect(body, isNot(contains('"code"')));
  });

  test('handler 抛异常返回 500 非信封纯文本', () async {
    server.stub('GET', '/api/v1/boom', (req) async {
      throw StateError('故意制造的 handler 异常');
    });

    final resp = await dio.get<String>('/boom');

    expect(resp.statusCode, 500);
    expect(resp.headers.value('content-type'), isNot(contains('json')));
    final body = resp.data ?? '';
    expect(body, contains('MOCK ERROR'));
    expect(body, contains('故意制造的 handler 异常'));
    expect(body, isNot(contains('request_id')));
    expect(body, isNot(contains('"code"')));
  });
}
