/// gzip 体积统计拦截器（详细设计 §11.1 链序第 2 位 / §11.5，
/// 编码规范 §5.3，计划 R13 / R16 / U4）。
///
/// 职责边界（R13，§11.5 第一天实测后固化）：
///   - **默认不写 `Accept-Encoding`**：dart:io `HttpClient`
///     （dio 在 VM 平台的默认 IOHttpClientAdapter，与生产同款适配器）
///     默认自动协商 gzip 并自动解压，应用层再注入该头零收益；实测两种
///     条件的实际观察值与裁定见 §11.5「实测结论（2026-09-10）」；
///   - **只统计、不压缩请求体**：本拦截器是「压缩前后响应体积」的唯一
///     统计处，数据供 §17 埋点的网络辅助指标使用，不参与任何请求改写；
///   - 统计永不阻断响应：缺 `Content-Length`（如 chunked 传输）时压缩后
///     字节数降级为 null，不抛异常。
///
/// R16 日志纪律：本拦截器自身**不打印任何日志**，只把结构化体积数据放
/// `response.extra` 与可选 [onStats] 回调。回调载荷 [GzipResponseStats]
/// 仅含 path / HTTP 状态码 / 字节数 / content-encoding 头值，
/// 永不含 headers 整体、body、Authorization（编码规范 §4.11）。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

/// 响应体积统计载荷（R16：只允许元数据，禁止携带 headers/body/token）。
class GzipResponseStats {
  /// 构造一次响应的体积统计载荷。
  ///
  /// 参数：
  ///   [path]               请求路径（不含 query 以外的敏感参数；取自
  ///                        RequestOptions.path，R16 白名单字段）；
  ///   [statusCode]         HTTP 状态码（R16 白名单字段）；
  ///   [compressedBytes]    线上（压缩后）字节数，取 `Content-Length`；
  ///                        头缺失（chunked 等）时为 null（降级，不猜值）；
  ///   [uncompressedBytes]  解压后 JSON 明文字节数（utf8 重新编码实测，
  ///                        不依赖响应头，故恒可测）；
  ///   [contentEncoding]    `Content-Encoding` 头原值（如 `gzip`），
  ///                        无头时为 null；只登记头值，不登记其他响应头。
  const GzipResponseStats({
    required this.path,
    required this.statusCode,
    required this.compressedBytes,
    required this.uncompressedBytes,
    required this.contentEncoding,
  });

  /// 请求路径（R16 元数据白名单）。
  final String path;

  /// HTTP 状态码（R16 元数据白名单）。
  final int? statusCode;

  /// 压缩后线上字节数；缺 Content-Length 时为 null。
  final int? compressedBytes;

  /// 解压后 JSON 明文字节数。
  final int uncompressedBytes;

  /// Content-Encoding 头原值；无头为 null。
  final String? contentEncoding;
}

/// gzip 体积统计拦截器（链序第 2 位，位于 EnvelopeInterceptor 之前）。
///
/// 统计时点（§11.1 第一天实测结论，2026-09-10）：dio 5.11.1 三个方向均按
/// `Interceptors.add` 添加顺序执行（FIFO，源码 dio_mixin.dart 对同一 future
/// 依添加序逐个 `.then`/`catchError` 串联，无 reversed）。因此返回向上本
/// 拦截器（第 2 位）**先于** EnvelopeInterceptor（第 3 位）运行，此刻
/// `response.data` 还是 dio Transformer 解码出的**完整信封 Map**（尚未拆包）。
/// 对其重新 `jsonEncode + utf8` 得到的「解压后字节数」即服务端压缩前的完整
/// 信封明文，与「压缩后线上字节数（Content-Length）」同口径，正是压缩收益
/// 分母；这与详设 §11.1 旧图注「返回向自下而上」的文字相反，已按实测回写。
class GzipInterceptor extends Interceptor {
  /// 构造体积统计拦截器。
  ///
  /// 参数：[onStats] 可选的结构化统计回调（埋点接线在后续条目消费；
  ///   本单元无真实日志通道，测试以回调产物作为「日志候选内容」断言
  ///   R16 无 token）。默认 null：只写 `response.extra`，不产生任何输出。
  const GzipInterceptor({this.onStats});

  /// `response.extra` 键：压缩后（线上）字节数，int? 形态。
  ///
  /// 埋点用途：§17 layer_switch 网络段辅助指标——线上传输体积，压缩收益
  /// 的分子；缺 Content-Length 时为 null（降级）。
  static const String compressedBytesExtraKey = 'gzip_compressed_bytes';

