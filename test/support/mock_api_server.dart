/// 测试脚手架：契约测试用内存 Mock API 服务。
///
/// 后端开工前，契约测试没有真实服务可打；本类用 [HttpServer] 在
/// localhost 起一个最小服务，按「方法 + 路径」路由到测试登记的处理器，
/// 让契约测试（统一包形态、错误码对齐、Retry-After、幂等头校验）
/// 现在就能写、就能跑，后端就绪后把 baseUrl 换成真实地址即可，
/// 断言一行不用改。
///
/// 设计取舍：不引入 dio_adapter / mockito。本服务只依赖 dart:io，
/// 走的是真实 HTTP 栈（真实状态码、真实响应头、真实 gzip 协商），
/// 比拦截器层 mock 更接近契约校验要证明的东西。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 一次请求的可见信息（传给路由处理器做断言）。
class MockRequest {
  const MockRequest({
    required this.method,
    required this.path,
    required this.headers,
    required this.body,
  });

  /// HTTP 方法大写。
  final String method;

  /// 请求路径（含 query，如 `/api/v1/map/pins?grid_id=26700_6728`）。
  final String path;

  /// 请求头（键已小写化）。
  final Map<String, String> headers;

  /// 解析后的 JSON 请求体；非 JSON 请求为 null。
  final Object? body;

  /// 取某个请求头，不存在返回 null。
  String? header(String name) => headers[name.toLowerCase()];
}

/// 一次 mock 响应。
///
/// 三种响应体形态互斥（优先级 gzipBytes > rawBytes > body）：
///   - 默认 [body]：JSON 信封/任意 JSON 值，服务统一 `application/json`
///     （契约测试的唯一形态）；
///   - [rawBytes]：网关/反代类场景的原始字节（HTML 502、非信封 200 等，
///     网络层 §11.3 分流测试需要），服务不再 JSON 编码，content-type 用
///     [contentType] 覆盖，缺省 `text/html`；
///   - [gzipBytes]：调用方已实体压缩（dart:io [GZipCodec]）的字节，
///     服务写出 `Content-Encoding: gzip` 且 Content-Length 为压缩后长度，
///     用于 §11.5 gzip 第一天实测——压缩在调用方完成，服务端不隐式编码，
///     保证「线上字节数」就是传入字节数，统计断言可逐字节相等。
class MockResponse {
  /// 构造一次 mock 响应。
  const MockResponse({
    this.status = 200,
    required this.body,
    this.headers = const {},
    this.rawBytes,
    this.gzipBytes,
    this.contentType,
    this.omitContentLength = false,
  });

  /// HTTP 状态码。
  final int status;

  /// 响应体（将 JSON 编码）；[rawBytes] 非空时本字段被忽略。
  final Object? body;

  /// 附加响应头。
  ///
  /// JSON 响应的 content-type 由服务统一处理；raw 响应可用 [contentType]
  /// 覆盖，或直接在本映射写 `content-type`（[contentType] 优先）。
  final Map<String, String> headers;

  /// 原始响应字节（不经 JSON 编码）；非空时走 raw 写出分支。
  final List<int>? rawBytes;

  /// 已 gzip 实体压缩的响应字节（调用方用 dart:io [gzip] 编码）；
  /// 非空时优先级最高，服务写 `Content-Encoding: gzip` 与压缩后
  /// Content-Length，供 §11.5 gzip 第一天实测。
  final List<int>? gzipBytes;

  /// raw 响应的 Content-Type 覆盖值（如 `text/html; charset=utf-8`）；
  /// null 时 raw 响应默认 `text/html`，JSON 响应恒为 application/json。
  final String? contentType;

  /// 是否省略 Content-Length（true 时由 HttpServer 自动走 chunked 传输
  /// 编码）；仅供 GzipInterceptor「缺 Content-Length 降级」实测使用。
  final bool omitContentLength;

  /// 快速构造一个失败响应：[body] 建议用 ApiEnvelope.failure 生成。
  factory MockResponse.failure(
    int status,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) =>
      MockResponse(status: status, body: body, headers: headers);

  /// 构造一个 raw 字节响应（HTML/字符串/非信封 body 的 §11.3 分流测试）。
  ///
  /// 参数：
  ///   [status]      HTTP 状态码；
  ///   [rawBytes]    原始字节（调用方自行 utf8/gzip 编码）；
  ///   [contentType] Content-Type 覆盖，缺省 `text/html; charset=utf-8`；
  ///   [headers]     附加响应头。
  /// 返回：[MockResponse]，其 [body] 恒为 null（raw 分支忽略该字段）。
  factory MockResponse.raw(
    int status,
    List<int> rawBytes, {
    String contentType = 'text/html; charset=utf-8',
    Map<String, String> headers = const {},
  }) =>
      MockResponse(
        status: status,
        body: null,
        rawBytes: rawBytes,
        contentType: contentType,
        headers: headers,
      );

