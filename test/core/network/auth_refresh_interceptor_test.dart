/// AuthRefreshInterceptor 40101 单飞续期测试（详细设计 §13 / §11.1 链序
/// 第 4 位 / §12.2 / §13.3，编码规范 §5.4，计划 U5：R9/R10/R16、KTD3/KTD4）。
///
/// 逐条落地计划 U5 的 Test scenarios（12 条）：
///   场景 1  5 并发 40101：refresh 实际调用 == 1，5 请求全部重放成功；
///         附：续期请求形态（Authorization 携旧 Token、无请求体，契约
///         `/auth/token/refresh` 单 Token 模型）；
///   场景 2  重放 X-Interaction-Id / Idempotency-Key 逐字沿用首发值；
///   场景 3  重放仅 Authorization 变化（新 Bearer），其余头逐字不变；
///   场景 4  重放仍 40101：不再二次 refresh，最终以重放响应的 40101 失败；
///   场景 5  refresh 自身 40101 / 403xx：leader 清会话 1 次、writeToken 0，
///         挂起请求保留各自原始 40101、不重放（R10 分流①）；
///   场景 6  refresh 收 42901（带 Retry-After）：不清会话，挂起请求以带
///         retryAfterSec 的异常失败（R10 分流②）；
///   场景 7  refresh 网络失败/5xx：信封 50001、网关 HTML 502、连接拒绝
///         三个入口均不清会话，以 networkFailure 结束（R10 分流③）；
///   场景 8  readToken 为 null（未登录）收 40101：不发 refresh、原样透传；
///   场景 9  取消语义：挂起期间单个 follower 被取消（共享续期不中断、
///         其余正常重放）；cancel 错误裸穿透不触发续期；
///   场景 10 续期在途代次变更（登出/换号）：结果丢弃、writeToken 0、
///         不重放、队列以各自原始 40101 结束；
///   场景 11 writeToken 受控 Future：写回完成前挂起队列绝不抢跑重放；
///   另含 KTD3 独立 refresh dio 装配形态断言与 R16 源码白名单扫描。
///
/// 全部走 MockApiServer 真实 HTTP 栈（R9：不用假 dio httpAdapter），
/// 两键/Authorization 保全断言落在 mock 服务实际收到的请求记录上。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
// api_client 已 re-export 三个拦截器（AuthRefresh/Envelope/Header），
// 直接引用其静态常量与类型，不重复 import。
import '../../support/network_chain_harness.dart';
// test_support barrel 已导出 repo_paths（repoFile）与 api_envelope/mock server。
import '../../support/test_support.dart';

/// mock 服务统一前缀（桩按含前缀的 `uri.path` 登记）。
const String _apiPrefix = '/api/v1';

/// 业务侧写接口逻辑路径（dio 请求用，baseUrl 已含前缀）。
const String _businessPath = '/biz/refresh-echo';

/// 续期端点在 mock 服务上的完整路径（含前缀）。
const String _refreshFullPath = '$_apiPrefix/auth/token/refresh';

/// 旧 Token 假值（测试唯一允许的字面量类别：明显假凭据）。
const String _oldToken = 'jwt-old-fake-token';

/// 新 Token 假值（与 [NetworkChainHarness.stubRefreshSuccess] 默认值对齐）。
const String _newToken = 'jwt-refreshed-fake';

/// 为并发序号生成互不相同、满足 UUID v4 形态的幂等键。
///
/// 参数：[index] 请求序号（0 起）。
/// 返回：[String] 版本位 4、变体位 8 的确定性 UUID v4。
String _idempotencyKeyFor(int index) {
  return '00000000-0000-4000-8000-${index.toString().padLeft(12, '0')}';
}

