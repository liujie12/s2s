/// 请求头注入拦截器（详细设计 §11.1 链序第 1 位 / §11.1.1 / §11.2，
/// 计划 R7）。
///
/// 四条注入纪律（§11.2 表格 + §11.1.1 修正结论）：
///   1. `Authorization` 是**唯一每次重写**的头：续期重放（§13）必须带新
///      Token，若走「缺失才写」，重放会带着失效旧 Token 再吃一次 40101
///      形成死循环；未登录时**不注入该头**（连空串都不写，否则服务端要
///      多判一种非法态）；
///   2. `X-Interaction-Id` / `X-Device-Id` / `Idempotency-Key` 三头一律
///      **containsKey 才写**，绝不覆盖调用方透传值。重试经
///      `dio.fetch(requestOptions)` 会重走完整 onRequest 链（§11.1.1），
///      只有显式判存在性才能在两种 dio 行为下都保全首次生成的两键；
///   3. `Idempotency-Key` 仅写接口（POST/PATCH）注入，GET 不注入；
///   4. 隐私同意态是硬门（PRD §6.5.1 / 计划 R7）：同意态经构造回调
///      **每次请求实时读取**，同意前即使设备 ID 已生成也不注入
///      `X-Device-Id`——不依赖「首个请求必在同意之后」的时序假设。
///
/// 唯一例外（§11.1.1）：`POST /track/events` 埋点批次每次组批须换新两键，
/// 由 TrackReporter 自行显式带头，containsKey 语义自然不覆盖；该例外写在
/// TrackReporter 类注释中，不在本拦截器特判。
library;

import 'package:dio/dio.dart';

import '../api_client.dart';

/// 请求头注入拦截器。
class HeaderInterceptor extends Interceptor {
  /// 构造请求头拦截器。
  ///
  /// 参数：[hooks] 会话/隐私/设备标识/UUID 的回调集（core 不感知
  /// Riverpod，计划 KTD5）。
  HeaderInterceptor(this._hooks);

  /// 全部可变依赖经回调注入（token 读取为异步，设备 ID 与同意态实时读）。
  final NetworkHooks _hooks;

  /// 交互 ID 请求头名（§11.2）。全工程三头键名的唯一字面量真源
  /// （计划 Assumptions：headers map 到达 adapter 前大小写敏感）。
  static const String interactionIdHeader = 'X-Interaction-Id';

  /// 设备标识请求头名（§11.2）。
  static const String deviceIdHeader = 'X-Device-Id';

  /// 幂等键请求头名（§11.2 / 契约 components/parameters/IdempotencyKey）。
  static const String idempotencyKeyHeader = 'Idempotency-Key';

  /// 鉴权请求头名（§11.2）。
  static const String authorizationHeader = 'Authorization';

  /// 鉴权头值前缀（`Bearer <JWT>` 形态）。
  static const String _bearerPrefix = 'Bearer ';

  /// 发出方向：按 §11.2 四条纪律注入请求头后放行。
  ///
  /// 参数：
  ///   [options] 本次请求配置（headers 已含调用方透传值，拦截器只补缺）；
  ///   [handler] dio 拦截器处理器，注入完成后调用 `handler.next`。
  /// 返回：[void]（异步）；不抛业务异常，任何注入失败不应阻断请求
  ///   （token/设备 ID 读取异常按「未取得」处理，纪律上宁可不注入）。
  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    await _rewriteAuthorization(options);
    _ensureInteractionId(options);
    await _injectDeviceIdIfConsented(options);
    _injectIdempotencyKeyForWrite(options);
    handler.next(options);
  }

  /// 每次重写 `Authorization`（§11.2 唯一例外项）。
  ///
  /// 为什么先 remove 再按最新 Token 写：dio 的 BaseOptions.headers 会与
  /// 单请求 headers 合并，残留旧值时续期重放会带旧 Token。未登录
  /// （token 为 null 或空串）时保持键不存在，不写空串。
  ///
  /// 参数：[options] 本次请求配置。
  /// 返回：[Future<void>]，完成后头与当前登录态严格一致。
  Future<void> _rewriteAuthorization(RequestOptions options) async {
    final headers = options.headers;
    headers.remove(authorizationHeader);
    final token = await _hooks.readToken();
    if (token != null && token.isNotEmpty) {
      headers[authorizationHeader] = '$_bearerPrefix$token';
    }
  }

  /// 缺失时兜底补 `X-Interaction-Id`（§11.2：交互起点生成、逐层透传，
  /// 拦截器仅在缺失时补，不覆盖已透传值）。
  ///
  /// 兜底而不强制生成的原因：方法参数透传是主路径（不用 Zone/全局变量，
  /// 并发交互下全局变量会串号，§11.2）；拦截器只保证「无 ID 不出网」。
  ///
  /// 参数：[options] 本次请求配置。
  /// 返回：void；已有该头时逐字保留，缺失时写入新 UUID v4。
  void _ensureInteractionId(RequestOptions options) {
    final headers = options.headers;
    if (headers.containsKey(interactionIdHeader)) return;
    headers[interactionIdHeader] = _hooks.newUuidV4();
  }

  /// 同意隐私协议且设备 ID 可读时注入 `X-Device-Id`（§11.2 / PRD §6.5.1）。
  ///
  /// 硬门不靠时序（计划 Assumptions）：即使设备 ID 已在本地生成，同意态
  /// 回调为 false 也绝不外发。先读同意态再读设备 ID，避免未同意场景下
  /// 无谓触发设备 ID 的惰性生成/读盘。
  ///
  /// 参数：[options] 本次请求配置。
  /// 返回：[Future<void>]。
  Future<void> _injectDeviceIdIfConsented(RequestOptions options) async {
    final headers = options.headers;
    if (headers.containsKey(deviceIdHeader)) return;
    final consented = await _hooks.readPrivacyConsented();
    if (!consented) return;
    final deviceId = await _hooks.readDeviceId();
    if (deviceId != null && deviceId.isNotEmpty) {
      headers[deviceIdHeader] = deviceId;
    }
  }

  /// 写接口（POST/PATCH）缺失时注入 `Idempotency-Key`（§11.2）。
  ///
  /// GET 不注入：读请求无写副作用，不需要服务端 SETNX 幂等占位
  /// （详设 §3.3）。已存在即视为透传或重试路径，逐字保留——
  /// 重试时无条件覆盖会让服务端把重发当成新写请求，幂等保护当场失效
  /// （§11.1.1）。
  ///
  /// 参数：[options] 本次请求配置。
  /// 返回：void。
  void _injectIdempotencyKeyForWrite(RequestOptions options) {
    if (!_isWriteMethod(options.method)) return;
    final headers = options.headers;
    if (headers.containsKey(idempotencyKeyHeader)) return;
    headers[idempotencyKeyHeader] = _hooks.newUuidV4();
  }

  /// 判断 HTTP 方法是否为需要幂等键的写接口。
  ///
  /// dio 不保证 [RequestOptions.method] 大小写（不同调用入口可能传入
  /// `post`），统一大写后比较。
  ///
  /// 参数：[method] 请求方法字符串。
  /// 返回：[bool] true 仅当方法为 POST 或 PATCH。
  bool _isWriteMethod(String method) {
    final upper = method.toUpperCase();
    return upper == 'POST' || upper == 'PATCH';
  }
}
