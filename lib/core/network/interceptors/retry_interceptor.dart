/// 全链路唯一自动重试拦截器（详细设计 §14 / §11.1 链序第 5 位 / §12.2，
/// 编码规范 §1.3 唯一重试点 / §5.5，计划 U6：R6/R9/R11/R14/R16、KTD4/KTD10）。
///
/// 职责边界（编码规范 §1.2：本类是 `lib/features/` 之外的全局唯一重试点，
/// 业务代码禁写 `for` 循环重试）：
///   - 仅按 [ErrBehavior.autoRetry] 行为表驱动重试，真实码集合由
///     [ApiErrorCode.behavior] 唯一决定（50001/50301/50302/50303 +
///     本地 networkFailure(-1)），本类不复制码表、不写码值特例分支；
///   - 全链路总共 [NfrNetwork.retryMaxCount] 次（首发之外 2 次），退避
///     基数 [NfrNetwork.backoffFirstSec]/[NfrNetwork.backoffSecondSec]，
///     ±[NfrNetwork.retryJitterPercent] 抖动；服务端整数秒 `Retry-After`
///     优先于退避表且**不叠加抖动**（详设 §14.1 末行：服务端给了秒数
///     就用服务端的；整数秒是服务端指令语义，抖动只服务于退避表的削峰）；
///   - 纯传输层 [DioException]（连接/接收超时、连接拒绝等非信封错误，
///     且非 cancel）在本类 onError —— 链尾归一点 —— 统一包装为
///     [ApiErrorCode.networkFailure]（KTD10），cancel 裸穿透；
///   - 重试**不生成任何 UUID**：重放走 `dio.fetch` 重走全链（KTD4），
///     X-Interaction-Id / Idempotency-Key 已在 headers 中，
///     HeaderInterceptor「containsKey 才写」逐字沿用（详设 §11.1.1）。
///     构造仍声明 `newUuidV4` 入参（装配侧透传 hooks.newUuidV4），但
///     刻意不保存、全程不调用（U6 测试据此断言 uuid 工厂计数 == 0/1）。
///
/// ── 设计推演：a/b 两种写法的抉择与嵌套终止原理 ──
/// dio 的 `dio.fetch(options)` 会从链首重走**全部**拦截器，故重放请求若
/// 再次失败，错误会**重新进入本拦截器的 onError**——若不加区分地继续
/// `fetch`，将形成无限递归（每次嵌套还会再 sleep，预算永远花不完）。
/// 任务书给出两种合理写法：
///   (a) 外层 onError 持有「for 重试循环」，对内层 fetch 打标记，内层
///       onError 见标记立即把错误抛回外层 await，由外层单点决定下一次
///       重试/耗尽拒绝；
///   (b) 无显式循环，全靠 onError 自递归（每次重放 count+1，内层 onError
///       自己判定是否再 fetch），用 count 到顶终止。
/// 本实现选 **(a)**：循环与计数状态集中在外层一个方法内，「何时 sleep、
/// 何时 fetch、何时耗尽拒绝」线性可读；(b) 的重试控制分散在递归栈每一
/// 层，耗尽时深层 onError 的 reject 是否必然冒泡为最外层调用方错误，依赖
/// dio callFollowingError 链路的多层语义，推理与排障成本更高。
///
/// 嵌套如何终止（KTD4，由场景 2/2b/8 机器证明）：
///   - 外层首发请求的 extra 不含 [retryInnerDispatchExtraKey]，进入
///     [_runOuterRetryLoop]；每次重放用 `copyWith(extra: …)` 把
///     [retryInnerDispatchExtraKey]=true 与递增后的
///     [retryAttemptCountExtraKey] 一并置入；
///   - 重放错误再入 onError 时凭 inner 标记**立即** `handler.reject(err,
///     true)`：该 reject 在外层 `await _networkDio.fetch` 处表现为抛出，
///     被外层循环的 catch 捕获，内层**绝不 sleep、绝不二次 fetch**；
///   - 外层循环以 `attempt`（1..retryMaxCount）为硬上界：sleep→fetch→
///     catch→再判定，attempt 到顶后构造终局错误一次性拒绝，不再有调度；
///   - 故无续期重放时全链路请求数恒为 1 + retryMaxCount（持续失败恰 3
///     次），嵌套栈深有界（最深 = retryMaxCount 层），无第四次请求、无
///     无限递归。
///
/// 续期重放为何是第三种标记（评审 #1，§14.1 全链路 2 次硬口径）：
/// AuthRefreshInterceptor 续期成功后也用 `dio.fetch` 重放原始请求，那是
/// 又一条全新拦截器链；其末端本类的 onError 是**同拦截器的另一次调用**，
/// 局部 attempt 从 0 起，且重放 options 不带本类 [retryInnerDispatchExtraKey]
/// （那是 Retry 自己 fetch 才置的标记）。若不加区分地自开外层循环，重放
/// 失败先花一份预算、错误冒泡回首发链 onError 再开一份，最坏放大为
/// 1 + 1 + 2 + 2×3 = 10 个业务请求。故约定：
///   - 重放 options 置 [AuthRefreshInterceptor.authReplayDispatchExtraKey]；
///   - 重放链上的本次 onError 见该标记**不自开循环**，直接 next 把错误
///     抛回 AuthRefresh 的 `await fetch`；
///   - AuthRefresh catch 剥离该标记后 reject 回**首发链**，首发链本次
///     onError 见不到标记，按唯一外层循环计数。
/// 故「refresh 成功 + 重放持续失败」时请求数恒为 1 首发 + 1 重放 +
/// retryMaxCount 次外层重试（恰 4 次），sleep 仅由首发链外层发出 2 次。
///
/// R16 日志白名单：本文件不产生任何日志输出（无标准/调试打印、无 dio
/// 日志拦截器、无 developer 日志调用）；不读取请求头与请求（响应）体
/// （token/body 不得入诊断信息，编码规范 §4.11/§5.9）；归一诊断
/// message 只允许出现 [DioExceptionType.name] 与请求路径 path。
library;

