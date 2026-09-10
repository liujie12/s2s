/// 测试脚手架：契约测试用内存 Mock API 服务。
///
/// 后端开工前，契约测试没有真实服务可打；本类用 [HttpServer] 在
/// localhost 起一个最小服务，按「方法 + 路径」路由到测试登记的处理器，
/// 让契约测试（统一包形态、错误码对齐、Retry-After、幂等头校验）
/// 现在就能写、就能跑。后端就绪后以 `--dart-define=S2S_API_BASE_URL=<基址>`
/// 直指真实服务；断言分两层——形态断言两模式共用，
/// 值级断言（mock 桩字面值）仅 mock 模式成立（评审 #2）。
///
/// 诚实性红线（评审 #13）：mock 自身出错（路由未登记 / handler 异常）
/// 必须返回**非信封体**——若伪装成合法 ApiError 信封，契约断言会把
/// 「测试写错了」当「服务端契约行为」放过，测试失去自证能力。
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
}

/// 路由处理器：拿到请求，返回响应（同步或异步均可）。
typedef MockRouteHandler = FutureOr<MockResponse> Function(MockRequest req);

/// 内存 Mock API 服务。
///
/// 典型生命周期：
/// ```dart
/// final server = MockApiServer();
/// server.stub('POST', '/api/v1/auth/login', (req) async { ... });
/// final baseUrl = await server.start();
/// // 用 start() 返回的基址发真实 HTTP 请求（本类无 baseUrl getter——评审 #15）
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
      // 非信封体（评审 #13）：未登记路由是测试缺陷，不是服务端契约行为，
      // 返回合法信封会让信封断言把测试错误当成契约行为放过。
      _writePlain(httpReq, 501,
          'MOCK ERROR: 未登记路由 $routeKey（测试缺陷：请先 stub()，非契约行为）');
      return;
    }
    try {
      final resp = await handler(req);
      _writeJson(httpReq, resp.status, resp.body, extraHeaders: resp.headers);
    } catch (e) {
      // 非信封体（评审 #13）：handler 抛异常同样是测试缺陷。
      _writePlain(
          httpReq, 500, 'MOCK ERROR: handler 异常：$e（测试缺陷，非契约行为）');
    }
  }

  /// 写出纯文本响应（mock 自身错误专用，刻意不是统一信封——评审 #13）。
  ///
  /// 参数：[httpReq] 原始请求；[status] HTTP 状态码；[text] 错误说明。
  /// 返回：void；dio 收到 text/plain 后无法按 Map 解码，
  /// 任何信封形态断言会立即失败——测试缺陷当场暴露，不被放过。
  void _writePlain(HttpRequest httpReq, int status, String text) {
    httpReq.response.statusCode = status;
    httpReq.response.headers.contentType = ContentType.text;
    httpReq.response.write(text);
    httpReq.response.close();
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
