/// 网络拦截器链测试 harness（计划 R9 / U3）：生产同款 dio + 拦截器共享装配。
///
/// 设计纪律（计划 R9）：
///   - 行为轨测试不走裸 dio，也不在测试里各拼一份拦截器列表，而是调用生产
///     装配函数 `buildNetworkDio(...)` —— 与 [dioProvider] 同一条代码路径，
///     后端就绪切真服务时断言一行不改；
///   - 429 与 401 的 fixture **分开造**（[stubRateLimited] / [stubUnauthorized]）：
///     U5 单飞续期与 U6 重试都依赖「这两类错误各自被正确分流」，共用一个
///     万能桩会让分流行为测不出来；
///   - 全部可变依赖（token、隐私同意态、设备 ID、UUID 生成器）经 [NetworkHooks]
///     回调注入，不引 mockito / dio_adapter（与 [MockApiServer] 同取向）。
///
/// 生命周期：
/// ```dart
/// final harness = NetworkChainHarness();
/// await harness.start();
/// harness.stub('GET', '/ping', (req) async => MockResponse(body: ApiEnvelope.success()));
/// await harness.dio.get('/ping');
/// await harness.dispose();
/// ```
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart' show TestFailure;
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

import 'api_envelope.dart';
import 'mock_api_server.dart';

/// 429 段 fixture 默认 Retry-After（整数秒，契约形态）。
const String harnessDefaultRetryAfter = '60';

/// 网络链行为测试 harness。
class NetworkChainHarness {
  /// 构造一个 harness。
  ///
  /// 参数：
  ///   [config] 覆盖网络配置（如模拟 release 态）；null 时用 mock 基址 +
  ///            非 release 配置（允许 http localhost）；
  ///   [hooks]  完全自定义回调集；null 时用本 harness 的可变状态装配一套。
  NetworkChainHarness({NetworkConfig? config, NetworkHooks? hooks})
      : _configOverride = config,
        _hooksOverride = hooks;

  /// 测试侧覆盖配置（null 则按 mock 端口构造）。
  final NetworkConfig? _configOverride;

  /// 测试侧完全自定义回调（null 则用 harness 状态回调）。
  final NetworkHooks? _hooksOverride;

  /// 内存 mock 服务（真实 HTTP 栈）。
  late final MockApiServer server;

  /// 生产同款装配的 dio（`buildNetworkDio`，计划 R9）。
  late final Dio dio;

  /// 当前登录 Token（null = 未登录，请求头不得出现 Authorization）。
  ///
  /// 单 Token 模型（契约 `/auth/token/refresh`，架构 §6.5）：续期请求
  /// 复用同一 Token 作为 Authorization 凭证，harness 不另设 refreshToken。
  String? token;

  /// 当前隐私同意态（false 时请求头不得出现 X-Device-Id，R7）。
  bool privacyConsented = false;

  /// 当前设备 ID（null 时回调也返回 null；与同意态联动由拦截器负责）。
  String? deviceId;

  /// 当前会话代次（U5：续期发起取样、写回前比对；用例可在续期在途
  /// 期间调 [bumpSessionEpoch] 模拟登出/换号）。
  int sessionEpoch = 0;

  /// writeToken 回调被调用的次数（U5 场景断言：认证类失败/代次变更
  /// 时必须为 0；受控 Completer 场景用它确认写回发生时点）。
  int writeTokenCallCount = 0;

  /// 最近一次 writeToken 写入的新 Token（null = 从未写回）。
  String? lastWrittenToken;

  /// 最近一次 writeToken 写入的到期时刻。
  DateTime? lastWrittenExpireAt;

  /// onSessionCleared 回调被调用的次数（U5：并发挂起下必须恰好 1 次）。
  int clearSessionCallCount = 0;

  /// writeToken 受控闸门（U5 场景 11）：非 null 时 writeToken 回调
  /// 会先等待该 Future 完成再返回——用 Completer 控制写回完成时点，
  /// 证明挂起请求在写回完成前不会提前重放。
  Future<void>? writeTokenGate;

  /// readSessionEpoch 受控覆盖（U5 场景 9）：非 null 时回调返回此函数
  /// 的结果而非 [sessionEpoch]，用于模拟「发起后代次已变」而不依赖
  /// 真实时序（真实链路则直接改 [sessionEpoch]）。
  Future<int> Function()? epochReaderOverride;

  /// writeToken 受控覆盖（U5 场景 9 配合用）：非 null 时替代 harness
  /// 默认写回行为（默认行为会更新 [token]，使重放带新 Authorization）。
  Future<void> Function(String token, DateTime expireAt)? writeTokenOverride;

  /// onSessionCleared 受控覆盖：非 null 时在默认计数之外额外执行。
  Future<void> Function()? clearSessionOverride;