import 'package:dio/dio.dart';

import '../../../nfr_constants.dart';
import '../api_error_code.dart';
import '../api_exception.dart';
import 'auth_refresh_interceptor.dart';

/// 全链路唯一自动重试拦截器（链序第 5 位）。
class RetryInterceptor extends Interceptor {
  /// 构造重试拦截器。
  ///
  /// 参数：
  ///   [networkDio]  业务 dio 自引用：重放经 `networkDio.fetch` 从链首
  ///                 重走全部拦截器（KTD4）；注入而非从 RequestOptions
  ///                 反取，因 dio 5.11.1 的 RequestOptions 不持有所属 dio
  ///                 （与 [AuthRefreshInterceptor] 同构）；
  ///   [newUuidV4]   UUID v4 生成器。**刻意注入但本类全程不调用、不保存**
  ///                 ——两键保全由 HeaderInterceptor「containsKey 才写」在
  ///                 重放链路上逐字沿用（§11.1.1）；保留此构造参数是任务
  ///                 契约的一部分：装配侧透传 hooks.newUuidV4，使「重试
  ///                 不换号」断言有明确的对称计数对象（测试断言其全程
  ///                 调用次数不增加），并为后续扩展预留同构缝；
  ///   [sleeper]     退避等待缝：生产用 [Future.delayed]，测试注入即时
  ///                 记录型等待（禁止真睡 1–2 秒，flaky 零容忍）；
  ///   [randomRatio] 抖动比例缝：生产 `Random().nextDouble`（[0,1)），
  ///                 测试注入固定比例使退避时长确定可断言。
  // ignore: avoid_unused_constructor_parameters
  RetryInterceptor({
    required Dio networkDio,
    required String Function() newUuidV4,
    required Future<void> Function(Duration duration) sleeper,
    required double Function() randomRatio,
  })  : _networkDio = networkDio,
        // newUuidV4 刻意不赋值给任何字段：本类不持有、不调用（重放不得
        // 换号，详设 §11.1.1），仅作为装配契约入参与测试计数对象存在。
        _sleeper = sleeper,
        _randomRatio = randomRatio;

  /// 业务 dio（重放走其 fetch，从链首重经全部拦截器，KTD4）。
  final Dio _networkDio;

  /// 退避等待缝（生产 Future.delayed，测试即时记录）。
  final Future<void> Function(Duration duration) _sleeper;

  /// 抖动比例缝（[0,1)，生产 Random().nextDouble）。
  final double Function() _randomRatio;

  /// RequestOptions.extra 中「本请求已发生的重试次数」键（首发为 0，
  /// 每次重放 +1，到 [NfrNetwork.retryMaxCount] 由外层归一拒绝，KTD4）。
  static const String retryAttemptCountExtraKey = 'retry_attempt_count';

