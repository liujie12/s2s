/// 40101 单飞续期拦截器（详细设计 §13 / §11.1 链序第 4 位 / §12.2，
/// 编码规范 §5.4，计划 U5：R9/R10/R16、KTD3/KTD4）。
///
/// 职责：业务请求收到已拆信封的 `40101`（[ApiErrorCode.unauthorized]）时，
/// 全客户端只发起**一次**续期（single-flight），并发/续期在途期间到达的
/// 其余 40101 全部挂起等同一结果；续期成功后各挂起请求**各自**经
/// `dio.fetch` 重放原始请求，失败则按 [RefreshVerdict] 三分流。
///
/// 边界（计划 U5，U6 将在链上本拦截器之后接 RetryInterceptor）：
///   - 本类**不含任何重试/退避/计时逻辑**：传输错误归一与全链路 2 次
///     重试是 U6 RetryInterceptor 的唯一职责（KTD10）；
///   - 本类**不解析 JWT exp、不做本地过期预判**（§13.3，客户端时钟
///     不可信，以服务端 40101 为唯一触发源）；
///   - 本类**不感知 Riverpod / AuthSessionNotifier**：续期动作经构造
///     注入的 [RefreshTokenExecutor] 完成，会话读写全部在装配侧经
///     NetworkHooks 回调（KTD5，依赖方向 features → core 单向）；
///   - 本类**不手写 Authorization 头**：重放走 `dio.fetch` 重走全链，
///     HeaderInterceptor 按「每次重写」规则用新 Token 重写该头；
///     `X-Interaction-Id`/`Idempotency-Key` 因「containsKey 才写」
///     逐字沿用（KTD4，两键保全由链路保证而非本类复制头）。
///
/// R16 日志白名单：续期链路**不落任何日志/统计**——本文件无 print、
/// 无 LogInterceptor、无回调上报；新旧 Token、Authorization 头、请求体
/// 均不允许出现在任何输出中（编码规范 §4.11）。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../api_error_code.dart';
import '../api_exception.dart';

/// 续期执行器：装配侧用独立 dio（仅挂 Header + Envelope，KTD3）构建，
/// 内部完成「读旧 Token → POST /auth/token/refresh → 代次校验 →
/// writeToken 写回」全流程。
///
/// 返回 [RefreshResult]：
///   - [RefreshResult.success] 续期成功且新 Token 已写回，可重放；
///   - [RefreshResult.stale]   续期在途期间会话已变更/登出（代次不一致
///                             或旧 Token 已不存在），结果被丢弃；
/// 续期请求自身的业务/网络失败以**抛异常**表达（信封失败是
/// [ApiException]，传输失败是 [DioException]），由本拦截器三分流。
typedef RefreshTokenExecutor = Future<RefreshResult> Function();

/// 续期执行结果（成功 / 会话已过期（代次变更）两态）。
sealed class RefreshResult {
  /// 构造续期结果基类（仅子类使用）。
  const RefreshResult();

  /// 续期成功且新 Token 已写回。
  ///
  /// 参数：[token] 新 Token（仅供成功态语义承载；拦截器重放不直接使用，
  /// 新 Authorization 头由 HeaderInterceptor 从会话态读取重写）。
  const factory RefreshResult.success(RefreshedToken token) =
      RefreshSuccess;

  /// 续期在途期间会话代次已变更（登出/换号），结果丢弃、不写回、不重放。
  const factory RefreshResult.stale() = RefreshStale;
}

/// 续期成功结果（[RefreshResult.success] 的落地类）。
class RefreshSuccess extends RefreshResult {
  /// 构造成功结果。
  ///
  /// 参数：[refreshedToken] 新 Token 与新到期时刻。
  const RefreshSuccess(this.refreshedToken);

  /// 新 Token 与到期时刻。
  final RefreshedToken refreshedToken;
}

/// 代次变更结果（[RefreshResult.stale] 的落地类）。
class RefreshStale extends RefreshResult {
  /// 构造代次变更结果。
  const RefreshStale();
}

/// 续期得到的新 Token 与到期时刻（契约 data：`{token, expire_at}`）。
class RefreshedToken {
  /// 构造新 Token 载体。
  ///
  /// 参数：
  ///   [token]    新 JWT；
  ///   [expireAt] 新到期时刻（已归一为 UTC）。
  const RefreshedToken({required this.token, required this.expireAt});

