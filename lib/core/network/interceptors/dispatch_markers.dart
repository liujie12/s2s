/// 拦截器调度标记与错误形态剥离的唯一共享实现（编码规范 §1.2/§1.1：
/// 同一逻辑只准有一份实现；2026-09-14 复审 #1 由两拦截器各抄一份
/// DioException 五字段重建收敛而来）。
///
/// 背景：AuthRefreshInterceptor 续期成功后经 `dio.fetch` 重放原始请求，
/// RetryInterceptor 自身重试也经 `dio.fetch` 发起内层重放；两类重放都会
/// 从链首重走全部拦截器。为抑制重放链上的错误处理自开调度循环，发起方
/// 在重放 options 的 extra 置调度标记，重放错误冒泡回发起方后，再把错误
/// 形态上的该标记剥离（见详设 §13/§14 与两拦截器类头「第三种标记」推演）。
library;

import 'package:dio/dio.dart';

/// RequestOptions.extra 中「本错误来自续期成功后的重放 fetch」标记键。
///
/// 重放链上的 RetryInterceptor 见此标记不自开外层重试循环，直接把错误
/// 交回 AuthRefreshInterceptor 的 `await fetch`；后者在 reject 回首发链
/// 前经 [errorWithoutExtraKey] 剥离它。该键由 AuthRefresh 置位、Retry
/// 读取、双方剥离路径共用，故定义在共享文件而非任一拦截器类上，避免
/// RetryInterceptor 反向 import AuthRefreshInterceptor（链尾到链中的
/// 类名耦合，复审 #1）。
const String authReplayDispatchExtraKey = 'auth_replay_dispatch';

/// 从错误携带的 [RequestOptions.extra] 剔除指定调度标记，并重建为同类
/// [DioException]，使落给调用方/首发链的错误形态不含仅存活于重放链路的
/// 内部标记（编码规范 §1.1：AuthRefresh 与 Retry 两拦截器共用此唯一实现，
/// 禁止内联重写）。
///
/// 参数：
///   [error] 内层/重放 fetch 抛出（并经重放链拦截器 reject）的错误；
///   [key]   需从 extra 剔除的调度标记键。
/// 返回：[DioException] 原本无该标记时原样返回 [error]；存在时返回仅
///   requestOptions 经 `copyWith(extra: 剔除后副本)` 替换、
///   response/type/error/stackTrace 逐字保留的新错误。
///
/// 字段保留口径：只拷 dio 5.11.1 DioException 构造器中参与错误流转的
/// 五字段（requestOptions/response/type/error/stackTrace）；`message`
/// 为纯诊断文案且 `copyWith` 不触及，两份历史实现均未拷贝、既有行为
/// 测试锁定此形态，故此处同样不拷贝。升级 dio 时须对照
/// DioException 构造器复核本字段清单（见详设 §11.1 链序与 dio 钉版）。
DioException errorWithoutExtraKey(DioException error, String key) {
  final options = error.requestOptions;
  if (!options.extra.containsKey(key)) {
    return error;
  }
  final strippedExtra = Map<String, dynamic>.of(options.extra)..remove(key);
  return DioException(
    requestOptions: options.copyWith(extra: strippedExtra),
    response: error.response,
    type: error.type,
    error: error.error,
    stackTrace: error.stackTrace,
  );
}