/// 读取生产源码并剥离字符串字面量与全部注释，供 R16 白名单扫描。
///
/// 为什么扫描前必须剥离：本测试的注释本身会引用 `LogInterceptor`、
/// `print` 等判据字面量（解释「为什么禁止」），不剥离会把注释自指误判为
/// 命中；字符串字面量同理（如异常文案里的诊断串）。保留代码结构所需的
/// 占位，保证 `print(` 这类「标识符紧跟左括号」的调用形态仍可识别。
///
/// 参数：[relativePath] 相对仓库根的生产源码路径（`/` 分隔）。
/// 返回：[String] 已将字符串/注释内容替换为空白（保留换行与长度形态）
///   的纯代码文本；文件缺失时抛 [StateError]（先断言存在，空扫描面
///   不得报通过）。
String productionCodeOf(String relativePath) {
  final sourceFile = repoFile(relativePath);
  if (!sourceFile.existsSync()) {
    throw StateError('R16 扫描对象缺失（空扫描面不得判通过）：$relativePath');
  }
  final source = sourceFile.readAsStringSync();
  final buffer = StringBuffer();
  var index = 0;
  var inLineComment = false;
  var inBlockComment = false;
  String? stringQuote;
  while (index < source.length) {
    final char = source[index];
    final next = index + 1 < source.length ? source[index + 1] : '';
    if (inLineComment) {
      if (char == '\n') {
        inLineComment = false;
        buffer.write(char);
      } else {
        buffer.write(' ');
      }
      index += 1;
      continue;
    }
    if (inBlockComment) {
      if (char == '*' && next == '/') {
        inBlockComment = false;
        buffer.write('  ');
        index += 2;
      } else {
        buffer.write(char == '\n' ? '\n' : ' ');
        index += 1;
      }
      continue;
    }
    if (stringQuote != null) {
      if (char == r'\' && index + 1 < source.length) {
        buffer.write('  ');
        index += 2;
        continue;
      }
      if (char == stringQuote) stringQuote = null;
      buffer.write(char == '\n' ? '\n' : ' ');
      index += 1;
      continue;
    }
    if ((char == '/' && next == '/') || (char == '/' && next == '*')) {
      if (next == '/') {
        inLineComment = true;
        index += 2;
      } else {
        inBlockComment = true;
        index += 2;
      }
      buffer.write('  ');
      continue;
    }
    if (char == "'" || char == '"') {
      stringQuote = char;
      buffer.write(' ');
      index += 1;
      continue;
    }
    buffer.write(char);
    index += 1;
  }
  return buffer.toString();
}