  /// 新 JWT。
  final String token;

  /// 新到期时刻（UTC，仅供展示，过期判定以服务端 40101 为准）。
  final DateTime expireAt;
}

/// 单飞续期拦截器。
class AuthRefreshInterceptor extends Interceptor {
  /// 构造拦截器。
  ///
  /// 参数：
  ///   [networkDio]      业务 dio 引用，续期成功后经 `networkDio.fetch`
  ///                     重放原始请求（重走全链，KTD4）；注入而非从
  ///                     RequestOptions 反取，因 dio 5.11.1 的
  ///                     RequestOptions 不持有所属 dio；
  ///   [refreshExecutor] 续期执行器（独立 dio + 会话回调，KTD3）；
  ///   [clearSession]    认证类续期失败（refresh 自身 40101/403xx）时
  ///                     清空会话的回调；由 leader 分支**唯一调用一次**
  ///                     （挂起分支只 await 共享结论，不重复清会话），
  ///                     映射到 NetworkHooks.onSessionCleared。
  AuthRefreshInterceptor({
    required Dio networkDio,
    required RefreshTokenExecutor refreshExecutor,
    required Future<void> Function() clearSession,
  })  : _networkDio = networkDio,
        _refreshExecutor = refreshExecutor,
        _clearSession = clearSession;

  /// 业务 dio（重放走其 fetch，从链首重经全部拦截器，KTD4）。
  final Dio _networkDio;

  /// 续期执行器（装配侧构建，core 不感知会话存储细节）。
  final RefreshTokenExecutor _refreshExecutor;

  /// 清会话回调（认证类续期失败时由 leader 唯一调用，R10 分流①）。
  final Future<void> Function() _clearSession;

  /// 在途续期的共享结论（单飞唯一字段，KTD3）。
  ///
  /// 判空 → 赋值 → 共享 await：首个 40101 触发执行器并保存 Future，
  /// 并发 40101 直接 await 同一 Future，故续期接口实际调用次数恒为 1。
  /// 执行器自身保证「结论落定前已完成 writeToken」，故挂起请求被
  /// 放行时新 Token 必然已写回，无重放抢跑（场景 11）。
  Future<RefreshVerdict>? _inFlight;

  /// RequestOptions.extra 中「本请求已续期重放过」的标记键。
  ///
  /// 重放请求经 `dio.fetch` 重走全链时在 extra 置 true；若重放仍收
  /// 40101（新 Token 也无效），不再二次续期，原样失败（防循环，场景 4）。
  static const String authRetriedExtraKey = 'auth_refresh_retried';

  /// RequestOptions.extra 中「本错误来自续期成功后的重放 fetch」标记键
  /// （评审 #1：防重试预算链式放大）。
  ///
  /// 为什么需要它：[_replay] 经 `dio.fetch` 重走全链，重放链末端的
  /// RetryInterceptor 是同拦截器的**另一次** onError 调用，局部重试计数
  /// 从 0 起；若不区分，重放遇 5xx/传输失败时重放链会自开一份重试预算，
  /// 错误冒泡回首发起后外层循环再开一份，单次业务请求最坏放大为 10 个
  /// 请求（详设 §14.1「全链路总共 2 次」被击穿）。RetryInterceptor 见此
  /// 标记必须不自起外层循环，直接把错误交回**首发链**外层唯一循环。
  ///
  /// 该标记仅存活于重放 fetch 链路；[_replay] 的 catch 在把错误交还链尾
  /// 前必剥离它（与 RetryInterceptor 剥离自身 inner 标记同构），使落
  /// 首发链外层循环的错误形态是「普通已续期重放失败」，可正常计数重试。
  static const String authReplayDispatchExtraKey = 'auth_replay_dispatch';

  /// 错误方向：只处理「已拆信封的业务 40101」，其余错误原样透传。
  ///
  /// 参数：
  ///   [err]     上游（EnvelopeInterceptor 或更后）传来的错误；
  ///   [handler] 续期成功调 `handler.resolve`（重放响应），分流失败
  ///             调 `handler.reject`，非 40101 调 `handler.next`。
  /// 返回：[void]（异步）。
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // cancel 是显式例外（KTD10）：被取消的请求不触发续期、不穿任何
    // 业务外衣，裸 DioExceptionType.cancel 穿透到调用方（场景 8b）。
    if (err.type == DioExceptionType.cancel) {
      handler.next(err);
      return;
    }