  /// RequestOptions.extra 中「本错误来自本拦截器自身发起的内层 fetch」
  /// 标记键。内层 onError 凭它立即把错误抛回外层 await，不二次调度；
  /// 该键仅存活于重放 options，落调用方的终局错误 extra 必剔除它。
  static const String retryInnerDispatchExtraKey = 'retry_inner_dispatch';

  /// 错误方向链尾收口（详设 §11.1：本拦截器位于 error 向最后一棒）。
  ///
  /// 参数：
  ///   [err]     上游（Envelope/AuthRefresh 或 dio 传输层）传来的错误；
  ///   [handler] 重试成功调 resolve，内层错误/耗尽/不重试分流调
  ///             reject/next。
  /// 返回：[Future<void>]（等待与重放均为异步）。
  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    // ① cancel 是显式例外（KTD10）：被取消的请求不计数、不重试、不穿
    //    ApiException 外衣，裸 DioExceptionType.cancel 穿透到调用方。
    //    必须先于 inner 判定：退避期间取消产生的内层 cancel 也要以裸
    //    cancel 形态落调用方，而非被当作「内层重放失败」继续循环。
    if (err.type == DioExceptionType.cancel) {
      handler.next(err);
      return;
    }

    final options = err.requestOptions;

    // ② 内层终止（KTD4）：本错误来自本拦截器自身发起的 dio.fetch。
    //    立即沿 error 链拒绝，外层 await fetch 处将以抛出接住；内层
    //    不 sleep、不 fetch，重试决策只存在于外层循环一处。
    if (options.extra[retryInnerDispatchExtraKey] == true) {
      handler.reject(err, true);
      return;
    }

    // ②b 续期重放不自开预算（评审 #1）：本错误来自 AuthRefreshInterceptor
    //    续期成功后经 dio.fetch 发起的重放（见其 authReplayDispatchExtraKey
    //    注释：dio.fetch 重走全链，本次 onError 是同拦截器的另一次调用，
    //    局部计数从 0 起）。此处若自开 _runOuterRetryLoop，会与首发链外层
    //    循环形成嵌套预算，最坏放大为 10 个请求（§14.1 全链路 2 次被击穿）。
    //    故重放链不 sleep、不 fetch，直接把错误沿 error 链抛出——本类是
    //    重放链最后一个 error 拦截器，错误在 AuthRefreshInterceptor._replay
    //    的 await fetch 处被接住，其 catch 剥离 auth_replay_dispatch 标记后
    //    reject 回**首发链**；首发链本次 onError 见不到该标记，按下方 ④
    //    正常进入唯一外层循环计数。
    if (options.extra[AuthRefreshInterceptor.authReplayDispatchExtraKey] ==
        true) {
      handler.next(err);
      return;
    }

    // ③ 链尾唯一归一点（KTD10）：非 ApiException 的纯传输层 DioException
    //    （超时/连接拒绝/connectionError 等）包装为 networkFailure；
    //    已是 ApiException 的（信封业务错误、U5 归一后的 refresh 瞬时
    //    失败）原样取，绝不二次包装、不丢 requestId/retryAfterSec。
    final ApiException apiError = _apiErrorFrom(err);

    // ④ 行为表驱动：仅 autoRetry 才重试；其余（限流提示/强制重取/
    //    确定性失败/续期分流等）一律原样放行，本拦截器零介入。
    if (apiError.code.behavior != ErrBehavior.autoRetry) {
      handler.next(err);
      return;
    }

