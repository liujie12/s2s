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
class MockResponse {
  const MockResponse({
    this.status = 200,
    required this.body,
    this.headers = const {},
  });

  /// HTTP 状态码。
  final int status;

  /// 响应体（将 JSON 编码）。
  final Object? body;

  /// 附加响应头（content-type 与 content-encoding 由服务统一处理）。
  final Map<String, String> headers;

  /// 快速构造一个失败响应：[body] 建议用 ApiEnvelope.failure 生成。
  factory MockResponse.failure(
    int status,
    Map<String, Object?> body, {
    Map<String, String> headers = const {},
  }) =>
      MockResponse(status: status, body: body, headers: headers);
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
      _writeJson(httpReq, resp.status, resp.body, extraHeaders: resp.headers);
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
    httpReq.response.write(jsonEncode(body));
    httpReq.response.close();
  }
}
