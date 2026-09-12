/// 统一信封解包拦截器（详细设计 §11.1 链序第 3 位 / §11.3，
/// 计划 R8 / KTD2 / KTD10）。
///
/// 信封纪律（§11.3）：服务端全部响应（含错误）都是
/// `{code, message, data, request_id}`（snake_case），HTTP 状态码只做粗
/// 分类，业务语义在 code 里。因此**先拆信封再判 code**：
///   - `code == 0`：成功，`data` 原样返回给调用方；`data == null`
///     （GET /categories/tree 版本相同的 200 表达 304 语义）与
///     `request_id == null`（缓存命中未过服务端）都是合法成功态，
///     不得判异常；
///   - `code != 0`：经 [ApiErrorCode.fromCode] 映射，构造携带
///     `requestId` / `retryAfterSec` 的 [ApiException]，以
///     `handler.reject(err, true)` 分流——第二参 true 错误才流向后续
///     error 拦截器（dio 5.x 语义，KTD2），否则 40101 永远到不了
///     U5 的 AuthRefreshInterceptor；
///   - 非 Map body（网关/反代直出 HTML、JSON 数组等，**不过 Spring
///     信封**）按 HTTP 状态分流：5xx → networkFailure（可重试），
///     其余 → parseError（协议不符不该重试，R8）。
///
/// KTD10 边界：传输层 DioException（连接/接收超时、connectionError）
/// 的归一**不在本拦截器**——唯一归一点是 U6 RetryInterceptor.onError
/// （链尾才能区分重试中与耗尽）；cancel 裸穿透。故本类 [onError]
/// 直接透传，不做任何映射。
library;

import 'package:dio/dio.dart';

import '../api_error_code.dart';
import '../api_exception.dart';

/// 统一信封解包拦截器。
///
/// 为什么把 request_id/message 放 `response.extra` 而不是包一层 Response：
/// UI 报错唯一格式 `{message}（{request_id}）`（§11.4）需要 request_id，
/// 但调用方大量代码只消费 `response.data`；extra 是 dio 自带的旁路载体，
/// 不改变调用方取值形状，键名见 [requestIdExtraKey]/[messageExtraKey]。
class EnvelopeInterceptor extends Interceptor {
  /// 构造信封解包拦截器。
  const EnvelopeInterceptor();

  /// `request_id` 透传键（§11.4：UI 报错唯一回显值，为 null 时只显
  /// message，禁用 interaction_id 顶替）。
  static const String requestIdExtraKey = 'envelope_request_id';

  /// 信封 `message` 透传键（成功路径也可能需要服务端提示文案，§11.3）。
  static const String messageExtraKey = 'envelope_message';

  /// 响应方向：先拆信封再判 code（§11.3）。
  ///
  /// 参数：
  ///   [response] dio 原始响应（[BaseOptions.validateStatus] 恒 true，
  ///              所有 HTTP 状态都进这里而非 dio 自动抛错，KTD2）；
  ///   [handler] 成功调 `handler.next`（data 已替换为信封 data），
  ///              业务/协议错误调 `handler.reject(err, true)`。
  /// 返回：[void]（同步分流，不做 I/O）。
  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final result = unwrapEnvelope(response);
    final apiError = result.apiError;
    if (apiError != null) {
      // reject 只接受 DioException：以其 error 字段承载 ApiException。
      // callFollowingError=true（KTD2）：让 U5/U6 在 error 向接到错误。
      // type 用 unknown 而非 badResponse：validateStatus 恒 true 时 HTTP
      // 状态本身不是错误（KTD2 的断言即「不产生 badResponse」），业务码
      // 分流是应用层语义；真正的传输错误归一在 U6 RetryInterceptor（KTD10）。
      handler.reject(
        DioException(
          requestOptions: response.requestOptions,
          response: response,
          type: DioExceptionType.unknown,
          error: apiError,
        ),
        true,
      );
      return;
    }
    response.data = result.data;
    response.extra[requestIdExtraKey] = result.requestId;
    response.extra[messageExtraKey] = result.message;
    handler.next(response);
  }

  /// 传输层错误透传（KTD10）：归一在 U6 RetryInterceptor，本层不映射。
  ///
  /// 参数：
  ///   [err]     dio 传输层异常（超时/连接错误/cancel 等）；
  ///   [handler] 直接 `handler.next(err)` 透传给后续 error 拦截器。
  /// 返回：[void]。
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }
}

/// 信封解包结果（成功形态）。
class EnvelopeResult {
  /// 构造成功解包结果。
  const EnvelopeResult({
    required this.data,
    required this.requestId,
    required this.message,
  }) : apiError = null;

  /// 构造失败解包结果（业务错误码或协议不符）。
  const EnvelopeResult.failure(ApiException error)
    : apiError = error,
      data = null,
      requestId = null,
      message = null;

  /// 业务异常；非 null 表示调用方应收到错误。
  final ApiException? apiError;

  /// 信封 `data` 字段原样值（可为 null，§11.3 合法成功态）。
  final Object? data;

  /// 信封 `request_id`（可为 null，缓存命中时天然缺失）。
  final String? requestId;

  /// 信封 `message`（成功路径的服务端提示，可为 null）。
  final String? message;
}

