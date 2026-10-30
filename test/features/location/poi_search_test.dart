/// POI 候选解析与降级守门测试（计划 R6 / R13 / KTD5）。
///
/// **这些断言防的是什么**：候选列表来自一个第三方接口，字段形态随版本漂移
/// （`address` 有时是字符串、有时是空数组；`location` 是 `"lng,lat"` 字符串）。
/// 解析器若对其中任何一种形态抛错，用户一打字整个选择页就会崩；而若把缺失
/// 坐标的条目也放进来，点选后回填的是一个没有坐标的「地点」——确认按钮看起来
/// 可用，实际提交不了。故这里把「跳过坏条目、失败即空」钉死。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/amap_degrade.dart';
import 'package:zhaoyazhao/features/location/amap_web_service_key.dart';
import 'package:zhaoyazhao/features/location/poi_search.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

/// 构造一条正常的候选条目（测试基线）。
///
/// 参数：[id] POI ID，默认 `B000A1`。
/// 返回：高德 `tips[]` 中的一项。
Map<String, Object?> tip({String id = 'B000A1'}) => <String, Object?>{
  'id': id,
  'name': '回龙观地铁站',
  'address': '北京市昌平区回龙观',
  'district': '昌平区',
  'location': '116.337,40.071',
};

void main() {
  group('parseInputTips 正常路径', () {
    test('解析出名称、地址描述与坐标', () {
      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[tip()],
      });

      expect(tips, hasLength(1));
      expect(tips.first.id, 'B000A1');
      expect(tips.first.name, '回龙观地铁站');
      expect(tips.first.address, '北京市昌平区回龙观');
      expect(tips.first.lng, 116.337);
      expect(tips.first.lat, 40.071);
    });

    test('address 为空数组时退回 district 作为描述', () {
      final raw = tip()..['address'] = const <Object?>[];

      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[raw],
      });

      expect(tips.first.address, '昌平区');
    });

    test('超过上限只保留前 N 条', () {
      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[
          for (var i = 0; i < 30; i++) tip(id: 'B$i'),
        ],
      });

      expect(tips.length, 10);
    });
  });

  group('parseInputTips 坏条目跳过', () {
    test('缺 location / id / name 的条目跳过，其余保留', () {
      final noLocation = tip(id: 'B1')..remove('location');
      final noId = tip()..['id'] = '';
      final noName = tip()..['name'] = '   ';
      final good = tip(id: 'B9');

      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[noLocation, noId, noName, good],
      });

      expect(tips, hasLength(1));
      expect(tips.first.id, 'B9');
    });

    test('location 不是两个数值 → 该条跳过', () {
      final bad = tip()..['location'] = '东经116,北纬40';

      final tips = parseInputTips(<String, Object?>{
        'status': '1',
        'tips': <Object?>[bad, tip(id: 'B2')],
      });

      expect(tips.map((t) => t.id), <String>['B2']);
    });
  });

  group('parseInputTips 失败路径', () {
    test('status != 1 → 空列表', () {
      expect(
        parseInputTips(<String, Object?>{'status': '0', 'tips': <Object?>[tip()]}),
        isEmpty,
      );
    });

    test('非 Map / tips 不是数组 → 空列表', () {
      expect(parseInputTips('不是 JSON 对象'), isEmpty);
      expect(parseInputTips(null), isEmpty);
      expect(parseInputTips(<String, Object?>{'status': '1', 'tips': 'x'}), isEmpty);
    });
  });

  group('请求侧降级', () {
    test('未注入 Key → 不发请求，返回空列表', () async {
      // 测试环境不带 --dart-define，Key 必为空；传入一个「一用就抛」的
      // 客户端，若实现先发了请求，用例会因异常失败而不是静默通过。
      final client = _ThrowingHttpClient();
      AmapDegradeReason? reason;

      final result = await searchPoiSuggestions(
        keywords: '回龙观',
        client: client,
        onDegraded: (r) => reason = r,
      );

      expect(result, isEmpty);
      expect(client.used, isFalse);
      // 未注入 Key 也要报原因，否则线上分不清「没配 Key」与「搜不到」。
      expect(reason, AmapDegradeReason.noKey);
    });

    test('关键词为空 → 不发请求', () async {
      final client = _ThrowingHttpClient();

      await searchPoiSuggestions(keywords: '   ', client: client);

      expect(client.used, isFalse);
    });
  });

  group('请求侧降级（已配置 Key）', () {
    setUp(() => amapWebServiceKeyOverride = 'test-key');
    tearDown(() => amapWebServiceKeyOverride = null);

    test('服务端返回非 200 → 空列表，并回调 http_error', () async {
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(500, const Stream<List<int>>.empty()),
      );

      final result = await searchPoiSuggestions(
        keywords: '回龙观',
        client: client,
        onDegraded: (r) => reason = r,
      );

      expect(result, isEmpty);
      expect(reason, AmapDegradeReason.httpError);
    });

    test('请求抛异常 → 空列表（不向上抛），并回调 network', () async {
      AmapDegradeReason? reason;
      final client = _FakeHttpClient(
        (_) async => throw const SocketException('连接失败'),
      );

      final result = await searchPoiSuggestions(
        keywords: '回龙观',
        client: client,
        onDegraded: (r) => reason = r,
      );

      expect(result, isEmpty);
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
      final result = await searchPoiSuggestions(
        keywords: '回龙观',
        client: client,
        onDegraded: (r) => reason = r,
      );
      final elapsed = DateTime.now().difference(startedAt);

      expect(result, isEmpty);
      expect(reason, AmapDegradeReason.timeout);
      // 只断言「有上限」：真正的回归是永不返回，而不是差几十毫秒。
      expect(
        elapsed.inMilliseconds,
        lessThan(NfrLocation.poiSearchTimeoutMs + 2000),
      );
    });

    test('200 且结构正常 → 解析出候选', () async {
      final client = _FakeHttpClient(
        (_) async => _FakeResponse(
          200,
          Stream<List<int>>.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'status': '1',
                'tips': <Object?>[tip()],
              }),
            ),
          ),
        ),
      );

      final result = await searchPoiSuggestions(
        keywords: '回龙观',
        client: client,
      );

      expect(result, hasLength(1));
      expect(result.first.name, '回龙观地铁站');
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
