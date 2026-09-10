/// 契约解析失败异常（详细设计 §10.4.2 / §10.4.3 的映射函数抛出物）。
///
/// 为什么现在就建、而且只建这一个类：§10.4 的枚举与半径映射函数需要一个
/// 「收到契约外取值」的抛出物。若此刻用 `FormatException` 顶替，等 §11 的
/// dio 拦截器链落地时再改，改的是**已经散在各处的 catch 分支**——
/// 那时漏掉一处的表现是「某个解析错误穿透到 UI 变成红屏」，而不是编译错。
///
/// 因此本文件刻意只做一件事：定义异常与它的成因分类。网络层的错误码映射、
/// 重试策略、Toast 文案一概不在这里 —— 那些属于 §11、§12，等拦截器链落地时
/// 在本类上补 `factory`，不需要回头改调用点。
library;

/// 解析/契约类失败的成因。
///
/// 用枚举而非纯字符串：调用方（拦截器、错误上报）需要按成因分流，
/// 只有一句 message 就只能靠字符串匹配，那是最容易随文案改动而失效的判据。
enum ApiFailure {
  /// 响应体不符合契约：字段缺失、类型不符、枚举出现契约外取值。
  ///
  /// 这类失败**不该重试** —— 服务端再发一次还是同样的响应体。
  parseError,
}

/// 契约层异常。
class ApiException implements Exception {
  /// 构造一个契约层异常。
  ///
  /// [failure] 成因分类，供调用方分流
  /// [message] 面向开发者的诊断信息（含实际收到的值），不直接展示给用户
  const ApiException(this.failure, this.message);

  /// 解析失败（含枚举取值超出契约）。
  ///
  /// 单独给一个命名构造而不让调用方写 `ApiException(ApiFailure.parseError, ...)`：
  /// 映射函数里这行会出现十几次，越短越不容易有人图省事改抛别的东西。
  ///
  /// [message] 须包含**实际收到的值**。只写「解析失败」的报错等于没写 ——
  /// 排查时最需要知道的恰是那个非法值长什么样。
  const ApiException.parse(String message) : this(ApiFailure.parseError, message);

  /// 成因分类。
  final ApiFailure failure;

  /// 开发者诊断信息。
  final String message;

  @override
  String toString() => 'ApiException(${failure.name}): $message';
}
