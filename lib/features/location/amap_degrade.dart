import 'dart:async';

/// 高德 Web 服务降级原因（埋点 `amap_degraded` 的 props.reason 取值）。
///
/// **为什么要显式区分原因**：三个客户端都是「失败即空」，线上若只看到「没有
/// 候选/没有距离」，无法判断是 Key 失效、限流、超时还是用户确实没搜到。原因
/// 枚举让这三种故障在埋点侧可区分，同时不携带坐标、关键词与含 Key 的 URL。
enum AmapDegradeReason {
  /// 未注入构建期 Key（该构建所有请求都直接降级）。
  noKey('no_key'),

  /// 请求超时（含响应体读取超时）。
  timeout('timeout'),

  /// 服务端返回非 200。
  httpError('http_error'),

  /// 响应无法解析（JSON 非法或结构不符）。
  parse('parse'),

  /// 其余网络异常（连接失败、DNS、TLS 等）。
  network('network');

  const AmapDegradeReason(this.wire);

  /// 埋点 props 线值（下划线小写）。
  final String wire;
}

/// 把捕获到的异常归为便于统计的降级原因。
///
/// 参数：[error] 异常对象。
/// 返回：[AmapDegradeReason.timeout] / [AmapDegradeReason.parse] /
///   [AmapDegradeReason.network]。
AmapDegradeReason amapDegradeReasonOf(Object error) {
  if (error is TimeoutException) return AmapDegradeReason.timeout;
  if (error is FormatException) return AmapDegradeReason.parse;
  return AmapDegradeReason.network;
}
