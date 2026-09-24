/// 统一异常形态（详细设计 §11.3）：网络层与契约解析层的**唯一异常类型**。
///
/// 自 `lib/core/api_exception.dart` 迁移至本目录并扩展（计划 KTD9 / R5）：
/// 旧失败分类枚举（`failure` 字段）退役删除，其唯一的 `parseError` 语义由
/// [ApiErrorCode.parseError] 吸收（计划 KTD1 —— 同一语义两份口径违反
/// 编码规范 §1.1；旧枚举名从代码与注释全面清除，grep 须零命中）。四字段
/// `{code, message, requestId?, retryAfterSec?}`
/// 与 §11.3 `unwrap` 的构造形状逐字对齐。
///
/// [ApiException.parse] 是 [ApiErrorCode.parseError] 的**规范工厂构造**，
/// 永久保留（评审 #12 订正：早期注释误标为「待退役的兼容构造」）。全部解析
/// 失败抛出点只准走该工厂，禁止内联
/// `ApiException(code: ApiErrorCode.parseError, ...)` —— 统一入口保证
/// message 必经 [_truncateParseMessage] 截断、口径单一（编码规范 §1.1）。
/// 现有 32 处生产调用点：`core/network` 9 处（`api_error_code.dart` ×1、
/// `api_client.dart` ×4、`interceptors/auth_refresh_interceptor.dart` ×1、
/// `interceptors/envelope_interceptor.dart` ×3）、
/// `core/contract_json.dart` ×10（解析助手，[124] B4 自 category_dto
/// 上浮 9 处并新增 optInt，搬家不减调用点）、
/// `domain/listing_category.dart` ×2、
/// `features/discovery/discovery_filter.dart` ×1、
/// `features/category/category_dto.dart` ×2（level 范围校验 1 +
/// `_optChildren` 1，[124] B1 起 11 处中 9 处已上浮）、
/// `features/auth/auth_repository.dart` ×8（[123] U10：AuthSession.fromJson ×2、
/// AuthRepository._parseLoginResult ×4、_parseUserId ×2）；
/// 新增解析失败点同走本工厂。
///
/// **循环 import 说明**：见 `api_error_code.dart` 文件头，同一份说明。
library;

import 'package:dio/dio.dart' show DioException;

import 'api_error_code.dart';

/// 契约层 / 网络层统一异常。
class ApiException implements Exception {
  /// 构造一个统一异常（§11.3 `unwrap` 的构造形状，全命名参数）。
  ///
  /// [code] 错误码枚举，决定调用方行为（查 §12.2 行为表）
  /// [message] 面向开发者的诊断信息（含实际收到的值），不直接展示给用户
  /// [requestId] 服务端 `request_id`，UI 报错唯一回显值（§11.4）；
  /// 缓存命中或请求未到服务端时为 null，属正常（§11.3）
  /// [retryAfterSec] 服务端 `Retry-After` 整数秒；只在 8 个限流/锁定码上
  /// 存在，缺失时为 null 属正常（§11.3）
  const ApiException({
    required this.code,
    required this.message,
    this.requestId,
    this.retryAfterSec,
  });

  /// 解析失败（含枚举取值超出契约、非信封 body）。
  ///
  /// 单独给一个命名构造而不让调用方写
  /// `ApiException(code: ApiErrorCode.parseError, ...)`：映射函数里这行会
  /// 出现十几次，越短越不容易有人图省事改抛别的东西。
  ///
  /// [message] 须包含**实际收到的值**。只写「解析失败」的报错等于没写 ——
  /// 排查时最需要知道的恰是那个非法值长什么样。message 经
  /// [_truncateParseMessage] 定长截断（R5）：只含截断后的类型/键名/枚举
  /// 实际值，不含原始 body 全文。
  ///
  /// 返回：code 恒为 [ApiErrorCode.parseError] 的异常实例。
  factory ApiException.parse(String message) => ApiException(
        code: ApiErrorCode.parseError,
        message: _truncateParseMessage(message),
      );

  /// 错误码枚举。
  final ApiErrorCode code;

  /// 开发者诊断信息。
  final String message;

  /// 服务端 `request_id`，可空。
  final String? requestId;

  /// 服务端 `Retry-After` 整数秒，可空。
  final int? retryAfterSec;

  /// 用户可读报错文案（详设 §11.4 UI 报错唯一格式，[124] B4 提取为
  /// 唯一实现处——selector 与 precheck 两处消费）。
  ///
  /// 格式 `{message}（{request_id}）`；[requestId] 为 null 只显
  /// [message]，**禁用 interaction_id 顶替**（详设 §11.4）。
  String get uiMessage =>
      requestId == null ? message : '$message（$requestId）';

  /// `parseError` message 的定长上限（字符数）。
  ///
  /// ⚠️ 依据源未给数值：R5 只要求「定长上限」，PRD/详设均无对应行。
  /// 取 200 的依据：既有调用点最长诊断串 <40 字符，200 足以容纳
  /// 「类型/键名/枚举实际值」三元组，又必然截断任何原始 body 全文 ——
  /// 防线目的是不让大体积 body 灌爆日志与报错弹窗（编码规范 §4.11 日志
  /// 纪律的客户端落地）。本值不进 `nfr_constants.dart`：它不是 PRD/详设
  /// 的 NFR 判定线，污染真源比字面量更难治理。改动须同步
  /// `test/core/api_exception_test.dart` 的体积断言。
  static const int maxParseMessageLength = 200;

  /// 截断 `parseError` 诊断 message 到 [maxParseMessageLength]。
  ///
  /// [message] 构造侧传入的原始诊断串。
  /// 返回：不超上限原样返回；超上限截到上限长度并以「…」收尾 ——
  /// 无标记的截断会让日志读者误以为信息完整。
  static String _truncateParseMessage(String message) {
    if (message.length <= maxParseMessageLength) return message;
    return '${message.substring(0, maxParseMessageLength - 1)}…';
  }

  @override
  String toString() => 'ApiException(${code.name}): $message';
}

/// 从链上 catch 到的异常对象中拆出 [ApiException]（生产侧唯一拆包处，
/// 编码规范 §1.1）。
///
/// 链上异常只有两种形态（详设 §11 / 计划 KTD2、KTD10）：
///   1. [DioException] 且其 `error` 为 [ApiException]——信封业务错误经
///      EnvelopeInterceptor reject、传输层错误经 RetryInterceptor 链尾
///      归一（networkFailure）后的统一形态；
///   2. 裸 [ApiException]——DTO/契约解析失败在响应返回后同步抛出，
///      不经拦截器 reject 包装。
/// 页面/状态层 catch 后一律经本函数归一再展示或入状态，禁止各处自行
/// 强转；测试侧对应物是 `NetworkChainHarness.apiErrorOf`（断言形态、
/// 不兜底，测试缺陷不得当契约行为放过）。
///
/// 参数：[error] try/catch 捕获的异常对象。
/// 返回：[ApiException]。理论不可达的第三形态（拦截器链缺损、绕过
///   生产装配发请求）按 [ApiErrorCode.networkFailure] 兜底并在 message
///   注明实际运行时类型——autoRetry 行为给页面重试入口，比静默吞掉
///   或整页崩溃诚实。
ApiException asApiException(Object error) {
  if (error is ApiException) return error;
  if (error is DioException) {
    final inner = error.error;
    if (inner is ApiException) return inner;
  }
  return ApiException(
    code: ApiErrorCode.networkFailure,
    message: '未归一的异常形态（期望 DioException 包 ApiException 或裸 '
        'ApiException），实际类型: ${error.runtimeType}',
  );
}