    await _runOuterRetryLoop(
      firstError: apiError,
      options: options,
      handler: handler,
    );
  }

  /// 外层重试循环：方案 (a) 的唯一调度点（sleep→fetch→catch 线性推进）。
  ///
  /// 参数：
  ///   [firstError] 首发失败归一后的业务异常（决定首次等待的 Retry-After）；
  ///   [options]    首发请求配置（计数键首发为 0）；
  ///   [handler]    首发 onError 的处理器（成功 resolve / 耗尽 reject）。
  /// 返回：[Future<void>]。
  Future<void> _runOuterRetryLoop({
    required ApiException firstError,
    required RequestOptions options,
    required ErrorInterceptorHandler handler,
  }) async {
    var currentOptions = options;
    var lastError = firstError;
    var attempt = 0;
    while (attempt < NfrNetwork.retryMaxCount) {
      attempt += 1;
      // ⑤ 等待：Retry-After 整数秒优先且不抖动；否则按退避表 + 抖动。
      await _sleeper(_delayBeforeAttempt(attempt, lastError.retryAfterSec));

      final nextCount = _readAttemptCount(currentOptions) + 1;
      final replayOptions = _buildReplayOptions(currentOptions, nextCount);
      try {
        // 重放走全链（KTD4）：Header 重写 Authorization、两键 containsKey
        // 才写逐字沿用；Envelope 重新拆信封。重放响应即首发响应形态。
        final response = await _networkDio.fetch<Object?>(replayOptions);
        handler.resolve(response);
        return;
      } on DioException catch (replayError) {
        // 退避期间取消 / 重放被取消：cancel 已在再入 onError 时裸穿透
        // 到此处（内层 reject），以裸 cancel 落调用方，不继续重试。
        if (replayError.type == DioExceptionType.cancel) {
          handler.reject(_asOuterError(replayError), true);
          return;
        }
        final normalized = _apiErrorFrom(replayError);
        // 非可重试行为（如重放收到 429/40903/parseError）：立即以该
        // 错误落调用方，不花完剩余预算——重试只会复现确定性失败。
        if (normalized.code.behavior != ErrBehavior.autoRetry) {
          handler.reject(_asOuterError(replayError), true);
          return;
        }
        lastError = normalized;
        currentOptions = replayOptions;
      }
    }

    // ⑥ 耗尽：全链路 1 + retryMaxCount 次后仍失败，按 §12.2 降级为
    //    确定性 networkFailure 提示（计划 U6 场景 2 明文）；终局 options
    //    保留计数到顶、剔除内层标记（调用方看到的是外层请求形态）。
    handler.reject(
      _buildTerminalError(
        options: currentOptions,
        attemptCount: NfrNetwork.retryMaxCount,
        lastError: lastError,
      ),
      true,
    );
  }

  /// 计算第 [attempt] 次重试（1 起）前的等待时长。
  ///
  /// 参数：
  ///   [attempt]          重试序号（1 = backoffFirst，2 = backoffSecond）；
  ///   [retryAfterSecond] 上游异常携带的服务端 Retry-After 整数秒。
  /// 返回：[Duration]：[retryAfterSecond] 非空（含 0 = 服务端要求立即
  ///   重试）时精确使用整数秒、不抖动；否则退避基数 × (1 ± 抖动比例)，
  ///   毫秒向下取整（详设 §14.1，公式与测试期望同源，不复制字面量）。
  Duration _delayBeforeAttempt(int attempt, int? retryAfterSecond) {
    if (retryAfterSecond != null) {
      return Duration(seconds: retryAfterSecond);
    }
    final baseSec = attempt == 1
        ? NfrNetwork.backoffFirstSec
        : NfrNetwork.backoffSecondSec;
    final ratio = _randomRatio();
    final factor =
        1 + (ratio * 2 - 1) * NfrNetwork.retryJitterPercent / 100;
    return Duration(milliseconds: (baseSec * 1000 * factor).floor());
  }

  /// 构造重放请求配置：计数 +1、置入内层调度标记，其余逐字沿用
  /// （请求头、查询串、请求体、方法、路径均由 [RequestOptions.copyWith]
  /// 原样保留；本拦截器不读取也不改写其中任何一项，R16）。
  ///
  /// 参数：
  ///   [options]   上一轮请求配置；
  ///   [nextCount] 本轮重试计数（1..retryMaxCount）。
  /// 返回：[RequestOptions] 重放专用配置。
  RequestOptions _buildReplayOptions(RequestOptions options, int nextCount) {
    final replayExtra = Map<String, dynamic>.of(options.extra)
      ..[retryAttemptCountExtraKey] = nextCount
      ..[retryInnerDispatchExtraKey] = true;
    return options.copyWith(extra: replayExtra);
  }

  /// 读取请求已发生的重试计数（首发无键视为 0）。
  ///
  /// 参数：[options] 请求配置。
  /// 返回：[int] extra 中的计数值；缺失/非 int 均按 0 处理（首发形态）。
  int _readAttemptCount(RequestOptions options) {
    final value = options.extra[retryAttemptCountExtraKey];
    return value is int ? value : 0;
  }

  /// 把内层 fetch 抛出的错误还原为外层形态：保留计数、剔除内层标记，
  /// 使落调用方的错误 extra 不含 [retryInnerDispatchExtraKey]（场景 8）。
  ///
  /// 参数：[innerError] 内层 fetch 抛出（并经内层 onError reject）的错误。
  /// 返回：[DioException] 携带外层形态 requestOptions 的同类错误。
  DioException _asOuterError(DioException innerError) {
    final outerOptions = _stripInnerMarker(innerError.requestOptions);
    return DioException(
      requestOptions: outerOptions,
      response: innerError.response,
      type: innerError.type,
      error: innerError.error,
      stackTrace: innerError.stackTrace,
    );
  }

  /// 构造重试耗尽的终局错误（计划 U6 场景 2）。
  ///
  /// 诊断文案除「已耗尽」语义外，逐字附上末次失败的 message：末次为非
  /// 信封 5xx（如网关 HTML 502）或纯传输错误时，上游诊断信息（HTTP
  /// 状态码、传输错误类型，见 EnvelopeInterceptor 非信封分流与
  /// [_wrapTransportError]）必须保留到调用方，否则调用方无法区分
  /// 502/503/504 或超时/连接拒绝；末次 message 只可能来自信封
  /// `message`（服务端用户可见文案）或本链两处诊断构造，均不含头/体
  /// （R16），故直接拼接不引入泄露面。
  ///
  /// 参数：
  ///   [options]      最后一轮请求配置（计数已到顶）；
  ///   [attemptCount] 终局计数（= [NfrNetwork.retryMaxCount]）；
  ///   [lastError]    最后一次失败的业务异常（取其码名与诊断 message）。
  /// 返回：[DioException] type=unknown、error=ApiException(networkFailure)，
  ///   requestOptions.extra 计数到顶且无内层标记。
  DioException _buildTerminalError({
    required RequestOptions options,
    required int attemptCount,
    required ApiException lastError,
  }) {
    final terminalExtra = Map<String, dynamic>.of(options.extra)
      ..[retryAttemptCountExtraKey] = attemptCount
      ..remove(retryInnerDispatchExtraKey);
    final terminalOptions = options.copyWith(extra: terminalExtra);
    return DioException(
      requestOptions: terminalOptions,
      type: DioExceptionType.unknown,
      error: ApiException(
        code: ApiErrorCode.networkFailure,
        message: '自动重试已达上限（共 $attemptCount 次），'
            '末次失败形态 ${lastError.code.name}：${lastError.message}',
      ),
    );
  }

  /// 复制一份剔除内层调度标记的请求配置（计数等其余 extra 原样保留）。
  ///
  /// 参数：[options] 可能携带内层标记的请求配置。
  /// 返回：[RequestOptions] 不含 [retryInnerDispatchExtraKey] 的配置。
  RequestOptions _stripInnerMarker(RequestOptions options) {
    if (!options.extra.containsKey(retryInnerDispatchExtraKey)) {
      return options;
    }
    final outerExtra = Map<String, dynamic>.of(options.extra)
      ..remove(retryInnerDispatchExtraKey);
    return options.copyWith(extra: outerExtra);
  }

  /// 从 [DioException.error] 载体取出业务异常；非 [ApiException] 载体
  /// （纯传输层超时/连接拒绝等）归一为 networkFailure（KTD10）。
  ///
  /// 已是 ApiException 的（信封业务错误、U5 归一后的 refresh 瞬时失败）
  /// 原样返回，绝不二次包装、不丢 requestId/retryAfterSec。onError 与
  /// 外层循环 catch 共用本方法（评审 #6：carrier 归一只此一处）。
  ///
  /// 参数：[err] 上游或重放 fetch 抛出的 DioException。
  /// 返回：[ApiException] 原样业务异常或 networkFailure 形态异常。
  ApiException _apiErrorFrom(DioException err) {
    final Object? carrier = err.error;
    return carrier is ApiException ? carrier : _wrapTransportError(err);
  }

  /// 纯传输层错误归一为 networkFailure（KTD10 链尾唯一归一点）。
  ///
  /// 诊断 message 只允许出现传输错误类型名与请求路径（R16：不含头/体）。
  ///
  /// 参数：[err] 非 ApiException 承载的 DioException（超时/连接拒绝等）。
  /// 返回：[ApiException] networkFailure 形态异常。
  ApiException _wrapTransportError(DioException err) {
    return ApiException(
      code: ApiErrorCode.networkFailure,
      message: '网络传输失败（${err.type.name}），请求路径 '
          '${err.requestOptions.path}',
    );
  }
}
