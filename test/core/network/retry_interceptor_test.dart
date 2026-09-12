/// RetryInterceptor 全链路唯一重试测试（详细设计 §14 / §11.1 链序第 5 位 /
/// §12.2，编码规范 §5.5 / §1.3，计划 U6：R6/R9/R11/R14、KTD4/KTD10）。
///
/// 逐条落地计划 U6 的 Test scenarios（7 条）+ 任务书追加的 2 条证明用例：
///   场景 1  前两次 50001 第三次成功：业务请求恰 3 次、成功 data 正确、
///         两键三次逐字相同（POST 用例）；uuid 工厂全程仅 1 次
///         （仅幂等键首次兜底生成，交互 ID 显式透传）；GET 显式透传
///         交互 ID 用例 uuid 0 次且三次逐字相同；
///   场景 2  持续 50001：恰 3 请求后以 ApiException(networkFailure) 落
///         调用方（计划 Test scenarios 第 2 条明文），无第 4 次请求；
///   场景 2b 纯传输层失败（连接拒绝）：经 KTD10 唯一归一点包装为
///         networkFailure 后重试，耗尽形态与计数同上，mock 服务 0 收包；
///   场景 3  Retry-After: 2 优先于退避表：sleeper 收到 [2s, 2s] 整数秒、
///         不抖动（详设 §14.1 仅规定「优先」，整数秒语义不施加抖动）；
///   场景 4  42901/42902/42907 各一例：1 请求、0 sleep、异常原样落
///         调用方（码与 retryAfterSec 保持）；
///   场景 5  40903：1 请求、不重试、请求体逐字不变、无 version 注入；
///   场景 6  cancel：首发前取消 → 裸 cancel、0 请求、0 sleep；退避期间
///         取消 → 已开始的等待后不再发起重放，裸 cancel 落调用方；
///   场景 7  jitter ±20% 边界：randomRatio=0.0 → 0.8s/1.6s 下界；
///         趋近 1 → <1.2s/<2.4s 上界（期望值以 NfrNetwork 常量计算，
///         不复制 1/2/20 字面量）；
///   场景 8  嵌套终止证明：持续失败 3 请求 + 调用方恰好一次终局错误 +
///         终局错误 extra 计数 == retryMaxCount + 无 unhandled exception；
///   场景 9  与 AuthRefresh 同链共存：40101→refresh 成功→重放成功时
///         RetryInterceptor 零介入（业务 2/refresh 1/0 sleep）；refresh
///         瞬时失败（50001）时重试的是**原业务请求**（每轮再吃 40101
///         后单飞字段已复位会再续期），固化实际连锁行为。
///
/// 全部走 MockApiServer 真实 HTTP 栈（R9：不用假 dio httpAdapter），
/// 等待经注入 sleeper 记录（测试禁止真睡 1–2 秒，flaky 零容忍）。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

// test_support barrel 导出 ApiEnvelope/MockResponse/MockRequest/repoFile；
// harness 单独 import（barrel 不含它）。
import '../../support/network_chain_harness.dart';
import '../../support/test_support.dart';

/// mock 服务统一前缀（桩按含前缀的 `uri.path` 登记）。
const String _apiPrefix = '/api/v1';

/// 读接口逻辑路径（GET 不注入幂等键，隔离交互 ID 保全断言）。
const String _readPath = '/retry-echo';

/// 写接口逻辑路径（POST 注入幂等键，覆盖两键保全）。
const String _writePath = '/retry-write';

/// 显式透传的交互 ID（满足 UUID v4 形态，仅测试假值）。
const String _interactionId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

/// 计算注入 [ratio] 时第 [attemptOrdinal] 次重试（1/2）的期望抖动退避。
///
/// 期望值必须用 [NfrNetwork] 常量推导（编码规范 §3.1：测试也不复制
/// 1s/2s/20% 字面量），公式与生产实现同源：
/// `base * (1 + (ratio*2-1) * jitterPercent/100)`，毫秒向下取整。
///
/// 参数：
///   [attemptOrdinal] 重试序号（1 = backoffFirst，2 = backoffSecond）；
///   [ratio]          注入的抖动随机比例（[0,1)）。
/// 返回：[Duration] 期望等待时长（毫秒精度）。
Duration expectedJitteredBackoff(int attemptOrdinal, double ratio) {
  final baseSec = attemptOrdinal == 1
      ? NfrNetwork.backoffFirstSec
      : NfrNetwork.backoffSecondSec;
  final factor =
      1 + (ratio * 2 - 1) * NfrNetwork.retryJitterPercent / 100;
  return Duration(milliseconds: (baseSec * 1000 * factor).floor());
}