  /// UUID v4 生成调用计数（详设 §11.1.1 第 3 断言：重试链路只生成一次；
  /// 收口在 U6，U3 先提供计数通道）。
  int uuidCallCount = 0;

  /// 历次生成的 UUID v4（顺序保留，U6 断言两键逐字相同时复用）。
  final List<String> generatedUuids = <String>[];

  /// 启动 mock 服务并装配生产同款 dio。
  ///
  /// 返回：[Future<String>] mock 服务基址（含 `/api/v1` 前缀）。
  Future<String> start() async {
    server = MockApiServer();
    final mockBaseUrl = await server.start();
    dio = buildNetworkDio(
      config: _configOverride ??
          NetworkConfig(baseUrl: mockBaseUrl, isRelease: false),
      hooks: _hooksOverride ?? _stateBackedHooks(),
    );
    return mockBaseUrl;
  }

  /// 停止 mock 服务并关闭 dio。
  ///
  /// 返回：[Future<void>] 资源释放完成。
  Future<void> dispose() async {
    dio.close(force: true);
    await server.stop();
  }

  /// 暴露当前可变状态装配的 [NetworkHooks]（U4 实测二：探针链需要与
  /// harness.dio 不同的 dio 实例，但回调缝必须同源——token/同意态/设备 ID
  /// 的在用例内赋值对探针链同样生效）。
  ///
  /// 返回：[NetworkHooks] 与 [start] 装配生产 dio 时所用的同一套状态回调。
  NetworkHooks hooksForProbe() => _stateBackedHooks();

  /// 当前 mock 服务基址（U4 实测二：探针链手动构造 dio 时需要与
  /// harness.dio 相同的 baseUrl，但不能复用 dio 实例——探针只挂探针链）。
  ///
  /// 返回：[Future<String>] mock 基址（须在 [start] 之后调用）。
  Future<String> serverBaseUrl() async =>
      'http://${server.address.host}:${server.port}/api/v1';

  /// 推进会话代次（U5 场景 9：模拟续期在途期间用户登出/换号）。
  ///
  /// 参数：[clearToken] true 时同时把 [token] 置 null（模拟登出）；
  ///   false 仅换代次（模拟换号但拦截器读态时点不确定的竞态）。
  /// 返回：void；续期执行器写回前比对代次不一致即丢弃结果。
  void bumpSessionEpoch({bool clearToken = false}) {
    sessionEpoch += 1;
    if (clearToken) token = null;
  }

  /// 登记续期成功 fixture（U5 单飞场景复用）。
  ///
  /// 参数：
  ///   [newToken]  续期响应的新 JWT（默认确定性假值，禁真实凭据）；
  ///   [expireAt]  新到期时刻（默认 2099 年，RFC3339 UTC 形态）；
  ///   [requestId] 信封 request_id。
  /// 返回：void；路由为 `POST /api/v1/auth/token/refresh`，无请求体
  ///   要求（契约：旧 Token 在 Authorization 头）。
  void stubRefreshSuccess({
    String newToken = 'jwt-refreshed-fake',
    String expireAt = '2099-01-01T00:00:00Z',
    String requestId = 'req_test_refresh_ok',
  }) {
    server.stub('POST', '/api/v1/auth/token/refresh', (req) async {
      return MockResponse(
        status: 200,
        body: ApiEnvelope.success(
          data: {'token': newToken, 'expire_at': expireAt},
          requestId: requestId,
        ),
      );
    });
  }

  /// 登记续期失败 fixture（U5 失败三分流）。
  ///
  /// 参数：
  ///   [code]       续期响应业务码（40101/403xx/429xx/5xx 等）；
  ///   [retryAfter] Retry-After 整数秒字符串，null 不带头（429 段测试
  ///                用它验证挂起请求异常携带 retryAfterSec）；
  ///   [requestId]  信封 request_id。
  /// 返回：void。
  void stubRefreshFailure(
    int code, {
    String? retryAfter,
    String requestId = 'req_test_refresh_fail',
  }) {
    server.stub('POST', '/api/v1/auth/token/refresh', (req) async {
      return MockResponse(
        status: code ~/ 100,
        headers: retryAfter == null ? const {} : {'Retry-After': retryAfter},
        body: ApiEnvelope.failure(
          code,
          '续期失败（测试 fixture code=$code）',
          requestId: requestId,
        ),
      );
    });
  }

  /// 登记路由（转发到 [MockApiServer.stub]，测试侧少一次内部对象访问）。
  ///
  /// 参数：
  ///   [method]  HTTP 方法（大小写不敏感）；
  ///   [path]    不含 query 的路径（含 `/api/v1` 前缀）；
  ///   [handler] 请求处理器。
  /// 返回：void；后登记同键路由覆盖前者。
  void stub(
    String method,
    String path,
    MockRouteHandler handler,
  ) {
    server.stub(method, path, handler);
  }