    final Object? error = err.error;
    final ApiException originalError;
    if (error is! ApiException ||
        error.code != ApiErrorCode.unauthorized) {
      // 非「已拆信封的业务 40101」一律透传：网络层错误（非 ApiException）
      // 不触发刷新；归一在 U6，本拦截器不提前映射。
      handler.next(err);
      return;
    }
    originalError = error;

    final options = err.requestOptions;

    // 已续期重放仍 40101（新 Token 也无效）：不再二次刷新，原样失败，
    // 防循环（U5 场景：再次 40101 直接失败）。未登录态（readToken 为
    // null）收到 40101 时，执行器内判空返 stale，同样不发续期请求。
    if (options.extra[authRetriedExtraKey] == true) {
      // 已用续期后的新 Token 重放仍 40101：不再刷新，原样以该
      // 40101 失败（场景 4）。
      handler.reject(err, true);
      return;
    }

    // 挂起前检查取消：请求在错误到达本拦截器前/续期排队期间已被
    // CancelToken 取消，则不参与续期，直接以 cancel 落调用方（场景 8a）。
    if (options.cancelToken?.isCancelled ?? false) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        ),
        true,
      );
      return;
    }

    final verdict = await _joinOrStartRefresh();

    // 拿到结论时再次检查取消：续期在途期间单个挂起请求被取消，不影响
    // 共享续期（leader 不因 follower 取消而中断），但该请求不重放（场景 8a）。
    if (options.cancelToken?.isCancelled ?? false) {
      handler.reject(
        DioException(
          requestOptions: options,
          type: DioExceptionType.cancel,
        ),
        true,
      );
      return;
    }

    switch (verdict) {
      case RefreshSuccessVerdict():
        await _replay(options, handler);
      case RefreshAuthFailedVerdict():
        // 认证类失败：会话已由 leader 清空；各挂起请求保留**各自原始**
        // 40101（不拿 refresh 的异常替换原请求异常，场景 5/7）。
        handler.reject(_wrapApiException(options, originalError), true);
      case RefreshStaleVerdict():
        // 续期期间会话已登出/换号：结果被丢弃，按清会话语义以原 40101
        // 结束挂起请求（场景 9），不重放。
        handler.reject(_wrapApiException(options, originalError), true);
      case RefreshRateLimitedVerdict(:final refreshError):
        // 429 段：不清会话；挂起请求收到携带 retryAfterSec 的异常
        // （透传 refresh 响应的 Retry-After，场景 6）。
        handler.reject(_wrapApiException(options, refreshError), true);
      case RefreshTransientVerdict(:final refreshError):
        // 网络失败/5xx：不清会话；以 refresh 链路上的失败异常结束，
        // 重试动作留给 U6（场景 7）。
        handler.reject(_refreshFailure(options, refreshError), true);
    }
  }

  /// 加入在途续期；无在途则作为 leader 启动一次（单飞，KTD3）。
  ///
  /// 返回：[Future<RefreshVerdict>] 所有并发调用方共享同一结论。
  ///   leader 的执行 Future 永不抛错（异常在此处收敛为分流结论），
  ///   保证多个 await 方不会产生 unhandled exception（纪律红线）。
  Future<RefreshVerdict> _joinOrStartRefresh() {
    final existing = _inFlight;
    if (existing != null) return existing;
    final future = _runRefreshAsLeader();
    _inFlight = future;
    // 结论落定即清空单飞字段：下一轮 40101（如新 Token 也过期）允许
    // 重新续期。leader Future 保证不抛（_runRefreshAsLeader 已全量 catch
    // 并收敛为 RefreshVerdict 返回值），故用 ignore 表明此处有意不消费
    // 结论（调用方各自持有同一 Future 的引用并 await），不存在未捕获异常。
    unawaited(
      future.whenComplete(() {
        _inFlight = null;
      }),
    );
    future.ignore();
    return future;
  }

  /// leader 执行续期并把结果/异常收敛为 [RefreshVerdict]。
  ///
  /// 为什么在此收敛异常而非让执行器 Future 抛出后各 await 方自行 catch：
  /// 共享失败 Future 被多个分支 await 时，任一分支漏 catch 即产生
  /// unhandled exception（5.11.0 前的 dio 队列悬挂同源问题）；收敛为
  /// 普通返回值后，每个挂起分支只做 switch 分流，异常不可能逃逸。
  ///
  /// 认证类失败（40101/403xx）时由 leader 在本方法内**唯一一次**调用
  /// [_clearSession]（= NetworkHooks.onSessionCleared）：挂起分支只
  /// await 共享结论，不重复清会话（场景 5 断言 clearSession 调用 == 1）。
  Future<RefreshVerdict> _runRefreshAsLeader() async {
    try {
      final result = await _refreshExecutor();
      return switch (result) {
        RefreshSuccess() => const RefreshSuccessVerdict(),
        RefreshStale() => const RefreshStaleVerdict(),
      };
    } on ApiException catch (apiError) {
      return _classifyAndClearOnAuthFailure(apiError);
    } on DioException catch (dioError) {
      // 传输层失败（连接/读超时/连接拒绝等）：不清会话，按瞬时失败透传；
      // 包成 networkFailure 的 ApiException 统一挂起请求的异常形态，
      // U6 上线后其 autoRetry 行为由错误码行为表驱动（场景 7）。
      // 若内层是信封分流的 ApiException（unknown 型 DioException），
      // 仍须走完整分类（认证类要清会话）。
      final inner = dioError.error;
      if (inner is ApiException) {
        return _classifyAndClearOnAuthFailure(inner);
      }
      return RefreshTransientVerdict(
        refreshError: ApiException(
          code: ApiErrorCode.networkFailure,
          message: '续期请求网络失败（${dioError.type.name}），不清会话',
        ),
      );
    } on Object catch (error) {
      // 执行器内部未知错误（含 parseError 等非 DioException 抛出）：
      // 不清会话、原样透传异常信息，绝不误清登录态（弱网不踢人）。
      return RefreshTransientVerdict(
        refreshError: error is ApiException
            ? error
            : ApiException.parse('续期执行失败：$error'),
      );
    }
  }

  /// 分类续期业务异常，并在认证类失败时由 leader 唯一一次清会话（R10）。
  ///
  /// 清会话异常收敛（评审 #4）：[verdict] 在调用 [_clearSession] **之前**
  /// 已分类落定，清会话是认证失败后的副作用而非判定输入；其回调将来要接
  /// `POST /auth/logout` 与持久化清理（皆可失败 I/O）。一旦抛出，本方法
  /// 运行在 [_runRefreshAsLeader] 的 `on ApiException` catch 中，async 下
  /// `return` 一个会抛错的 Future 不会被同一 catch 再捕获，会击穿
  /// [_joinOrStartRefresh]「leader Future 永不抛、无 unhandled」红线，还会
  /// 把挂起请求的 40101 替换成清理异常。故清会话失败只吞错、不改判（会话
  /// 是否真清干净由 UI watch / 下次请求的 40101 兜底），裁决与单飞复位
  /// 都不受影响。
  ///
  /// 参数：[apiError] 续期响应信封解析出的业务异常。
  /// 返回：[RefreshVerdict] 分流结论（与清会话成功与否无关）。
  Future<RefreshVerdict> _classifyAndClearOnAuthFailure(
    ApiException apiError,
  ) async {
    final verdict = _classifyRefreshApiError(apiError);
    if (verdict is RefreshAuthFailedVerdict) {
      // 认证类失败（旧 Token 已不可续期）：清空本地会话，UI 侧 watch
      // 会话态跳登录。仅 leader 走到本方法（挂起方只 await 结论），
      // 故全客户端调用次数恒为 1（场景 5）。
      try {
        await _clearSession();
      } on Object {
        // 见方法注释（评审 #4）：清会话是失败后的副作用，抛错不改变认证
        // 裁决，也不得逃逸为 leader 共享 Future 的异常（红线）。R16：此处
        // 不落任何日志（错误对象可能含持久化实现细节），吞错即「按已尽力
        // 清理」处理，后续 40101 会再次驱动收敛。
      }
    }
    return verdict;
  }

  /// 按错误码把续期自身的 [ApiException] 归入三（四）分流（R10）。
  ///
  /// 判定只引用 [ApiErrorCode] 既有枚举、其 [ApiErrorCode.behavior] 行为表
  /// 与「码对齐 HTTP（code ~/ 100）」不变量，禁止自造码表（编码规范
  /// §3.2）；与 RetryInterceptor 唯一重试判定同源（评审 #13，不再另写
  /// `httpClass == 500` 段算术而漏掉 50301/50302/50303）：
  ///   - 401 段（含 40101）/403 段：认证类失败 → 清会话；
  ///   - 429 段：限流 → 不清会话，带 retryAfterSec 透传；
  ///   - 行为表 [ErrBehavior.autoRetry] 集合（50001/50301/50302/50303 与
  ///     本地 networkFailure(-1)）：瞬时失败 → 不清会话，归一为
  ///     networkFailure 供 RetryInterceptor 行为表驱动重试；
  ///   - 其余（40001/409xx/41001/parseError 等确定性失败）：不清会话，
  ///     原样透传 refresh 的异常。
  ///
  /// 参数：[apiError] 续期响应信封解析出的业务异常。
  /// 返回：[RefreshVerdict] 分流结论。
  RefreshVerdict _classifyRefreshApiError(ApiException apiError) {
    final code = apiError.code.code;
    final httpClass = code ~/ 100;
    if (code == ApiErrorCode.unauthorized.code || httpClass == 403) {
      return RefreshAuthFailedVerdict(refreshError: apiError);
    }
    if (httpClass == 429) {
      return RefreshRateLimitedVerdict(refreshError: apiError);
    }
    if (apiError.code.behavior == ErrBehavior.autoRetry) {
      return RefreshTransientVerdict(
        refreshError: ApiException(
          code: ApiErrorCode.networkFailure,
          message: '续期服务暂不可用（业务码 $code），不清会话',
          retryAfterSec: apiError.retryAfterSec,
        ),
      );
    }
    return RefreshTransientVerdict(refreshError: apiError);
  }

  /// 续期成功后用 `dio.fetch` 重放原始请求（KTD4）。
  ///
  /// 为什么必须 dio.fetch 重走全链而非重调拦截器回调：
  ///   - HeaderInterceptor 位于链首，重放经过它时会用**新 Token**
  ///     重写 Authorization（每次重写），而 X-Interaction-Id/
  ///     Idempotency-Key/X-Device-Id 已存在于 headers，containsKey
  ///     判定为真，逐字沿用——两键保全是链路语义，不靠本类复制头；
  ///   - EnvelopeInterceptor/GzipInterceptor 同样重新生效，重放响应
  ///     与首发响应经过完全相同的解包路径，调用方拿到的形态一致。
  ///
  /// 重放在 extra 增加两个标记：已续期（[authRetriedExtraKey]，防重放仍
  /// 40101 时二次续期）与重放调度（[authReplayDispatchExtraKey]，告知
  /// 重放链上的 RetryInterceptor「预算已由首发链外层持有，不得自开循环」，
  /// 评审 #1）；不改写 headers map、不改 query/data/方法/路径（场景 2/3）。
  ///
  /// 参数：
  ///   [options] 原始请求配置（40101 错误携带的同一对象）；
  ///   [handler] 成功 resolve 重放响应；重放再失败则 reject 给链尾。
  /// 返回：[Future<void>]。
  Future<void> _replay(
    RequestOptions options,
    ErrorInterceptorHandler handler,
  ) async {
    final replayExtra = Map<String, dynamic>.of(options.extra)
      ..[authRetriedExtraKey] = true
      ..[authReplayDispatchExtraKey] = true;
    final replayOptions = options.copyWith(extra: replayExtra);
    try {
      // fetch 从链首重走全部拦截器（KTD4）；CancelToken 沿用原对象，
      // 取消语义对重放同样生效。
      final response = await _networkDio.fetch<Object?>(replayOptions);
      // ErrorInterceptorHandler.resolve 无第二参（dio 5.11.1）：直接以
      // 重放响应完成原始请求，后续 error 拦截器（U6 Retry）自然不再介入。
      handler.resolve(response);
    } on DioException catch (replayError) {
      // 重放失败（含重放仍 40101）：auth_retried 已在 extra 中，若错误再
      // 流到本拦截器会走「已重放」分支直接失败，不二次续期。交还链尾前
      // 必须剥离 auth_replay_dispatch 标记：该标记只用于抑制**重放链内**
      // Retry 的自开循环；剥离后首发链 Retry 见到的是普通 autoRetry 失败，
      // 由其外层唯一循环按全链路 2 次预算计数重试（评审 #1）。
      handler.reject(_stripReplayDispatchMarker(replayError), true);
    }
  }

  /// 把重放链抛出的错误还原为「普通已续期重放失败」形态：保留
  /// [authRetriedExtraKey]（防二次续期）与计数等其余 extra，仅剔除
  /// [authReplayDispatchExtraKey]（评审 #1，与 RetryInterceptor 剥离自身
  /// inner 标记同构）。
  ///
  /// 参数：[replayError] 重放 fetch 抛出（并经重放链拦截器 reject）的错误。
  /// 返回：[DioException] 携带剥离后请求配置的同类错误；原本无标记则原样返回。
  DioException _stripReplayDispatchMarker(DioException replayError) {
    final replayOptions = replayError.requestOptions;
    if (!replayOptions.extra.containsKey(authReplayDispatchExtraKey)) {
      return replayError;
    }
    final outerExtra = Map<String, dynamic>.of(replayOptions.extra)
      ..remove(authReplayDispatchExtraKey);
    return DioException(
      requestOptions: replayOptions.copyWith(extra: outerExtra),
      response: replayError.response,
      type: replayError.type,
      error: replayError.error,
      stackTrace: replayError.stackTrace,
    );
  }

  /// 以 [ApiException] 构造 reject 用的 [DioException]（与
  /// EnvelopeInterceptor 的 reject 形态同构：type=unknown、
  /// error=ApiException、callFollowingError=true，KTD2）。
  ///
  /// 参数：
  ///   [options]    对应请求配置；
  ///   [apiError]   要落给调用方的业务异常。
  /// 返回：[DioException] 包装异常。
  DioException _wrapApiException(
    RequestOptions options,
    ApiException apiError,
  ) {
    return DioException(
      requestOptions: options,
      type: DioExceptionType.unknown,
      error: apiError,
    );
  }

  /// 瞬时失败分流的 reject 异常构造（语义同 [_wrapApiException]，单列
  /// 命名以便阅读分流分支；网络/5xx 异常同样以 ApiException 承载）。
  ///
  /// 参数：
  ///   [options]      对应请求配置；
  ///   [refreshError] 续期链路归一后的业务异常。
  /// 返回：[DioException] 包装异常。
  DioException _refreshFailure(
    RequestOptions options,
    ApiException refreshError,
  ) =>
      _wrapApiException(options, refreshError);
}

