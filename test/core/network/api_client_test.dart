/// api_client 测试（计划 R12 超时部分 / KTD8 注入缝 / KTD2，U3）。
///
/// 覆盖：
///   - 全局超时引 NfrNetwork 常量（连接 5s、读 10s），不复制字面量；
///   - `/map/pins` 以 Per-Request Options 覆盖读超时为 3s（§14.1），
///     mock 延迟触发真实 receiveTimeout（DioException 类型）；
///   - KTD8：release==true 且 baseUrl 非 https → 启动快速失败；
///     release==false 允许 http mock 地址（两态各一测）；
///   - KTD2：validateStatus: (_) => true，HTTP 429 不交给 dio 抛，
///     统一进 EnvelopeInterceptor 分流。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;

  setUp(() async {
    // 注入即时等待：超时错误经链尾归一点包装为 networkFailure（autoRetry），
    // 位 5 真实化后会重试 2 次，生产默认退避会真睡 0.8–2.4s（本用例单次
    // 尝试就要墙钟等满 3s 读超时，再叠加真睡会逼近用例 15s 上限，flaky）。
    harness = NetworkChainHarness(
      retrySleeper: (duration) async {},
      retryRandomRatio: () => 0,
    );
    await harness.start();
  });

  tearDown(() => harness.dispose());

  group('全局超时引 NfrNetwork（R12 / §14.1）', () {
    test('connectTimeout 与 receiveTimeout 取值与常量真源一致', () {
      final options = harness.dio.options;
      expect(options.connectTimeout?.inSeconds,
          NfrNetwork.connectTimeoutSec,
          reason: '连接 5s 只引 NfrNetwork.connectTimeoutSec（不复制字面量）');
      expect(options.receiveTimeout?.inSeconds, NfrNetwork.readTimeoutSec,
          reason: '读取 10s 只引 NfrNetwork.readTimeoutSec');
    });

    test('mapPinsOptions 覆盖读超时为 3s，其余超时不动', () {
      final options = mapPinsOptions();
      expect(options.receiveTimeout?.inSeconds,
          NfrNetwork.mapPinsReadTimeoutSec,
          reason: '/map/pins 读 3s（收紧档），以 Per-Request Options 覆盖（§14.1）');
      // 只收紧读超时；连接超时不随单请求选项漂移。
      expect(options.connectTimeout, isNull,
          reason: 'Per-Request Options 只覆盖读超时，全局 5s 连接超时继续生效');
      expect(NfrNetwork.mapPinsReadTimeoutSec, 3);
      expect(NfrNetwork.readTimeoutSec, 10);
    });
  });

  group('/map/pins 读超时 3s 行为（R12，真实延迟触发；U6 位 5 真实化）',
      () {
    test('mock 延迟超过 3s → receiveTimeout 被链尾归一为 networkFailure 并'
        '重试 2 次；墙钟 ~9s 证明生效的是 3s 收紧档而非全局 10s', () async {
      // 桩按请求 path 是否要求延迟分流：慢请求挂起 5s（>3s 收紧档、
      // <10s 全局档），快请求立即回。
      harness.stub('GET', '/api/v1/map/pins', (req) async {
        final slow = req.path.contains('slow=1');
        if (slow) {
          await Future<void>.delayed(const Duration(seconds: 5));
        }
        return MockResponse(body: ApiEnvelope.success(data: {'pins': const []}));
      });

      // 慢请求：每次尝试都在 3s 覆盖档触发 receiveTimeout。dio 传输层错误
      // 不是信封错误，经链尾 RetryInterceptor 唯一归一点（KTD10）包装为
      // networkFailure（autoRetry），首发 + 2 次重试后耗尽；落调用方的
      // DioException 已归一为 unknown/ApiException(networkFailure)。
      final startedAt = DateTime.now();
      Object? captured;
      try {
        await harness.dio.get<Object?>('/map/pins?slow=1',
            options: mapPinsOptions());
        fail('3s 读超时必须失败');
      } on Object catch (error) {
        captured = error;
      }
      final elapsed = DateTime.now().difference(startedAt);

      final terminalDioError = captured as DioException;
      expect(terminalDioError.type, DioExceptionType.unknown,
          reason: 'receiveTimeout 在链尾唯一归一点已穿 ApiException 外衣'
              '（KTD10），调用方不再见裸 receiveTimeout 形态');
      final apiError = harness.apiErrorOf(captured);
      expect(apiError.code, ApiErrorCode.networkFailure);
      expect(apiError.message, contains('receiveTimeout'),
          reason: '耗尽终局文案逐字保留末次传输诊断，须能区分接收超时/'
              '连接超时/连接拒绝');
      final slowRequests = harness.server.received
          .where((request) => request.path.contains('slow=1'))
          .length;
      expect(slowRequests, 3, reason: '首发 + 全链路 2 次重试（§14.1）');

      // 墙钟是 3s 收紧档的唯一可观测证据：3 次尝试 × 3s ≈ 9s。
      // 下界 7s 与「3 次全局 10s（≈30s）」和「1 次 10s」都拉开 2.8s+
      // 余量（fakeAsync 无法驱动真实 HttpClient 的 IO 超时，只能真等）。
      // 上界 28s（评审 #9）：真 IO 超时在慢机/CI 高负载下有调度漂移，
      // 原 14s 上界距期望值仅 ~5s，慢机易假红；放宽到 28s 仍与 30s
      // （误走全局 10s × 3）保持区分，timeout 相应放到 40s 留收尾余量。
      expect(elapsed.inMilliseconds, greaterThanOrEqualTo(7000),
          reason: '3 次尝试各等满 3s 读超时，墙钟应 ≈9s；明显偏小说明'
              '超时未触发或重试次数不足');
      expect(elapsed.inMilliseconds, lessThan(28000),
          reason: '上界 28s：防慢机/CI 调度漂移假红，同时排除误走全局 '
              '10s 档（3 次 ≈30s）');

      // 快请求：同一端点带 3s 覆盖选项时正常成功。
      final ok = await harness.dio.get<Object?>('/map/pins',
          options: mapPinsOptions());
      expect(ok.statusCode, 200);
      expect(ok.data, isNotNull);
    }, timeout: const Timeout(Duration(seconds: 40)));
  });

  group('KTD8 release-https 快速失败注入缝（两态各一测）', () {
    test('release==true 且 baseUrl 非 https → 构造即抛 StateError', () {
      expect(
        () => NetworkConfig(baseUrl: 'http://api.example.com/api/v1', isRelease: true),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('https'),
        )),
        reason: 'release 包明文 HTTP 必须启动快速失败（编码规范 §3.3：对外 TLS ≥1.2）',
      );
    });

    test('release==false 时 http mock 地址放行（本 harness 即此态）', () {
      final config =
          NetworkConfig(baseUrl: 'http://127.0.0.1:1/api/v1', isRelease: false);
      expect(config.baseUrl, 'http://127.0.0.1:1/api/v1');
      expect(config.isRelease, isFalse);
    });

    test('release==true 且 https baseUrl → 放行', () {
      final config = NetworkConfig(
          baseUrl: 'https://api.example.com/api/v1', isRelease: true);
      expect(config.baseUrl, startsWith('https://'));
    });

    test('生产默认配置经 fromEnvironment 读 S2S_API_BASE_URL（注入缝存在性）', () {
      // 单测环境未传 --dart-define：默认空串；真实 baseUrl 由出包注入，
      // 此处只断言默认配置对象可构造且 release 判定为独立入参（KTD8 分离）。
      const config = NetworkConfig.production();
      expect(config, isA<NetworkConfig>());
    });
  });

  group('KTD2 validateStatus：HTTP 状态不交给 dio 抛', () {
    test('429 响应进入 onResponse（由 EnvelopeInterceptor 分流）而非 dio 直接抛', () async {
      harness.stubRateLimited('GET', '/api/v1/posts/7/contact');

      try {
        await harness.dio.get<Object?>('/posts/7/contact');
        fail('429 业务信封应由 EnvelopeInterceptor reject');
      } on Object catch (error) {
        final dioError = error as DioException;
        // 若是 connectionTimeout/badResponse 之外的类型说明 validateStatus 未生效。
        expect(dioError.type, isNot(DioExceptionType.badResponse),
            reason: 'validateStatus: (_) => true 时 dio 不会因 HTTP 状态抛 badResponse');
        expect(harness.apiErrorOf(error).code.code, 42902);
      }
    });
  });
}