  /// 构造一个 gzip 实体压缩响应（§11.5 第一天实测专用）。
  ///
  /// [gzipBytes] 为调用方已用 dart:io [gzip] 编解码器压缩的字节（通常是
  /// `gzip.encode(utf8.encode(jsonEncode(envelope)))`）；服务端逐字写出
  /// 并附 `Content-Encoding: gzip`，不再二次压缩、不再 JSON 编码。
  /// [contentType] 缺省 `application/json; charset=utf-8`（压缩前的逻辑
  /// 媒体类型）。
  factory MockResponse.gzip(
    int status,
    List<int> gzipBytes, {
    String contentType = 'application/json; charset=utf-8',
    Map<String, String> headers = const {},
  }) =>
      MockResponse(
        status: status,
        body: null,
        gzipBytes: gzipBytes,
        contentType: contentType,
        headers: headers,
      );

  /// 构造一个省略 Content-Length 的 raw 响应（HttpServer 自动 chunked），
  /// 仅供 GzipInterceptor 缺头降级实测；禁止手工设 transfer-encoding
  /// （dart:io 拒绝调用方写该受控头）。
  factory MockResponse.chunked(
    int status,
    List<int> rawBytes, {
    String contentType = 'application/json; charset=utf-8',
    Map<String, String> headers = const {},
  }) =>
      MockResponse(
        status: status,
        body: null,
        rawBytes: rawBytes,
        contentType: contentType,
        headers: headers,
        omitContentLength: true,
      );
}

/// 路由处理器：拿到请求，返回响应（同步或异步均可）。
typedef MockRouteHandler = FutureOr<MockResponse> Function(MockRequest req);

/// 内存 Mock API 服务。
///
/// 典型生命周期：
/// ```dart
/// final server = MockApiServer();
/// server.stub('POST', '/api/v1/auth/login', (req) async { ... });
/// await server.start();
/// // 用 server.baseUrl 发真实 HTTP 请求
/// await server.stop();
/// ```
class MockApiServer {
  HttpServer? _server;

  /// 路由表：键为 `METHOD path`（path 不含 query）。
  final Map<String, MockRouteHandler> _routes = {};

  /// 服务绑定地址（[start] 之后可用；测试手动构造 dio 时取基址用）。
  InternetAddress get address => _server!.address;

  /// 服务监听端口（[start] 之后可用）。
  int get port => _server!.port;

  /// 最近一次收到的请求（供测试断言服务端实际看到了什么头/体）。
  MockRequest? lastRequest;

  /// 已收到的全部请求（顺序保留，供幂等/单飞类断言）。
  final List<MockRequest> received = [];

  /// 登记一条路由。
  ///
  /// 参数：
  ///   [method]  HTTP 方法（大小写不敏感）；
  ///   [path]    路径，须与请求行 path 一致（不含 query 部分按精确前缀匹配）；
  ///   [handler] 请求处理器。
  /// 返回：void；后登记同键路由覆盖前者。
  void stub(String method, String path, MockRouteHandler handler) {
    _routes['${method.toUpperCase()} $path'] = handler;
  }