/// 统一响应解包（§11.3 唯一实现处，编码规范 §1.2）。
///
/// 为什么非 Map body 按 HTTP 状态分流：正常情况下服务端错误也走 Spring
/// 信封（Map 形态，含业务码）；但网关、反向代理、WAF 拦截、DNS 劫持
/// 门户等环节可能**直出 HTML/纯文本**，这些响应根本没经过应用的信封
/// 切面。此时 5xx 与「上游服务不可用」语义相同，按可重试的
/// networkFailure 处理；2xx/4xx 却拿到非信封则是协议不符（如登录门户
/// 劫持、接口地址错误），重试结果必然相同，按 parseError 确定性失败。
///
/// 参数：[response] dio 原始响应（HTTP 状态码与 body 均为原始值）。
/// 返回：[EnvelopeResult] 成功携 data/requestId/message，失败携
///   [ApiException]（业务码带 requestId/retryAfterSec；非信封按状态
///   分流）；本函数不抛异常，全部失败形态经返回值表达。
EnvelopeResult unwrapEnvelope(Response<dynamic> response) {
  final body = response.data;

  // 非 Map body：网关/反代直出，不过 Spring 信封（R8 分流）。
  if (body is! Map) {
    return EnvelopeResult.failure(_nonEnvelopeFailure(response, body));
  }

  final codeValue = body['code'];
  if (codeValue is! int) {
    // 信封缺 code 或类型不符：协议不符，不重试（§10.3 解析失败 message
    // 含实际收到的值，经 ApiException.parse 定长截断，R5）。
    return EnvelopeResult.failure(
      ApiException.parse('响应信封缺少 int 型 code 字段，实际: $codeValue'),
    );
  }

  final requestId = _asNullableString(body['request_id'], 'request_id');
  final message = _asNullableString(body['message'], 'message');

  if (codeValue != ApiErrorCode.ok.code) {
    final ApiErrorCode mapped;
    try {
      mapped = ApiErrorCode.fromCode(codeValue);
    } on ApiException catch (e) {
      // 契约外业务码（fromCode 按 §10.3 default 降级抛 parseError）。
      return EnvelopeResult.failure(e);
    }
    return EnvelopeResult.failure(
      ApiException(
        code: mapped,
        message: message ?? '',
        requestId: requestId,
        retryAfterSec: _parseRetryAfterSeconds(response),
      ),
    );
  }

  return EnvelopeResult(
    data: body['data'],
    requestId: requestId,
    message: message,
  );
}

/// 非 Map body 按 HTTP 状态分流（R8）。
///
/// 参数：
///   [response] 原始响应（取 statusCode）；
///   [body]     已判定为非 Map 的响应体（仅用于类型诊断，不进 message
///              全文，防止超大 HTML 灌爆报错，R5）。
/// 返回：[ApiException] 5xx 为 [ApiErrorCode.networkFailure]
///   （message 必含 HTTP 状态码，否则无法区分 502/503/504），
///   其余为 [ApiErrorCode.parseError]。
ApiException _nonEnvelopeFailure(Response<dynamic> response, Object? body) {
  final statusCode = response.statusCode ?? 0;
  final bodyKind = body == null ? 'null' : body.runtimeType.toString();
  if (statusCode >= 500) {
    // 主构造而非 parse 工厂：networkFailure 的 message 含 HTTP 状态码，
    // 长度天然受限（不携带原始 body），无需 parse 截断路径。
    return ApiException(
      code: ApiErrorCode.networkFailure,
      message: '非信封响应（HTTP $statusCode，body 类型 $bodyKind），'
          '按上游不可用处理',
    );
  }
  return ApiException.parse(
    '非信封响应（HTTP $statusCode，body 类型 $bodyKind），协议不符',
  );
}

/// 解析 `Retry-After` 响应头为整数秒（§11.3 第三条易错点）。
///
/// 服务端约定是整数秒而非 HTTP-date：按 [int.tryParse] 解析，失败回退
/// null（调用方据此退回 §14 默认退避表），解析头本身**永不抛异常**。
///
/// 参数：[response] 原始响应。
/// 返回：[int?] 整数秒；头缺失或非整数时为 null。
int? _parseRetryAfterSeconds(Response<dynamic> response) {
  final raw = response.headers.value('retry-after');
  if (raw == null) return null;
  return int.tryParse(raw.trim());
}

/// 把信封中可空的字符串字段安全取出，类型不符时抛 [ApiException.parse]。
///
/// 为什么不直接 `as String?`：服务端错把 `request_id` 返成数字时硬转
/// 会抛 TypeError，绕过统一异常形态；显式判型后走 parseError，message
/// 含实际值便于定位（§10.3）。
///
/// 参数：
///   [value]    信封字段原始值；
///   [fieldName] 字段名（进诊断 message）。
/// 返回：[String?] null/字符串原样返回，字符串形态通过。
/// 抛出：[ApiException.parse] 当值既非 null 也非 String。
String? _asNullableString(Object? value, String fieldName) {
  if (value == null || value is String) return value as String?;
  throw ApiException.parse(
    '响应信封字段 $fieldName 应为 String?，实际: $value',
  );
}