void main() {
  late NetworkChainHarness harness;

  /// 统计 mock 实际收到的续期请求数（单飞计数断言的唯一口径）。
  ///
  /// 返回：[int] `POST /api/v1/auth/token/refresh` 命中次数。
  int refreshCallCount() => harness.server.received
      .where(
        (request) =>
            request.method == 'POST' &&
            request.path.startsWith('$_apiPrefix/auth/token/refresh'),
      )
      .length;

  /// 取 mock 收到的全部业务写接口请求（含首发与重放，按到达顺序）。
  ///
  /// 返回：[List<MockRequest>] 业务请求记录。
  List<MockRequest> businessRequests() => harness.server.received
      .where((request) => request.path.startsWith('$_apiPrefix$_businessPath'))
      .toList();

  /// 登记业务桩：每个幂等键**首发**回 40101（requestId 按键区分，便于
  /// 断言挂起请求保留的是「各自原始」异常），第 2 次（重放）回成功。
  ///
  /// 返回：void。
  void stubBusinessFirst401ThenSuccess() {
    final hitCountPerIdempotencyKey = <String, int>{};
    harness.stub('POST', '$_apiPrefix$_businessPath', (request) async {
      final idempotencyKey =
          request.header(HeaderInterceptor.idempotencyKeyHeader.toLowerCase()) ??
          '';
      final hits = (hitCountPerIdempotencyKey[idempotencyKey] ?? 0) + 1;
      hitCountPerIdempotencyKey[idempotencyKey] = hits;
      if (hits == 1) {
        return MockResponse(
          status: 401,
          body: ApiEnvelope.failure(
            ApiErrorCode.unauthorized.code,
            '登录已失效，请重新登录',
            requestId: 'req_401_$idempotencyKey',
          ),
        );
      }
      return MockResponse(
        body: ApiEnvelope.success(
          data: const {'ok': true},
          requestId: 'req_ok_$idempotencyKey',
        ),
      );
    });
  }

  /// 登记业务桩：恒定回 40101（失败分流/未登录等不应发生重放的场景用）。
  ///
  /// 返回：void；requestId 按幂等键区分以识别异常归属。
  void stubBusinessAlwaysUnauthorized() {
    harness.stub('POST', '$_apiPrefix$_businessPath', (request) async {
      final idempotencyKey =
          request.header(HeaderInterceptor.idempotencyKeyHeader.toLowerCase()) ??
          '';
      return MockResponse(
        status: 401,
        body: ApiEnvelope.failure(
          ApiErrorCode.unauthorized.code,
          '登录已失效，请重新登录',
          requestId: 'req_401_$idempotencyKey',
        ),
      );
    });
  }

  /// 发起一次业务写请求，显式透传交互 ID 与幂等键（测两键逐字保全的前提）。
  ///
  /// 参数：
  ///   [dio]          发起请求用的 dio（默认生产同款 harness.dio）；
  ///   [interactionId] 透传 X-Interaction-Id；
  ///   [idempotencyKey] 透传 Idempotency-Key；
  ///   [cancelToken]   可选取消令牌（取消语义场景用）。
  /// 返回：[Future<Object?>] 拆信封后的 data。
  Future<Object?> postBusiness(
    String interactionId,
    String idempotencyKey, {
    Dio? dio,
    CancelToken? cancelToken,
  }) async {
    // 返回拆信封后的 data（成功路径用例按业务负载断言）；失败仍以
    // DioException(ApiException) 抛出，由 captureApiError 拆包。
    final response = await (dio ?? harness.dio).post<Object?>(
      _businessPath,
      data: const {'biz': 'ping'},
      options: Options(
        headers: {
          HeaderInterceptor.interactionIdHeader: interactionId,
          HeaderInterceptor.idempotencyKeyHeader: idempotencyKey,
        },
      ),
      cancelToken: cancelToken,
    );
    return response.data;
  }

  /// 运行一个必有 40101/分流异常落调用方的动作并拆包为 [ApiException]。
  ///
  /// 参数：[action] 预期失败的请求闭包。
  /// 返回：[Future<ApiException>] 拆包后的业务异常。
  /// 抛出：[TestFailure] 动作未失败或异常形态不符（KTD2 包装）。
  Future<ApiException> captureApiError(Future<Object?> Function() action) async {
    try {
      await action();
    } on Object catch (error) {
      return harness.apiErrorOf(error);
    }
    fail('预期请求以 ApiException 失败，但实际成功');
  }

  /// 轮询等待条件成立（真实 HTTP 栈下排队时序不能靠固定 sleep 猜）。
  ///
  /// 参数：
  ///   [condition] 条件谓词；
  ///   [timeout]   超时上限，超时抛 [TestFailure]（不静默挂起）。
  /// 返回：[Future<void>]。
  Future<void> waitFor(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return;
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    throw TestFailure('等待条件超时：${condition.runtimeType}');
  }

  setUp(() async {
    harness = NetworkChainHarness();
    await harness.start();
    // 显式登录态与非零代次：续期发起取样、写回前比对都依赖非默认值。
    harness.token = _oldToken;
    harness.sessionEpoch = 1;
  });

  tearDown(() => harness.dispose());

  group('单飞与续期请求形态（计划场景 1；契约单 Token 模型）', () {
    test('5 个并发请求同收 40101：refresh 仅 1 次，5 请求全部重放成功',
        () async {
      stubBusinessFirst401ThenSuccess();
      harness.stubRefreshSuccess();
      const requestCount = 5;

      final futures = <Future<Object?>>[
        for (var index = 0; index < requestCount; index++)
          postBusiness(
            'itx-u5-concurrent-$index',
            _idempotencyKeyFor(index),
          ),
      ];
      final results = await Future.wait<Object?>(futures);

      expect(results.length, requestCount);
      expect(
        results.every((data) => data is Map && data['ok'] == true),
        isTrue,
        reason: '5 个挂起请求必须各自重放成功并拿到业务 data',
      );
      expect(refreshCallCount(), 1, reason: '并发 40101 单飞：续期端点只调 1 次');
      expect(businessRequests().length, requestCount * 2,
          reason: '每个请求首发 1 次 + 续期后重放 1 次');
      expect(harness.writeTokenCallCount, 1, reason: '新 Token 仅写回 1 次');
      expect(harness.clearSessionCallCount, 0, reason: '续期成功不得清会话');
      expect(harness.lastWrittenToken, _newToken);
      expect(
        harness.lastWrittenExpireAt,
        DateTime.utc(2099, 1, 1),
        reason: 'expire_at 按 RFC3339 解析并归一为 UTC 写回',
      );
    });

    test('续期请求形态：Authorization 携旧 Token、无请求体（契约单 Token）',
        () async {
      stubBusinessFirst401ThenSuccess();
      harness.stubRefreshSuccess();

      await postBusiness('itx-u5-form', _idempotencyKeyFor(0));

      final refreshRequests = harness.server.received
          .where((request) => request.path == _refreshFullPath)
          .toList();
      expect(refreshRequests.length, 1);
      final refreshRequest = refreshRequests.single;
      expect(
        refreshRequest.header('authorization'),
        'Bearer $_oldToken',
        reason: '契约 /auth/token/refresh：旧 Token 经 Authorization 头携带',
      );
      expect(
        refreshRequest.body,
        isNull,
        reason: '单 Token 模型：续期请求无请求体（无 refresh_token 字段）',
      );
    });
  });

  group('重放两键逐字沿用（计划场景 2，KTD4 链路保证）', () {
    test('每个请求的 X-Interaction-Id / Idempotency-Key 首发与重放逐字相同',
        () async {
      stubBusinessFirst401ThenSuccess();
      harness.stubRefreshSuccess();
      const requestCount = 3;
      final keys = [
        for (var index = 0; index < requestCount; index++)
          _idempotencyKeyFor(index),
      ];
      final interactionIds = [
        for (var index = 0; index < requestCount; index++)
          'itx-u5-keys-$index',
      ];

      await Future.wait<Object?>([
        for (var index = 0; index < requestCount; index++)
          postBusiness(interactionIds[index], keys[index]),
      ]);

      final received = businessRequests();
      expect(received.length, requestCount * 2);
      for (var index = 0; index < requestCount; index++) {
        final pair = received
            .where(
              (request) =>
                  request.header(
                    HeaderInterceptor.idempotencyKeyHeader.toLowerCase(),
                  ) ==
                  keys[index],
            )
            .toList();
        expect(pair.length, 2, reason: '幂等键 ${keys[index]} 应有首发+重放两条');
        expect(
          pair.first.header(
            HeaderInterceptor.idempotencyKeyHeader.toLowerCase(),
          ),
          pair.last.header(
            HeaderInterceptor.idempotencyKeyHeader.toLowerCase(),
          ),
          reason: 'Idempotency-Key 必须逐字沿用，不得因重放换新',
        );
        for (final request in pair) {
          expect(
            request.header(
              HeaderInterceptor.interactionIdHeader.toLowerCase(),
            ),
            interactionIds[index],
            reason: 'X-Interaction-Id 必须逐字沿用首发值',
          );
        }
      }
    });
  });

  group('重放仅 Authorization 变化（计划场景 3）', () {
    test('重放请求除 Authorization（换新 Bearer）外其余头逐字不变', () async {
      stubBusinessFirst401ThenSuccess();
      harness.stubRefreshSuccess();
      // 隐私同意 + 设备 ID：让三头之一也参与逐字比对，覆盖更全。
      harness.privacyConsented = true;
      harness.deviceId = TestFixtures.deviceId;

      await postBusiness(
        TestFixtures.interactionId,
        TestFixtures.idempotencyKey,
      );

      final received = businessRequests();
      expect(received.length, 2);
      final first = received.first;
      final replay = received.last;
      expect(
        first.header('authorization'),
        'Bearer $_oldToken',
        reason: '首发携带旧 Token',
      );
      expect(
        replay.header('authorization'),
        'Bearer $_newToken',
        reason: '重放由 HeaderInterceptor 按每次重写规则换新 Token',
      );
      final allHeaderNames = <String>{
        ...first.headers.keys,
        ...replay.headers.keys,
      };
      for (final name in allHeaderNames) {
        if (name == 'authorization') continue;
        expect(
          replay.headers[name],
          first.headers[name],
          reason: '重放唯一允许变化的头是 Authorization：$name 必须逐字不变',
        );
      }
    });
  });

  group('重放仍 40101 防循环（计划场景 4）', () {
    test('续期成功但重放仍 40101：不二次 refresh，以重放响应 40101 失败',
        () async {
      // 业务恒定 40101：重放（带 auth_retried 标记）也收 40101。
      harness.stub('POST', '$_apiPrefix$_businessPath', (request) async {
        final idempotencyKey =
            request.header(
                HeaderInterceptor.idempotencyKeyHeader.toLowerCase()) ??
            '';
        final hitsForIdempotencyKey = businessRequests()
            .where(
              (seen) =>
                  seen.header(
                    HeaderInterceptor.idempotencyKeyHeader.toLowerCase(),
                  ) ==
                  idempotencyKey,
            )
            .length;
        return MockResponse(
          status: 401,
          body: ApiEnvelope.failure(
            ApiErrorCode.unauthorized.code,
            '登录已失效，请重新登录',
            requestId: hitsForIdempotencyKey == 1
                ? 'req_401_first'
                : 'req_401_replay',
          ),
        );
      });
      harness.stubRefreshSuccess();

      final apiError = await captureApiError(
        () => postBusiness('itx-u5-loop', _idempotencyKeyFor(0)),
      );

      expect(apiError.code, ApiErrorCode.unauthorized);
      expect(
        apiError.requestId,
        'req_401_replay',
        reason: '落调用方的是重放响应的 40101，不是首发的旧异常',
      );
      expect(refreshCallCount(), 1, reason: '已重放仍 40101 不得二次续期');
      expect(businessRequests().length, 2, reason: '仅首发 + 一次重放');
    });
  });

  group('认证类续期失败清会话（计划场景 5，R10 分流①）', () {
    test('refresh 自身 40101：leader 清会话 1 次、writeToken 0、不重放、'
        '挂起请求保留各自原始 40101', () async {
      stubBusinessAlwaysUnauthorized();
      harness.stubRefreshFailure(
        ApiErrorCode.unauthorized.code,
        requestId: 'req_refresh_auth_fail',
      );
      const requestCount = 2;

      final outcomes = await Future.wait<ApiException>([
        for (var index = 0; index < requestCount; index++)
          captureApiError(
            () => postBusiness(
              'itx-u5-authfail-$index',
              _idempotencyKeyFor(index),
            ),
          ),
      ]);

      expect(refreshCallCount(), 1, reason: '失败同样单飞，续期只发 1 次');
      expect(harness.clearSessionCallCount, 1,
          reason: '仅 leader 清会话 1 次，挂起分支不重复清');
      expect(harness.writeTokenCallCount, 0, reason: '认证失败不得写回 Token');
      expect(businessRequests().length, requestCount, reason: '认证失败不重放');
      expect(outcomes.length, requestCount);
      for (var index = 0; index < requestCount; index++) {
        expect(outcomes[index].code, ApiErrorCode.unauthorized);
        expect(
          outcomes[index].requestId,
          'req_401_${_idempotencyKeyFor(index)}',
          reason: '挂起请求必须保留各自原始 40101，而非 refresh 的异常',
        );
        expect(
          outcomes[index].requestId == 'req_refresh_auth_fail',
          isFalse,
          reason: '不得用 refresh 响应异常替换原请求异常',
        );
      }
    });

    test('refresh 收 40303（403 段）：同属认证类，清会话、writeToken 0、不重放',
        () async {
      stubBusinessAlwaysUnauthorized();
      harness.stubRefreshFailure(40303, requestId: 'req_refresh_403');

      final apiError = await captureApiError(
        () => postBusiness('itx-u5-403', _idempotencyKeyFor(0)),
      );

      expect(apiError.code, ApiErrorCode.unauthorized,
          reason: '挂起请求仍以各自原始 40101 失败');
      expect(harness.clearSessionCallCount, 1, reason: '403 段同属认证类失败');
      expect(harness.writeTokenCallCount, 0);
      expect(businessRequests().length, 1, reason: '不重放');
      expect(refreshCallCount(), 1);
    });
  });

  group('429 段续期限流不清会话（计划场景 6，R10 分流②）', () {
    test('refresh 收 42901 带 Retry-After：不清会话，异常带 retryAfterSec 透传',
        () async {
      stubBusinessAlwaysUnauthorized();
      harness.stubRefreshFailure(
        42901,
        retryAfter: '45',
        requestId: 'req_refresh_429',
      );
      const requestCount = 2;

      final outcomes = await Future.wait<ApiException>([
        for (var index = 0; index < requestCount; index++)
          captureApiError(
            () => postBusiness(
              'itx-u5-429-$index',
              _idempotencyKeyFor(index),
            ),
          ),
      ]);

      expect(harness.clearSessionCallCount, 0, reason: '429 段不清会话');
      expect(harness.writeTokenCallCount, 0);
      expect(businessRequests().length, requestCount, reason: '不重放');
      for (final apiError in outcomes) {
        expect(apiError.code, ApiErrorCode.aiQuotaExceeded,
            reason: '透传 refresh 响应的 42901 业务异常');
        expect(apiError.retryAfterSec, 45,
            reason: 'Retry-After 整数秒必须透传到挂起请求');
        expect(apiError.requestId, 'req_refresh_429');
      }
    });
  });

  group('网络失败/5xx 不清会话（计划场景 7，R10 分流③）', () {
    test('refresh 信封 50001：不清会话，归一为 networkFailure', () async {
      stubBusinessAlwaysUnauthorized();
      harness.stubRefreshFailure(
        ApiErrorCode.internalError.code,
        requestId: 'req_refresh_500',
      );

      final apiError = await captureApiError(
        () => postBusiness('itx-u5-500', _idempotencyKeyFor(0)),
      );

      expect(apiError.code, ApiErrorCode.networkFailure,
          reason: '5xx 归一为 networkFailure，重试留给 U6');
      expect(harness.clearSessionCallCount, 0, reason: '瞬时失败不踢登录态');
      expect(harness.writeTokenCallCount, 0);
      expect(businessRequests().length, 1, reason: '不重放');
    });

    test('refresh 网关直出 HTML 502（非信封）：networkFailure、不清会话',
        () async {
      stubBusinessAlwaysUnauthorized();
      harness.stub(
        'POST',
        _refreshFullPath,
        (request) async => MockResponse.raw(
          502,
          utf8.encode('<html><body>Bad Gateway</body></html>'),
        ),
      );

      final apiError = await captureApiError(
        () => postBusiness('itx-u5-502', _idempotencyKeyFor(0)),
      );

      expect(apiError.code, ApiErrorCode.networkFailure,
          reason: '非信封 5xx 经信封拦截器分流为 networkFailure');
      expect(harness.clearSessionCallCount, 0);
      expect(businessRequests().length, 1);
    });

    test('refresh 传输层连接拒绝：leader 收敛 networkFailure、不清会话、'
        '共享 Future 无 unhandled exception、失败后单飞字段复位', () async {
      // 绑定一个端口后立即关闭，得到一个确定无监听的端口（连接拒绝）。
      final probeSocket = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final closedPort = probeSocket.port;
      await probeSocket.close();
      final closedConfig = NetworkConfig(
        baseUrl: 'http://127.0.0.1:$closedPort$_apiPrefix',
        isRelease: false,
      );
      final hooks = harness.hooksForProbe();
      // 手工装配业务 dio：Header → Envelope → AuthRefresh，续期执行器指向
      // 已关闭端口（refresh 栈与业务栈物理分离，KTD3）。
      final networkDio = Dio(
        BaseOptions(
          baseUrl: await harness.serverBaseUrl(),
          validateStatus: (_) => true,
        ),
      );
      addTearDown(() => networkDio.close(force: true));
      networkDio.interceptors.add(HeaderInterceptor(hooks));
      networkDio.interceptors.add(const EnvelopeInterceptor());
      var refreshAttempts = 0;
      final baseExecutor = buildDefaultRefreshTokenExecutor(
        config: closedConfig,
        hooks: hooks,
      );
      networkDio.interceptors.add(
        AuthRefreshInterceptor(
          networkDio: networkDio,
          refreshExecutor: () {
            refreshAttempts += 1;
            return baseExecutor();
          },
          clearSession: hooks.onSessionCleared,
        ),
      );
      harness.stub('POST', '$_apiPrefix$_businessPath', (request) async {
        return MockResponse(
          status: 401,
          body: ApiEnvelope.failure(
            ApiErrorCode.unauthorized.code,
            '登录已失效，请重新登录',
            requestId: 'req_401_transport',
          ),
        );
      });

      final firstError = await captureApiError(
        () => networkDio.post<Object?>(
          _businessPath,
          data: const {'biz': 'ping'},
        ),
      );
      expect(firstError.code, ApiErrorCode.networkFailure);
      expect(harness.clearSessionCallCount, 0, reason: '传输失败不清会话');

      // 让出事件轮：若 leader 共享 Future 有未捕获异常，flutter test 会在此
      // 期间以 unhandled exception 直接判失败（异常安全红线）。
      await Future<void>.delayed(const Duration(milliseconds: 100));

      // 失败结论落定后单飞字段必须复位：下一轮 40101 允许重新发起续期。
      final secondError = await captureApiError(
        () => networkDio.post<Object?>(
          _businessPath,
          data: const {'biz': 'ping'},
        ),
      );
      expect(secondError.code, ApiErrorCode.networkFailure);
      expect(refreshAttempts, 2,
          reason: '两次独立 40101 各触发一次续期尝试，失败不永久占用单飞');
    });
  });

  group('未登录不续期（计划场景 8）', () {
    test('readToken 为 null 时收 40101：不发 refresh，原样透传', () async {
      harness.token = null;
      stubBusinessAlwaysUnauthorized();
      harness.stubRefreshSuccess();

      final apiError = await captureApiError(
        () => postBusiness('itx-u5-anon', _idempotencyKeyFor(0)),
      );

      expect(apiError.code, ApiErrorCode.unauthorized);
      expect(apiError.requestId, 'req_401_${_idempotencyKeyFor(0)}');
      expect(refreshCallCount(), 0, reason: '未登录态不得发起续期请求');
      expect(harness.clearSessionCallCount, 0);
      expect(harness.writeTokenCallCount, 0);
    });
  });

  group('取消语义（计划场景 9）', () {
    test('挂起期间单个 follower 被取消：共享续期不中断，其余正常重放，'
        '被取消请求收 cancel 且不重放', () async {
      final writeGate = Completer<void>();
      harness.writeTokenGate = writeGate.future;
      stubBusinessFirst401ThenSuccess();
      harness.stubRefreshSuccess();
      const requestCount = 3;
      final cancelTokens = [
        for (var index = 0; index < requestCount; index++) CancelToken(),
      ];

      final futures = <Future<Object?>>[
        for (var index = 0; index < requestCount; index++)
          postBusiness(
            'itx-u5-cancel-$index',
            _idempotencyKeyFor(index),
            cancelToken: cancelTokens[index],
          ),
      ];
      // 完成计数必须挂在「带错误处理」的监听副本上：直接对原失败 future
      // whenComplete 会派生出一条无人接住错误的链，flutter test 会以
      // unhandled exception 判失败。
      var settledCount = 0;
      final settlementErrors = <int, Object>{};
      for (var index = 0; index < futures.length; index++) {
        unawaited(
          futures[index].then<Object?>((_) {
            settledCount += 1;
            return null;
          }, onError: (Object error) {
            settlementErrors[index] = error;
            settledCount += 1;
            return null;
          }),
        );
      }

      // 等三个首发 40101 均到达、共享续期已发起（writeToken 正阻塞在闸门）。
      await waitFor(
        () =>
            businessRequests().length == requestCount &&
            refreshCallCount() == 1,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(settledCount, 0, reason: 'writeToken 未完成前挂起请求不得放行');
      expect(businessRequests().length, requestCount, reason: '闸门期间无重放');

      // 仅取消第 3 个请求（follower）。
      cancelTokens[2].cancel();
      await waitFor(() => settlementErrors.containsKey(2));
      expect(refreshCallCount(), 1, reason: 'follower 取消不得中断共享续期');
      expect(businessRequests().length, requestCount,
          reason: '续期结论未落定，任何请求都还不能重放');
      expect(
        settlementErrors[2],
        isA<DioException>().having(
          (error) => error.type,
          'type',
          DioExceptionType.cancel,
        ),
        reason: '挂起期间被取消的请求收裸 cancel',
      );

      // 放行 writeToken：leader 结论落定，其余 follower 放行重放。
      writeGate.complete();

      final firstData = await futures[0];
      final secondData = await futures[1];
      expect(firstData, isA<Map>());
      expect((firstData as Map?)?['ok'], isTrue);
      expect((secondData as Map?)?['ok'], isTrue);
      expect(harness.clearSessionCallCount, 0);
      expect(refreshCallCount(), 1, reason: '全程只有一次续期');
      final received = businessRequests();
      expect(received.length, requestCount + (requestCount - 1),
          reason: '仅未取消的 2 个请求重放');
      expect(
        received
            .where(
              (request) =>
                  request.header(
                    HeaderInterceptor.idempotencyKeyHeader.toLowerCase(),
                  ) ==
                  _idempotencyKeyFor(2),
            )
            .length,
        1,
        reason: '被取消请求只首发、不重放',
      );
    });

    test('cancel 错误直达本拦截器：裸穿透，不触发续期、不出网', () async {
      harness.stubRefreshSuccess();
      final cancelToken = CancelToken()..cancel();

      Object? caughtError;
      try {
        await postBusiness(
          'itx-u5-precancel',
          _idempotencyKeyFor(0),
          cancelToken: cancelToken,
        );
      } on Object catch (error) {
        caughtError = error;
      }

      expect(caughtError, isA<DioException>());
      expect(
        (caughtError as DioException).type,
        DioExceptionType.cancel,
        reason: 'cancel 是显式例外，不穿业务外衣',
      );
      expect(refreshCallCount(), 0, reason: 'cancel 不触发续期');
      expect(harness.server.received, isEmpty, reason: '取消在出网前生效');
    });
  });

  group('续期在途代次变更（计划场景 10，R10）', () {
    test('写回前代次已变（登出/换号）：丢弃结果、writeToken 0、不重放、'
        '队列以各自原始 40101 结束', () async {
      stubBusinessAlwaysUnauthorized();
      // hooks 在 harness.start() 时定型（读 sessionEpoch 字段），故代次
      // 变更必须通过真实状态变更注入：续期请求到达 mock 的时刻即「续期
      // 在途」，此时推进会话代次并保留 Token（模拟换号/登出语义里的
      // 代次跳变），执行器写回前第二次取样必然与发起时不一致。
      var refreshSeenByServer = false;
      harness.stub(
        'POST',
        _refreshFullPath,
        (request) async {
          if (!refreshSeenByServer) {
            refreshSeenByServer = true;
            harness.bumpSessionEpoch(clearToken: false);
          }
          return MockResponse(
            status: 200,
            body: ApiEnvelope.success(
              data: const {
                'token': _newToken,
                'expire_at': '2099-01-01T00:00:00Z',
              },
              requestId: 'req_refresh_ok_late',
            ),
          );
        },
      );
      const requestCount = 2;

      final outcomes = await Future.wait<ApiException>([
        for (var index = 0; index < requestCount; index++)
          captureApiError(
            () => postBusiness(
              'itx-u5-epoch-$index',
              _idempotencyKeyFor(index),
            ),
          ),
      ]);

      expect(refreshCallCount(), 1);
      expect(harness.writeTokenCallCount, 0, reason: '代次不一致必须丢弃新 Token');
      expect(businessRequests().length, requestCount, reason: '不重放');
      for (var index = 0; index < requestCount; index++) {
        expect(
          outcomes[index].code,
          ApiErrorCode.unauthorized,
          reason: '按清会话语义以各自原始 40101 结束',
        );
        expect(
          outcomes[index].requestId,
          'req_401_${_idempotencyKeyFor(index)}',
        );
      }
    });
  });

  group('writeToken 受控 Future 无抢跑（计划场景 11）', () {
    test('writeToken 完成前挂起队列不重放；完成后全部重放成功', () async {
      final writeGate = Completer<void>();
      harness.writeTokenGate = writeGate.future;
      stubBusinessFirst401ThenSuccess();
      harness.stubRefreshSuccess();
      const requestCount = 3;

      final futures = <Future<Object?>>[
        for (var index = 0; index < requestCount; index++)
          postBusiness(
            'itx-u5-gate-$index',
            _idempotencyKeyFor(index),
          ),
      ];

      await waitFor(
        () =>
            businessRequests().length == requestCount &&
            refreshCallCount() == 1,
      );
      // 续期 HTTP 已回但 writeToken 阻塞在闸门：留出调度余量后确认无抢跑。
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(harness.writeTokenCallCount, 0);
      expect(businessRequests().length, requestCount,
          reason: 'writeToken 未完成，任何挂起请求不得提前重放');

      writeGate.complete();

      final results = await Future.wait<Object?>(futures);
      expect(
        results.every((data) => data is Map && data['ok'] == true),
        isTrue,
      );
      expect(harness.writeTokenCallCount, 1);
      expect(businessRequests().length, requestCount * 2);
      expect(harness.clearSessionCallCount, 0);
    });
  });

  group('独立 refresh dio 装配形态（KTD3）', () {
    test('buildRefreshDio 仅挂 Header + Envelope，物理隔离 AuthRefresh/Retry',
        () {
      final refreshDio = buildRefreshDio(
        config: NetworkConfig(
          baseUrl: 'http://127.0.0.1:1$_apiPrefix',
          isRelease: false,
        ),
        hooks: harness.hooksForProbe(),
      );
      addTearDown(() => refreshDio.close(force: true));

      // dio 5.x 拦截器表默认内置 ImplyContentTypeInterceptor（仅按载荷补
      // content-type，无业务语义），按类型剔除后业务拦截器必须恰好两个。
      final businessInterceptors = refreshDio.interceptors
          .where(
            (interceptor) =>
                interceptor.runtimeType.toString() !=
                'ImplyContentTypeInterceptor',
          )
          .map((interceptor) => interceptor.runtimeType)
          .toList();
      expect(
        businessInterceptors,
        containsAllInOrder(
          <Type>[HeaderInterceptor, EnvelopeInterceptor],
        ),
        reason: '续期栈按发出向仅 Header → Envelope',
      );
      expect(businessInterceptors.length, 2,
          reason: '不得挂 AuthRefresh（递归续期）与 Retry（嵌套重试预算）');
      expect(
        businessInterceptors,
        isNot(contains(AuthRefreshInterceptor)),
        reason: 'refresh 栈物理隔离 AuthRefreshInterceptor（KTD3）',
      );
    });
  });

  group('R16 源码白名单（续期链路不落 Token/Authorization 明文）', () {
    test('auth_refresh_interceptor.dart 无任何日志输出、无 JWT exp 解析', () {
      final code = productionCodeOf(
        'lib/core/network/interceptors/auth_refresh_interceptor.dart',
      );

      expect(code.contains('LogInterceptor'), isFalse,
          reason: '续期链路禁挂 LogInterceptor（Authorization/Token 明文风险）');
      expect(RegExp(r'(^|\s)print\s*\(').hasMatch(code), isFalse);
      expect(RegExp(r'\bdebugPrint\s*\(').hasMatch(code), isFalse);
      expect(code.contains('developer.log'), isFalse);
      expect(
        RegExp(r'exp(ire)?[A-Za-z_0-9]*\s*\(').hasMatch(code),
        isFalse,
        reason: '不解析 JWT exp（§13.3：客户端时钟不可信，不做本地过期预判）',
      );
    });

    test('api_client.dart 续期装配无日志拦截器/打印', () {
      final code = productionCodeOf('lib/core/network/api_client.dart');

      expect(code.contains('LogInterceptor'), isFalse);
      expect(RegExp(r'(^|\s)print\s*\(').hasMatch(code), isFalse);
      expect(code.contains('developer.log'), isFalse);
    });
  });
}