  /// 登记一条 429 段限流 fixture（与 401 fixture 分开造，R9）。
  ///
  /// 参数：
  ///   [method]/[path] 路由；
  ///   [code]          429 段业务码，默认 42902（联系限频）；
  ///   [retryAfter]    Retry-After 整数秒字符串，默认
  ///                   [harnessDefaultRetryAfter]；传非整数字符串可测回退；
  ///   [requestId]     信封 request_id。
  /// 返回：void。
  void stubRateLimited(
    String method,
    String path, {
    int code = 42902,
    String retryAfter = harnessDefaultRetryAfter,
    String requestId = 'req_test_429',
  }) {
    server.stub(method, path, (req) async {
      return MockResponse(
        status: code ~/ 100,
        headers: {'Retry-After': retryAfter},
        body: ApiEnvelope.failure(
          code,
          '操作过于频繁，请稍后再试',
          requestId: requestId,
        ),
      );
    });
  }

  /// 登记一条 40101 未登录/Token 失效 fixture（与 429 fixture 分开造，R9）。
  ///
  /// 参数：
  ///   [method]/[path] 路由；
  ///   [requestId]     信封 request_id。
  /// 返回：void；不带 Retry-After（40101 不在 8 个限流/锁定码集合内）。
  void stubUnauthorized(
    String method,
    String path, {
    String requestId = 'req_test_401',
  }) {
    server.stub(method, path, (req) async {
      return MockResponse(
        status: 401,
        body: ApiEnvelope.failure(
          ApiErrorCode.unauthorized.code,
          '登录已失效，请重新登录',
          requestId: requestId,
        ),
      );
    });
  }

  /// 从调用方 catch 到的对象中取出 [ApiException]。
  ///
  /// EnvelopeInterceptor 按 KTD2 以 `reject(err, true)` 分流，业务错误以
  /// [DioException.error] 承载（dio 的 reject 签名只接受 [DioException]），
  /// 故调用方 catch 到的是包了一层的 [DioException]。本方法是测试侧唯一的
  /// 拆包处，避免每条用例各写一遍强转。
  ///
  /// 参数：[error] catch 到的异常对象，须为 `DioException` 且 error 是
  ///   [ApiException]。
  /// 返回：[ApiException] 业务异常。
  ApiException apiErrorOf(Object error) {
    if (error is! DioException) {
      throw TestFailure('期望 DioException（KTD2 reject 包装），实际：$error');
    }
    final inner = error.error;
    if (inner is! ApiException) {
      throw TestFailure('期望 DioException.error 为 ApiException，实际：$inner');
    }
    return inner;
  }

  /// 由 harness 可变状态装配一套 [NetworkHooks]（token/同意态/设备 ID
  /// 均在用例内直接赋值切换，UUID 生成计数供 §11.1.1 断言使用）。
  ///
  /// 返回：[NetworkHooks] 回调集。
  NetworkHooks _stateBackedHooks() {
    return NetworkHooks(
      readToken: () async => token,
      readPrivacyConsented: () async => privacyConsented,
      readDeviceId: () async => deviceId,
      newUuidV4: () {
        final value = _fixedUuidForCall(uuidCallCount);
        uuidCallCount++;
        generatedUuids.add(value);
        return value;
      },
      // U5：写回默认同步更新 harness.token，重放请求经 HeaderInterceptor
      // 重写 Authorization 后即携带新 Token（场景 3 据此逐字比对）。
      writeToken: (newToken, expireAt) async {
        // 受控闸门（场景 11）：闸门未完成前执行器不返回，挂起请求不得重放。
        final gate = writeTokenGate;
        if (gate != null) await gate;
        final override = writeTokenOverride;
        if (override != null) {
          await override(newToken, expireAt);
        } else {
          token = newToken;
        }
        writeTokenCallCount++;
        lastWrittenToken = newToken;
        lastWrittenExpireAt = expireAt;
      },
      onSessionCleared: () async {
        clearSessionCallCount++;
        final override = clearSessionOverride;
        if (override != null) await override();
      },
      readSessionEpoch: epochReaderOverride ?? () async => sessionEpoch,
    );
  }

  /// 确定性 UUID v4 序列：每次调用取序列下一值，超出后按序号派生。
  ///
  /// 用确定性值而非随机值：重试两键「逐字相同」的断言不能依赖概率。
  /// 序列值全部满足契约 UUID v4 正则（4xxx 版本位、8/9/a/b 变体位）。
  static String _fixedUuidForCall(int index) {
    const sequence = <String>[
      '11111111-1111-4111-8111-111111111111',
      '22222222-2222-4222-9222-222222222222',
      '33333333-3333-4333-a333-333333333333',
    ];
    if (index < sequence.length) return sequence[index];
    final suffix = (index + 1).toString().padLeft(12, '4');
    return '44444444-4444-4444-8444-${suffix.substring(suffix.length - 12)}';
  }
}
