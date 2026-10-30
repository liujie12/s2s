/// 驾车路径摘要解析与降级守门测试（计划 R7 / R13）。
///
/// **这些断言防的是什么**：距离与时长是「这条路顺不顺」的唯一量化依据。
/// 解析器把 `status=0`（配额或 Key 问题）当成成功返回 0 米，会让页面显示
/// 「约 0 km」——用户看到的是一个错误的确定值，而非「暂时没有」。故所有
/// 失败分支必须回到 null，由页面隐藏整段（R13）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/amap_degrade.dart';
import 'package:zhaoyazhao/features/location/amap_web_service_key.dart';
import 'package:zhaoyazhao/features/location/driving_route.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

void main() {
  group('parseDrivingSummary 正常路径', () {
    test('取第一条路径的米与秒', () {
      final summary = parseDrivingSummary(<String, Object?>{
        'status': '1',
        'route': <String, Object?>{
          'paths': <Object?>[
            <String, Object?>{'distance': 18500, 'duration': 2100},
            <String, Object?>{'distance': 20000, 'duration': 2400},
          ],
        },
      });

      expect(summary, isNotNull);
      expect(summary!.distanceM, 18500);
      expect(summary.durationS, 2100);
    });

    test('数值是浮点 → 取整数部分（米 / 秒）', () {
      final summary = parseDrivingSummary(<String, Object?>{
        'status': '1',
        'route': <String, Object?>{
          'paths': <Object?>[
            <String, Object?>{'distance': 18500.6, 'duration': 2100.2},
          ],
        },
      });

      expect(summary?.distanceM, 18500);
      expect(summary?.durationS, 2100);
    });
  });

  group('parseDrivingSummary 失败路径', () {
    test('paths 为空 → null', () {
      expect(
        parseDrivingSummary(<String, Object?>{
          'status': '1',
          'route': <String, Object?>{'paths': <Object?>[]},
        }),
        isNull,
      );
    });

    test('status != 1 → null（不返回 0 距离）', () {
      expect(
        parseDrivingSummary(<String, Object?>{'status': '0', 'info': 'INVALID_USER_KEY'}),
        isNull,
      );
    });

    test('缺 route / paths 或数值类型不符 → null', () {
      expect(parseDrivingSummary(<String, Object?>{'status': '1'}), isNull);
      expect(
        parseDrivingSummary(<String, Object?>{
          'status': '1',
          'route': <String, Object?>{
            'paths': <Object?>[
              <String, Object?>{'distance': '很远', 'duration': 2100},
            ],
          },
        }),
        isNull,
      );
    });

    test('非 Map → null', () {
      expect(parseDrivingSummary(null), isNull);
      expect(parseDrivingSummary('oops'), isNull);
    });
  });

  group('请求侧降级', () {
    test('未注入 Key → 不发请求，返回 null 并回调 no_key', () async {
      final client = _ThrowingHttpClient();
      AmapDegradeReason? reason;

      final summary = await fetchDrivingSummary(
        originLng: 116.337,
        originLat: 40.071,
        destinationLng: 116.316,
        destinationLat: 39.983,
        client: client,
        onDegraded: (r) => reason = r,
      );

      expect(summary, isNull);
      expect(client.used, isFalse);
      expect(reason, AmapDegradeReason.noKey);
    });
  });

  group('请求侧降级（已配置 Key）', () {
    setUp(() => amapWebServiceKeyOverride = 'test-key');
    tearDown(() => amapWebServiceKeyOverride = null);

    /// 用给定响应体发起一次请求。
    ///
    /// 参数：[client] 注入的客户端；[onDegraded] 降级回调。
    /// 返回：驾车摘要或 null。
    Future<DrivingSummary?> fetch(
      HttpClient client, {
      void Function(AmapDegradeReason reason)? onDegraded,
    }) => fetchDrivingSummary(
      originLng: 116.337,
      originLat: 40.071,
      destinationLng: 116.316,
      destinationLat: 39.983,
      client: client,
      onDegraded: onDegraded,
    );

    test('服务端返回非 200 → null，并回调 http_error', () async {
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(500, const Stream<List<int>>.empty()),
      );

      final summary = await fetch(client, onDegraded: (r) => reason = r);

      expect(summary, isNull);
      expect(reason, AmapDegradeReason.httpError);
    });

    test('请求抛异常 → null（不向上抛），并回调 network', () async {
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => throw const SocketException('连接失败'),
      );

      final summary = await fetch(client, onDegraded: (r) => reason = r);

      expect(summary, isNull);
      expect(reason, AmapDegradeReason.network);
    });

    test('响应体停滞 → 有超时上限，不永久挂起，并回调 timeout', () async {
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(200, body.stream),
      );

      final startedAt = DateTime.now();
      final summary = await fetch(client, onDegraded: (r) => reason = r);
      final elapsed = DateTime.now().difference(startedAt);

      expect(summary, isNull);
      expect(reason, AmapDegradeReason.timeout);
      expect(
        elapsed.inMilliseconds,
        lessThan(NfrLocation.drivingRouteTimeoutMs + 2000),
      );
    });

    test('200 且结构正常 → 解析出里程与时长', () async {
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(
          200,
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'status': '1',
                'route': <String, Object?>{
                  'paths': <Object?>[
                    <String, Object?>{'distance': 18500, 'duration': 2100},
                  ],
                },
              }),
            ),
          ),
        ),
      );

      final summary = await fetch(client);

      expect(summary, isNotNull);
      expect(summary!.distanceM, 18500);
      expect(summary.durationS, 2100);
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

/// 一被使用就抛异常的 HttpClient（验证「未配置 Key 时不发请求」）。
class _ThrowingHttpClient implements HttpClient {
  /// 是否被调用过（任一请求入口）。
  bool used = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    used = true;
    throw StateError('不应发起网络请求');
  }
}