  /// `response.extra` 键：解压后明文字节数，int 形态（恒可测）。
  static const String uncompressedBytesExtraKey = 'gzip_uncompressed_bytes';

  /// `response.extra` 键：Content-Encoding 头原值，String? 形态。
  static const String contentEncodingExtraKey = 'gzip_content_encoding';

  /// 响应头名：Content-Length（dart:io HttpHeaders 常量同名，此处经 dio
  /// Headers 小写键读取，不复制协议外字面量）。
  static const String _contentLengthHeader = 'content-length';

  /// 响应头名：Content-Encoding。
  static const String _contentEncodingHeader = 'content-encoding';

  /// 结构化统计回调；null 时只写 extra。
  final void Function(GzipResponseStats stats)? onStats;

  /// 发出方向：默认无动作（不写 Accept-Encoding，R13 / §11.5 实测裁定）。
  ///
  /// 保留重写点仅是 dio 拦截器契约完整性的体现；任何注入逻辑都必须先有
  /// §11.5 新实测结论回写后才允许添加（编码规范 §5.3：默认不注入）。
  ///
  /// 参数：
  ///   [options] 本次请求配置（原样透传，不读不改 headers）；
  ///   [handler] dio 请求拦截器处理器。
  /// 返回：[void]，直接 `handler.next`。
  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    handler.next(options);
  }

  /// 返回方向：登记压缩前后字节数到 `response.extra` 并触发 [onStats]。
  ///
  /// 参数：
  ///   [response] dio 响应（返回向按添加序执行，本拦截器先于 Envelope，
  ///              data 此刻为完整信封 Map）；
  ///   [handler] dio 响应拦截器处理器，统计后必须原样放行，统计失败也
  ///              不得阻断业务响应。
  /// 返回：[void]。
  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final compressedBytes = _readContentLength(response);
    final contentEncoding =
        response.headers.value(_contentEncodingHeader)?.toLowerCase();
    final uncompressedBytes = _measureUncompressedBytes(response.data);

    response.extra[compressedBytesExtraKey] = compressedBytes;
    response.extra[uncompressedBytesExtraKey] = uncompressedBytes;
    response.extra[contentEncodingExtraKey] = contentEncoding;

    final callback = onStats;
    if (callback != null) {
      callback(
        GzipResponseStats(
          path: response.requestOptions.path,
          statusCode: response.statusCode,
          compressedBytes: compressedBytes,
          uncompressedBytes: uncompressedBytes,
          contentEncoding: contentEncoding,
        ),
      );
    }
    handler.next(response);
  }

  /// 错误方向：透传（统计只在成功响应上做，KTD10 错误归一在 U6）。
  ///
  /// 参数：
  ///   [err]     dio 异常；
  ///   [handler] 直接 `handler.next(err)` 交给后续 error 拦截器。
  /// 返回：[void]。
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    handler.next(err);
  }

  /// 读取 Content-Length 为线上字节数；缺失/非法时降级 null（不抛异常）。
  ///
  /// 为什么不猜值：chunked 传输没有 Content-Length，按其他头估算会产出
  /// 假数据污染埋点；null 是显式降级语义（详设 §11.5：统计不依赖该头）。
  ///
  /// 参数：[response] dio 响应。
  /// 返回：[int?] 线上字节数；头缺失或非正整数时为 null。
  int? _readContentLength(Response<dynamic> response) {
    final raw = response.headers.value(_contentLengthHeader);
    if (raw == null) return null;
    return int.tryParse(raw.trim());
  }

  /// 测量解压后 JSON 明文字节数（对当前 `response.data` 重新做
  /// `jsonEncode + utf8`，null 负载记 0）。
  ///
  /// 为什么重新编码而非取原始字节：返回向到达本拦截器时，dio 的
  /// Transformer 已把响应体解码为 Dart 对象，原始明文字节流不在手上；
  /// 且实测返回向按添加序执行，本拦截器（第 2 位）先于 Envelope（第 3 位）
  /// 运行，故此处 data 是**完整信封 Map**。对它做确定性的反向编码得到的
  /// 字节数即「解压后完整信封长度」（详设 §11.5 统计口径），与服务端压缩
  /// 前明文在 JSON 无空白差异的语义下等长；测量本身不依赖请求头。
  ///
  /// 参数：[data] 当前响应负载（本拦截器时点为完整信封 Map）。
  /// 返回：[int] utf8 明文字节数；null 负载为 0。
  int _measureUncompressedBytes(Object? data) {
    if (data == null) return 0;
    return utf8.encode(jsonEncode(data)).length;
  }
}