/// 单飞续期的内部分流结论（执行器结果 + 异常分类后的统一形态）。
sealed class RefreshVerdict {
  /// 构造结论基类（仅子类使用）。
  const RefreshVerdict();
}

/// 续期成功：挂起请求可重放。
class RefreshSuccessVerdict extends RefreshVerdict {
  /// 构造成功结论。
  const RefreshSuccessVerdict();
}

/// 认证类失败（refresh 自身 40101/403xx）：会话已清空，挂起请求以
/// 各自原始 40101 失败、不重放。
class RefreshAuthFailedVerdict extends RefreshVerdict {
  /// 构造认证失败结论。
  ///
  /// 参数：[refreshError] 续期响应的认证类异常（仅诊断用，挂起请求
  /// 保留各自原始异常）。
  const RefreshAuthFailedVerdict({required this.refreshError});

  /// 续期响应的认证类异常。
  final ApiException refreshError;
}

/// 429 段失败：不清会话，挂起请求以带 retryAfterSec 的异常失败。
class RefreshRateLimitedVerdict extends RefreshVerdict {
  /// 构造限流结论。
  ///
  /// 参数：[refreshError] 续期响应的 429 段异常（携 Retry-After 秒数）。
  const RefreshRateLimitedVerdict({required this.refreshError});

  /// 续期响应的 429 段异常。
  final ApiException refreshError;
}

/// 瞬时失败（网络失败/5xx/其他透传异常）：不清会话、不重放。
class RefreshTransientVerdict extends RefreshVerdict {
  /// 构造瞬时失败结论。
  ///
  /// 参数：[refreshError] 续期链路的失败异常（网络类已归一为
  /// [ApiErrorCode.networkFailure]）。
  const RefreshTransientVerdict({required this.refreshError});

  /// 续期链路的失败异常。
  final ApiException refreshError;
}

/// 代次变更：续期在途期间会话登出/换号，结果丢弃，挂起请求按清会话
/// 语义以原 40101 失败。
class RefreshStaleVerdict extends RefreshVerdict {
  /// 构造代次变更结论。
  const RefreshStaleVerdict();
}