void main() {
  late NetworkChainHarness harness;

  /// 装配一套带「记录型 sleeper + 固定抖动」的 harness（禁止真睡）。
  ///
  /// 参数：
  ///   [sleeps]      外部持有的等待记录（同一 harness 重建时保持引用）；
  ///   [randomRatio] 固定抖动比例（默认 0.0 = 下界，退避时长确定可断言）。
  /// 返回：配置好的 harness（调用方仍负责 start/setUp 语义）。
  NetworkChainHarness harnessWithRecordedSleep({
    required List<Duration> sleeps,
    double randomRatio = 0.0,
  }) {
    return NetworkChainHarness(
      retrySleeper: (duration) async {
        sleeps.add(duration);
      },
      retryRandomRatio: () => randomRatio,
    );
  }

  /// 当前测试持有的 sleeper 等待记录（setUp 中随 harness 一并创建）。
  late List<Duration> recordedSleeps;

  /// 取 mock 收到的全部读接口请求（按到达顺序）。
  List<MockRequest> readRequests() => harness.server.received
      .where((request) => request.path.startsWith('$_apiPrefix$_readPath'))
      .toList();

  /// 取 mock 收到的全部写接口请求（按到达顺序）。
  List<MockRequest> writeRequests() => harness.server.received
      .where((request) => request.path.startsWith('$_apiPrefix$_writePath'))
      .toList();

  /// 发起一次显式透传交互 ID 的 GET。
  ///
  /// 参数：
  ///   [dio]         发起请求用的 dio（默认 harness.dio）；
  ///   [interaction] X-Interaction-Id 透传值；
  ///   [cancelToken] 可选取消令牌。
  /// 返回：[Future<Object?>] 拆信封后的 data。
  Future<Object?> getEcho({
    Dio? dio,
    String interaction = _interactionId,
    CancelToken? cancelToken,
  }) async {
    final response = await (dio ?? harness.dio).get<Object?>(
      _readPath,
      options: Options(
        headers: {HeaderInterceptor.interactionIdHeader: interaction},
      ),
      cancelToken: cancelToken,
    );
    return response.data;
  }

  /// 发起一次 POST（交互 ID 显式透传，幂等键默认交给拦截器首次兜底生成）。
  ///
  /// 参数：
  ///   [dio]            发起请求用的 dio；
  ///   [body]           请求体（40903 用例逐字断言用）；
  ///   [interaction]    X-Interaction-Id 透传值；
  ///   [idempotencyKey] 显式幂等键，null 时不传该头（拦截器首次兜底）；
  ///   [cancelToken]    可选取消令牌。
  /// 返回：[Future<Object?>] 拆信封后的 data。
  Future<Object?> postWrite({
    Dio? dio,
    Map<String, Object?> body = const {'biz': 'ping'},
    String interaction = _interactionId,
    String? idempotencyKey,
    CancelToken? cancelToken,
  }) async {
    // 可空头在 map 构造后条件写入（避免 collection-if + 非空检查触发
    // use_null_aware_elements；同时语义不变：null = 不传该头）。
    final headers = <String, String>{
      HeaderInterceptor.interactionIdHeader: interaction,
    };
    if (idempotencyKey != null) {
      headers[HeaderInterceptor.idempotencyKeyHeader] = idempotencyKey;
    }
    final response = await (dio ?? harness.dio).post<Object?>(
      _writePath,
      data: body,
      options: Options(headers: headers),
      cancelToken: cancelToken,
    );
    return response.data;
  }

  /// 登记读接口桩：前 [failTimes] 次返信封 50001，其后成功。
  ///
  /// 参数：
  ///   [failTimes]   连续失败次数；默认恰为「首发 + 全链路重试」总数，
  ///                 即耗尽场景每次尝试都失败（无成功尾包）；
  ///   [retryAfter] 非 null 时失败响应附带 Retry-After 整数秒头。
  /// 返回：void。
  void stubReadFlaky({
    int? failTimes,
    String? retryAfter,
  }) {
    // 默认失败次数 = 首发 + retryMaxCount 次重试：持续失败/退避断言场景
    // 必须每次尝试都拿到 50001（不能让第 3 次命中成功尾包）；场景 1 的
    // 「前两次失败第三次成功」在其用例内显式传 retryMaxCount。
    final effectiveFailTimes =
        failTimes ?? NfrNetwork.retryMaxCount + 1;

    var hits = 0;
    harness.stub('GET', '$_apiPrefix$_readPath', (request) async {
      hits += 1;
      if (hits <= effectiveFailTimes) {
        return MockResponse(
          status: 500,
          headers: retryAfter == null ? const {} : {'Retry-After': retryAfter},
          body: ApiEnvelope.failure(
            ApiErrorCode.internalError.code,
            '服务繁忙，请稍后重试',
            requestId: 'req_500_$hits',
          ),
        );
      }
      return MockResponse(
        body: ApiEnvelope.success(
          data: {'ok': true, 'hit': hits},
          requestId: 'req_ok_$hits',
        ),
      );
    });
  }

  /// 登记读接口恒定失败桩（信封 [code]，可带 Retry-After）。
  ///
  /// 参数：
  ///   [code]       业务失败码；
  ///   [retryAfter] Retry-After 整数秒字符串，null 不带头。
  /// 返回：void。
  void stubReadAlwaysFailure(int code, {String? retryAfter}) {
    harness.stub('GET', '$_apiPrefix$_readPath', (request) async {
      return MockResponse(
        status: code ~/ 100,
        headers: retryAfter == null ? const {} : {'Retry-After': retryAfter},
        body: ApiEnvelope.failure(
          code,
          '测试失败 fixture code=$code',
          requestId: 'req_fail_$code',
        ),
      );
    });
  }

  /// 运行必有异常的动作并返回 catch 到的原始对象（保留 DioException 外壳）。
  ///
  /// 参数：[action] 预期失败的请求闭包。
  /// 返回：[Object] catch 到的异常对象（调用方自行判型）。
  Future<Object> captureRawError(Future<Object?> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      return error;
    }
    fail('预期请求失败，但实际成功');
  }

  /// 从原始异常拆包 [ApiException]（先剥 DioException 外壳）。
  ///
  /// 参数：[raw] captureRawError 的返回值。
  /// 返回：[ApiException] 业务异常；形态不符抛 [TestFailure]。
  ApiException asApiError(Object raw) => harness.apiErrorOf(raw);

  setUp(() async {
    recordedSleeps = <Duration>[];
    harness = harnessWithRecordedSleep(sleeps: recordedSleeps);
    await harness.start();
  });

  tearDown(() => harness.dispose());

  group('场景 1：可重试失败后成功（R6/R9，详设 §14.1 总共 2 次）', () {
    test('POST 前两次 50001 第三次成功：恰 3 请求、data 正确、'
        '两键三次逐字相同、uuid 工厂全程仅 1 次（仅幂等键首次兜底）', () async {
      var hits = 0;
      harness.stub('POST', '$_apiPrefix$_writePath', (request) async {
        hits += 1;
        if (hits <= 2) {
          return MockResponse(
            status: 500,
            body: ApiEnvelope.failure(
              ApiErrorCode.internalError.code,
              '服务繁忙，请稍后重试',
              requestId: 'req_500_$hits',
            ),
          );
        }
        return MockResponse(
          body: ApiEnvelope.success(
            data: {'ok': true},
            requestId: 'req_ok_$hits',
          ),
        );
      });

      final data = await postWrite();

      expect(data, isA<Map>().having((map) => map['ok'], 'ok', true));
      final requests = writeRequests();
      expect(requests.length, 3, reason: '首发 + 全链路 2 次重试');
      final interactionHeaders = requests
          .map((request) => request.header('x-interaction-id'))
          .toSet();
      expect(interactionHeaders, {_interactionId},
          reason: 'X-Interaction-Id 三次必须逐字相同，重放不得换号');
      final idempotencyKeys = requests
          .map((request) => request.header('idempotency-key'))
          .toSet();
      expect(idempotencyKeys.length, 1, reason: 'Idempotency-Key 三次逐字相同');
      expect(
        idempotencyKeys.single,
        matches(TestFixtures.uuidV4Pattern),
        reason: '幂等键为 HeaderInterceptor 首次兜底生成的 UUID v4',
      );
      expect(harness.uuidCallCount, 1,
          reason: '交互 ID 显式透传不触发生成；仅幂等键首发兜底生成 1 次，'
              '重放走全链时 containsKey 判定为真不再生成（KTD4）');
      expect(recordedSleeps, [
        expectedJitteredBackoff(1, 0),
        expectedJitteredBackoff(2, 0),
      ]);
    });

    test('GET 显式透传交互 ID：uuid 0 次，三次交互 ID 逐字相同', () async {
      // 前 retryMaxCount 次失败、其后成功：第三次尝试命中成功尾包。
      stubReadFlaky(failTimes: NfrNetwork.retryMaxCount);

      final data = await getEcho();

      expect((data as Map?)?['ok'], isTrue);
      final requests = readRequests();
      expect(requests.length, 3);
      expect(
        requests.map((request) => request.header('x-interaction-id')).toSet(),
        {_interactionId},
      );
      expect(
        requests.every((request) => request.header('idempotency-key') == null),
        isTrue,
        reason: 'GET 不注入幂等键',
      );
      expect(harness.uuidCallCount, 0,
          reason: '三头均显式齐备/不适用时，重试链路不得生成任何 UUID');
    });
  });

  group('场景 2/8：持续失败耗尽与嵌套终止证明（KTD4/KTD10）', () {
    test('持续信封 50001：恰 3 请求后以 networkFailure 落调用方，'
        '无第 4 次请求，终局错误恰好一次且带重试计数', () async {
      stubReadFlaky();

      final raw = await captureRawError(getEcho);
      final apiError = asApiError(raw);
      expect(apiError.code, ApiErrorCode.networkFailure,
          reason: '计划 U6 场景 2 明文：持续 50001 耗尽后以 networkFailure '
              '结束（自动重试耗尽即降级为确定性网络失败提示，§12.2）');

      final requests = readRequests();
      expect(requests.length, 3, reason: '首发 + 2 次重试，不得有第 4 次请求');
      expect(recordedSleeps.length, NfrNetwork.retryMaxCount);

      // 嵌套终止证明（KTD4）：终局错误携带的 extra 计数必须恰好到顶——
      // dio.fetch 重走全链时内层 onError 凭「内层标记」直接把错误抛回外层
      // await，绝不二次 sleep/再 fetch；计数是唯一防递归手段。
      expect(raw, isA<DioException>());
      final terminalOptions = (raw as DioException).requestOptions;
      expect(
        terminalOptions.extra[RetryInterceptor.retryAttemptCountExtraKey],
        NfrNetwork.retryMaxCount,
        reason: '终局错误 extra 计数 == 2：每次重放 +1，到顶后由外层归一拒绝',
      );
      expect(
        terminalOptions.extra
            .containsKey(RetryInterceptor.retryInnerDispatchExtraKey),
        isFalse,
        reason: '落调用方的是外层请求形态，内层调度标记不得外泄',
      );

      // 让出事件轮：若嵌套 fetch 的错误链有未捕获异常，flutter test 会
      // 在此期间以 unhandled exception 直接判失败（纪律红线：零 unhandled）。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(readRequests().length, 3, reason: '终止后不得再有迟到的第 4 请求');
    });

    test('纯传输层连接拒绝：KTD10 唯一归一点包装为 networkFailure 后重试，'
        '耗尽形态同上，mock 服务 0 收包', () async {
      // 绑定一个端口后立即关闭，得到确定无监听的端口（连接拒绝立即返回）。
      final probeSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final closedPort = probeSocket.port;
      await probeSocket.close();
      final closedDio = buildNetworkDio(
        config: NetworkConfig(
          baseUrl: 'http://127.0.0.1:$closedPort$_apiPrefix',
          isRelease: false,
        ),
        hooks: harness.hooksForProbe(),
        retrySleeper: (duration) async {},
        retryRandomRatio: () => 0,
      );
      addTearDown(() => closedDio.close(force: true));

      final raw = await captureRawError(
        () => getEcho(dio: closedDio, interaction: 'transport-retry-itx'),
      );

      expect(asApiError(raw).code, ApiErrorCode.networkFailure,
          reason: '连接拒绝等纯传输错误在链尾唯一归一点包装为 networkFailure');
      expect(
        (raw as DioException).requestOptions
            .extra[RetryInterceptor.retryAttemptCountExtraKey],
        NfrNetwork.retryMaxCount,
      );
      expect(harness.server.received, isEmpty,
          reason: '全部尝试都打向已关闭端口，mock 服务不应收到任何请求');
    });
  });

  group('场景 3：Retry-After 整数秒优先于退避表（R11，详设 §14.1）', () {
    test('失败响应带 Retry-After: 2：两次等待均为 2s 整数秒、不抖动',
        () async {
      stubReadFlaky(retryAfter: '2');

      final raw = await captureRawError(getEcho);
      expect(asApiError(raw).code, ApiErrorCode.networkFailure);
      expect(readRequests().length, 3);
      expect(
        recordedSleeps,
        <Duration>[
          const Duration(seconds: 2),
          const Duration(seconds: 2),
        ],
        reason: 'Retry-After 优先于退避表；整数秒是服务端指令语义，'
            '不叠加客户端抖动（抖动只服务于退避表的削峰目的）',
      );
      expect(recordedSleeps.every((d) => d.inMilliseconds % 1000 == 0),
          isTrue);
    });
  });

  group('场景 4：429 段不自动重试（R14，promptWithRetryAfter 用户显式操作）',
      () {
    /// 参数化用例：[code] 的限流响应必须原样落调用方。
    ///
    /// 参数：
    ///   [code]        42901/42902/42907；
    ///   [retryAfter]  服务端 Retry-After 秒数；
    ///   [description] 用例描述。
    void assertRateLimitNotRetried(
      int code,
      int retryAfter,
      String description,
    ) {
      test('$description（code=$code）：1 请求、0 sleep、码与秒数原样保持',
          () async {
        stubReadAlwaysFailure(code, retryAfter: '$retryAfter');

        final raw = await captureRawError(getEcho);
        final apiError = asApiError(raw);
        expect(apiError.code, ApiErrorCode.fromCode(code));
        expect(apiError.retryAfterSec, retryAfter,
            reason: 'Retry-After 必须原样透传给用户提示分支');
        expect(readRequests().length, 1, reason: '限流码禁止自动重试');
        expect(recordedSleeps, isEmpty, reason: '不得退避等待');
      });
    }

    assertRateLimitNotRetried(42901, 60, 'AI 配额超限');
    assertRateLimitNotRetried(42902, 30, '查看联系方式限频');
    assertRateLimitNotRetried(42907, 120, '游客详情浏览限频');
  });

  group('场景 5：40903 乐观锁冲突不重试、不注入 version（R14 forceRefetch）',
      () {
    test('40903：1 请求、0 sleep、异常原样（requestId 保持）、'
        '请求体逐字不变且无 version 字段', () async {
      const requestBody = <String, Object?>{'post_id': 'post-u6-1', 'note': 'x'};
      harness.stub('POST', '$_apiPrefix$_writePath', (request) async {
        return MockResponse(
          status: 409,
          body: ApiEnvelope.failure(
            ApiErrorCode.versionConflict.code,
            '数据已更新，请刷新后重试',
            requestId: 'req_40903_u6',
          ),
        );
      });

      final raw = await captureRawError(
        () => postWrite(body: requestBody),
      );
      final apiError = asApiError(raw);
      expect(apiError.code, ApiErrorCode.versionConflict);
      expect(apiError.requestId, 'req_40903_u6',
          reason: '不重试：落调用方的就是首发响应的异常');
      final requests = writeRequests();
      expect(requests.length, 1, reason: 'forceRefetch 禁止自动重试');
      expect(recordedSleeps, isEmpty);
      expect(requests.single.body, requestBody,
          reason: '本拦截器根本不碰 data，请求体逐字不变');
      expect(
        (requests.single.body as Map?)?.containsKey('version'),
        isFalse,
        reason: '严禁自动带新 version 重发（§12.2：必须用户决定）',
      );
    });
  });

  group('场景 6：cancel 裸放过（KTD10，不计数不重试）', () {
    test('首发前 CancelToken 已取消：裸 cancel 落调用方、0 请求、0 sleep',
        () async {
      stubReadFlaky();
      final cancelToken = CancelToken()..cancel();

      final raw = await captureRawError(
        () => postWrite(idempotencyKey: TestFixtures.idempotencyKey,
            cancelToken: cancelToken),
      );

      expect(raw, isA<DioException>());
      expect((raw as DioException).type, DioExceptionType.cancel,
          reason: 'cancel 是显式例外，不穿 ApiException 外衣');
      expect(raw.error, isNot(isA<ApiException>()),
          reason: 'cancel 不得被归一为 networkFailure');
      expect(harness.server.received, isEmpty, reason: '取消在出网前生效');
      expect(recordedSleeps, isEmpty);
    });

    test('首次退避期间取消：已开始的等待后不发起重放，裸 cancel 落调用方',
        () async {
      final cancelToken = CancelToken();
      // 独立 harness：sleeper 在首次被调用时记录并立即取消令牌（等待本身
      // 瞬时完成，测试不真睡）；重放 fetch 携带同一已取消令牌，必须在出网
      // 前终止。
      final cancelSleeps = <Duration>[];
      await harness.dispose();
      harness = NetworkChainHarness(
        retrySleeper: (duration) async {
          cancelSleeps.add(duration);
          cancelToken.cancel();
        },
        retryRandomRatio: () => 0,
      );
      await harness.start();
      stubReadFlaky();

      final raw = await captureRawError(
        () => getEcho(cancelToken: cancelToken),
      );

      expect(raw, isA<DioException>());
      expect((raw as DioException).type, DioExceptionType.cancel);
      expect(readRequests().length, 1, reason: '仅首发；取消后无重放出网');
      expect(cancelSleeps.length, 1, reason: '第一次退避已开始即被取消');
    });
  });

  group('场景 7：退避抖动 ±20% 边界（R6，详设 §14.1）', () {
    test('randomRatio 下界 0.0：两次等待恰为退避基数的 -20%（0.8s/1.6s）',
        () async {
      stubReadFlaky();

      await captureRawError(getEcho);

      expect(readRequests().length, 3);
      expect(
        recordedSleeps,
        [
          expectedJitteredBackoff(1, 0),
          expectedJitteredBackoff(2, 0),
        ],
      );
      expect(recordedSleeps[0], const Duration(milliseconds: 800),
          reason: '1s 的 -20% 下界');
      expect(recordedSleeps[1], const Duration(milliseconds: 1600),
          reason: '2s 的 -20% 下界');
    });

    test('randomRatio 趋近 1：两次等待落在 +20% 开区间上界（<1.2s/<2.4s）',
        () async {
      // 独立 harness：固定上界抖动比例。sleeper 闭包写入同一等待记录。
      await harness.dispose();
      harness = harnessWithRecordedSleep(
        sleeps: recordedSleeps,
        randomRatio: 0.999999,
      );
      await harness.start();
      stubReadFlaky();

      await captureRawError(getEcho);

      expect(readRequests().length, 3);
      expect(
        recordedSleeps,
        [
          expectedJitteredBackoff(1, 0.999999),
          expectedJitteredBackoff(2, 0.999999),
        ],
        reason: '抖动比例趋近 1 时取 +20% 方向的毫秒向下取整值',
      );
      final firstUpperExclusive = Duration(
        milliseconds:
            NfrNetwork.backoffFirstSec * 1000 *
                (100 + NfrNetwork.retryJitterPercent) ~/
            100,
      );
      final secondUpperExclusive = Duration(
        milliseconds:
            NfrNetwork.backoffSecondSec * 1000 *
                (100 + NfrNetwork.retryJitterPercent) ~/
            100,
      );
      expect(recordedSleeps[0] < firstUpperExclusive, isTrue,
          reason: '首次等待严格小于 +20% 上界（开区间）');
      expect(recordedSleeps[0] >= firstUpperExclusive - const Duration(milliseconds: 1),
          isTrue, reason: '距上界不超过 1ms（随机比例 0.999999）');
      expect(recordedSleeps[1] < secondUpperExclusive, isTrue,
          reason: '第二次等待严格小于 +20% 上界（开区间）');
      expect(recordedSleeps[1] >= secondUpperExclusive - const Duration(milliseconds: 1),
          isTrue, reason: '距上界不超过 1ms');
    });
  });

  group('场景 9：与 AuthRefresh 同链共存（生产同款五拦截器链，R9）', () {
    test('业务 40101 → refresh 成功 → 重放成功：RetryInterceptor 零介入',
        () async {
      harness.token = 'jwt-old-fake';
      harness.sessionEpoch = 1;
      harness.stubRefreshSuccess();
      harness.stub('GET', '$_apiPrefix$_readPath', (request) async {
        if (request.header('authorization') == 'Bearer jwt-old-fake') {
          return MockResponse(
            status: 401,
            body: ApiEnvelope.failure(
              ApiErrorCode.unauthorized.code,
              '登录已失效，请重新登录',
              requestId: 'req_401_once',
            ),
          );
        }
        return MockResponse(
          body: ApiEnvelope.success(
            data: {'ok': true},
            requestId: 'req_ok_after_refresh',
          ),
        );
      });

      final data = await getEcho();

      expect((data as Map?)?['ok'], isTrue);
      expect(readRequests().length, 2, reason: '首发 + AuthRefresh 重放各 1 次');
      final refreshCount = harness.server.received
          .where((request) =>
              request.method == 'POST' &&
              request.path.startsWith('$_apiPrefix/auth/token/refresh'))
          .length;
      expect(refreshCount, 1, reason: '40101 单飞续期 1 次');
      expect(recordedSleeps, isEmpty,
          reason: '成功路径不触发 RetryInterceptor 退避');
    });

    test('refresh 自身瞬时失败（信封 50001）：重试的是原业务请求，'
        '每轮再吃 40101 且单飞字段复位后重新续期（实际连锁行为固化）',
        () async {
      harness.token = 'jwt-old-fake';
      harness.sessionEpoch = 1;
      // refresh 恒定 50001：U5 将其归一为 networkFailure（不清会话），
      // 到达链尾命中 autoRetry。
      harness.stubRefreshFailure(ApiErrorCode.internalError.code);
      harness.stub('GET', '$_apiPrefix$_readPath', (request) async {
        return MockResponse(
          status: 401,
          body: ApiEnvelope.failure(
            ApiErrorCode.unauthorized.code,
            '登录已失效，请重新登录',
            requestId: 'req_401_each',
          ),
        );
      });

      final raw = await captureRawError(getEcho);

      // 连锁推演（重试预算全花在原业务请求上）：
      //   业务 #1 → 40101 → refresh #1 → 50001 归一 networkFailure
      //   → Retry 退避 1 → dio.fetch 重放业务 #2 → 再 40101
      //   → U5 单飞字段已复位 → refresh #2 → networkFailure
      //   → Retry 退避 2 → 重放业务 #3 → 再 40101 → refresh #3
      //   → networkFailure → 计数到顶 → 终局 networkFailure。
      expect(asApiError(raw).code, ApiErrorCode.networkFailure);
      expect(readRequests().length, 3,
          reason: '全链路 3 个业务请求（首发 + 2 重试），未超 §14.1 预算');
      final refreshCount = harness.server.received
          .where((request) =>
              request.method == 'POST' &&
              request.path.startsWith('$_apiPrefix/auth/token/refresh'))
          .length;
      expect(refreshCount, 3,
          reason: '每轮业务重试再吃 40101，U5 单飞字段结论落定即复位，'
              '故每个重放各触发一次续期；refresh 自身不经 Retry（KTD3）');
      expect(harness.clearSessionCallCount, 0, reason: '瞬时失败不清会话');
      expect(harness.writeTokenCallCount, 0);
      expect(recordedSleeps, [
        expectedJitteredBackoff(1, 0),
        expectedJitteredBackoff(2, 0),
      ]);
    });
  });

  group('R16 白名单：重试链路不输出任何敏感信息', () {
    test('retry_interceptor.dart 无 print/log，诊断 message 仅允许 err.type',
        () {
      final sourceFile = repoFile(
        'lib/core/network/interceptors/retry_interceptor.dart',
      );
      expect(sourceFile.existsSync(), isTrue,
          reason: '空扫描面是 FAIL 不是 SKIP（部署 §14.5）');
      final source = sourceFile.readAsStringSync();
      expect(RegExp(r'(^|\s)print\s*\(').hasMatch(source), isFalse);
      expect(RegExp(r'\bdebugPrint\s*\(').hasMatch(source), isFalse);
      expect(source.contains('LogInterceptor'), isFalse);
      expect(source.contains('developer.log'), isFalse);
      // R16：重试链路禁止读取/拼接请求头与请求体（token/body 不得入日志、
      // 不得入诊断 message）；本拦截器只允许触碰 path/extra/error 形态。
      expect(source.contains('.headers'), isFalse,
          reason: '重试实现不得读取请求头（防 token 泄露）');
      expect(RegExp(r'\.data\b').hasMatch(source), isFalse,
          reason: '重试实现不得触碰请求体/响应体');
    });
  });
}
