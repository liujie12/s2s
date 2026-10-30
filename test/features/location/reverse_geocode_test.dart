import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/amap_degrade.dart';
import 'package:zhaoyazhao/features/location/amap_web_service_key.dart';
import 'package:zhaoyazhao/features/location/reverse_geocode.dart';

void main() {
  /// 在 HttpClientOverrides 下执行一次逆地理（本函数自建客户端，只能这样注入）。
  ///
  /// 参数：[client] 替身；[run] 实际调用。
  /// 返回：[run] 的结果。
  Future<T> withClient<T>(
    _FakeHttpClient client,
    Future<T> Function() run,
  ) => HttpOverrides.runZoned(run, createHttpClient: (_) => client);

  group('未注入 Key', () {
    test('不建客户端、返回空串，并回调 no_key', () async {
      AmapDegradeReason? reason;
      var created = 0;

      final label = await HttpOverrides.runZoned(
        () => reverseGeocodeLabel(
          lat: 40.071,
          lng: 116.337,
          onDegraded: (r) => reason = r,
        ),
        createHttpClient: (_) {
          created++;
          return _FakeHttpClient(
            (_) async => _FakeResponse(200, const Stream<List<int>>.empty()),
          );
        },
      );

      expect(label, '');
      expect(created, 0);
      expect(reason, AmapDegradeReason.noKey);
    });
  });

  group('请求侧降级（已配置 Key）', () {
    setUp(() => amapWebServiceKeyOverride = 'test-key');
    tearDown(() => amapWebServiceKeyOverride = null);

    test('服务端返回非 200 → 空串，并回调 http_error', () async {
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(500, const Stream<List<int>>.empty()),
      );

      final label = await withClient(
        client,
        () => reverseGeocodeLabel(
          lat: 40.071,
          lng: 116.337,
          onDegraded: (r) => reason = r,
        ),
      );

      expect(label, '');
      expect(reason, AmapDegradeReason.httpError);
    });

    test('请求抛异常 → 空串（不向上抛），并回调 network', () async {
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => throw const SocketException('连接失败'),
      );

      final label = await withClient(
        client,
        () => reverseGeocodeLabel(
          lat: 40.071,
          lng: 116.337,
          onDegraded: (r) => reason = r,
        ),
      );

      expect(label, '');
      expect(reason, AmapDegradeReason.network);
    });

    test('响应体停滞 → 有超时上限，并回调 timeout', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(200, body.stream),
      );

      final label = await withClient(
        client,
        () => reverseGeocodeLabel(
          lat: 40.071,
          lng: 116.337,
          onDegraded: (r) => reason = r,
        ),
      );

      expect(label, '');
      expect(reason, AmapDegradeReason.timeout);
    });

    test('200 且结构正常 → 返回格式化地址', () async {
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(
          200,
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'status': '1',
                'regeocode': <String, Object?>{
                  'formatted_address': '北京市昌平区回龙观东大街',
                },
              }),
            ),
          ),
        ),
      );

      final label = await withClient(
        client,
        () => reverseGeocodeLabel(lat: 40.071, lng: 116.337),
      );

      expect(label, '北京市昌平区回龙观东大街');
    });
  });
}

/// 可控的 HttpClient 替身：把它收到的请求换成一个固定响应。
class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._onGet);

  final Future<HttpClientResponse> Function(Uri url) _onGet;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(url, _onGet);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('未预期的 HttpClient 调用');
}

/// 只实现 close() 的请求替身（客户端只用到这一个入口）。
class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.url, this._onGet);

  /// 请求 URL（本替身不校验，仅保留以便排查）。
  final Uri url;
  final Future<HttpClientResponse> Function(Uri url) _onGet;

  @override
  Future<HttpClientResponse> close() => _onGet(url);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('未预期的 HttpClientRequest 调用');
}

/// 固定状态码 + 可控响应体的响应替身。
class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(this.statusCode, this._body);

  @override
  final int statusCode;

  final Stream<List<int>> _body;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _body.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('未预期的 HttpClientResponse 调用');
}