  /// 启动服务，监听 localhost 随机端口。
  ///
  /// 返回：[Future<String>] 服务基址，如 `http://127.0.0.1:53917/api/v1`。
  /// [apiPrefix] 为契约统一前缀，默认 `/api/v1`。
  Future<String> start({String apiPrefix = '/api/v1'}) async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handle);
    return 'http://${_server!.address.host}:${_server!.port}$apiPrefix';
  }

  /// 停止服务。
  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
  }

  /// 统一请求分发。
  Future<void> _handle(HttpRequest httpReq) async {
    final routeKey = '${httpReq.method} ${httpReq.uri.path}';
    // HttpHeaders 没有 entries 迭代器，用 forEach 收集（同名头取首个值即可，
    // 契约测试不涉及多值头）。
    final headers = <String, String>{};
    httpReq.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.join(',');
    });
    Object? body;
    if (httpReq.method != 'GET' && httpReq.contentLength > 0) {
      final raw = await utf8.decoder.bind(httpReq).join();
      if (raw.isNotEmpty) body = jsonDecode(raw);
    }
    final req = MockRequest(
      method: httpReq.method,
      path: httpReq.uri.toString(),
      headers: headers,
      body: body,
    );
    lastRequest = req;
    received.add(req);

    final handler = _routes[routeKey];
    if (handler == null) {
      _writeJson(
        httpReq,
        501,
        {'code': 50001, 'message': 'mock 未登记路由：$routeKey', 'data': null},
      );
      return;
    }
    try {
      final resp = await handler(req);
      final gzipped = resp.gzipBytes;
      final rawBytes = resp.rawBytes;
      if (gzipped != null) {
        // gzip 分支：字节已由调用方实体压缩，服务逐字写出并声明
        // Content-Encoding: gzip（§11.5 第一天实测，不做隐式二次压缩）。
        _writeGzip(
          httpReq,
          resp.status,
          gzipped,
          contentType: resp.contentType,
          extraHeaders: resp.headers,
        );
      } else if (rawBytes != null) {
        // raw 分支：不经 JSON 编码、不强制 application/json ——
        // §11.3 分流测试要复现网关直出 HTML/非信封 body 的真实形态。
        _writeRaw(
          httpReq,
          resp.status,
          rawBytes,
          contentType: resp.contentType,
          extraHeaders: resp.headers,
          omitContentLength: resp.omitContentLength,
        );
      } else {
        _writeJson(httpReq, resp.status, resp.body, extraHeaders: resp.headers);
      }
    } catch (e) {
      _writeJson(
        httpReq,
        500,
        {'code': 50001, 'message': 'mock handler 异常：$e', 'data': null},
      );
    }
  }

  /// 写出 JSON 响应（统一 content-type）。
  void _writeJson(
    HttpRequest httpReq,
    int status,
    Object? body, {
    Map<String, String> extraHeaders = const {},
  }) {
    httpReq.response.statusCode = status;
    httpReq.response.headers.contentType = ContentType.json;
    extraHeaders.forEach(httpReq.response.headers.set);
    // 先编码为字节再显式写 Content-Length：GzipInterceptor 的压缩后字节数
    // 统计读该响应头，必须由服务端真实给出（而非依赖 write(String) 的隐式
    // 分块行为），体积断言才能逐字节对齐（详设 §11.5 实测/R13）。
    final bytes = utf8.encode(jsonEncode(body));
    httpReq.response.headers
        .set(HttpHeaders.contentLengthHeader, bytes.length);
    httpReq.response.add(bytes);
    httpReq.response.close();
  }

  /// 写出原始字节响应（content-type 可覆盖，默认 text/html）。
  ///
  /// 参数：
  ///   [httpReq]             底层请求；
  ///   [status]              HTTP 状态码；
  ///   [rawBytes]            调用方已编码的响应字节；
  ///   [contentType]         Content-Type 覆盖值，null 用 text/html；
  ///   [extraHeaders]        附加响应头；
  ///   [omitContentLength]   true 时不写 Content-Length，HttpServer 自动
  ///                         改用 chunked 传输编码（缺头降级实测场景）。
  /// 返回：void；写出后关闭响应。
  void _writeRaw(
    HttpRequest httpReq,
    int status,
    List<int> rawBytes, {
    String? contentType,
    Map<String, String> extraHeaders = const {},
    bool omitContentLength = false,
  }) {
    httpReq.response.statusCode = status;
    httpReq.response.headers
        .set(HttpHeaders.contentTypeHeader, contentType ?? 'text/html');
    extraHeaders.forEach(httpReq.response.headers.set);
    if (!omitContentLength) {
      httpReq.response.headers.set(
        HttpHeaders.contentLengthHeader,
        rawBytes.length,
      );
    }
    httpReq.response.add(rawBytes);
    httpReq.response.close();
  }

  /// 写出 gzip 实体压缩响应（§11.5 第一天实测专用）。
  ///
  /// 与 [_writeRaw] 的唯一语义差异：显式声明 `Content-Encoding: gzip`
  /// 且 Content-Length 为**压缩后**字节数；Content-Type 描述压缩前的
  /// 逻辑媒体类型（缺省 application/json）。字节逐字写出，不依赖
  /// HttpServer.autoCompress（默认关闭，避免双重压缩）。
  ///
  /// 参数：
  ///   [httpReq]      底层请求；
  ///   [status]       HTTP 状态码；
  ///   [gzipBytes]    调用方已用 dart:io gzip 编码的字节；
  ///   [contentType]  压缩前逻辑媒体类型，null 用 application/json；
  ///   [extraHeaders] 附加响应头。
  /// 返回：void；写出后关闭响应。
  void _writeGzip(
    HttpRequest httpReq,
    int status,
    List<int> gzipBytes, {
    String? contentType,
    Map<String, String> extraHeaders = const {},
  }) {
    httpReq.response.statusCode = status;
    httpReq.response.headers.set(
      HttpHeaders.contentTypeHeader,
      contentType ?? 'application/json; charset=utf-8',
    );
    httpReq.response.headers
        .set(HttpHeaders.contentEncodingHeader, 'gzip');
    httpReq.response.headers.set(
      HttpHeaders.contentLengthHeader,
      gzipBytes.length,
    );
    extraHeaders.forEach(httpReq.response.headers.set);
    httpReq.response.add(gzipBytes);
    httpReq.response.close();
  }
}
