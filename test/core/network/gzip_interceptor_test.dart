/// GzipInterceptor 与「第一天双实测」测试（详细设计 §11.1 链序 / §11.5，
/// 编码规范 §5.3，计划 R13 / R16 / U4）。
///
/// 本文件同时承担 U4 的两个第一天实测项，结论必须回写详设真源：
///   - 实测一（§11.5 判定表）：dart:io HttpClient（dio VM 平台默认
///     IOHttpClientAdapter，与生产同款适配器）在「不注入 / 手工注入」
///     Accept-Encoding 两种条件下，对服务端真实 gzip 响应的实际行为
///     （服务端实际收到的头值、`response.data` 运行时类型、
///     `content-encoding` 头解压后是否仍可见）；
///   - 实测二（§11.1 图序）：dio 5.11.1 三方向（onRequest / onResponse /
///     onError）的实际拦截器遍历序。计划 Assumptions 第 2 条已据源码预判
///     「三方向均按 Interceptors.add 添加顺序执行」，与详设 §11.1 图
///     「返回向自下而上」文字有出入，出入以实测为准并同批回写图注。
///
/// 全部用例走 MockApiServer（dart:io HttpServer 真栈，不引外网、不引新
/// 依赖），响应 gzip 字节由 dart:io GZipCodec 实体压缩。
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
// api_client.dart 已 re-export 三个真实拦截器（Header/Gzip/Envelope），
// 此处单 import 即取得生产装配同款类型，避免冗余 import。
import 'package:zhaoyazhao/core/network/api_client.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;

  setUp(() async {
    harness = NetworkChainHarness();
    await harness.start();
  });

  tearDown(() => harness.dispose());

  group('实测一：gzip 行为（§11.5，VM/dart:io IOHttpClientAdapter 真栈）', () {
    test('条件A：默认不注入时拦截器未写 Accept-Encoding；'
        '底层自动协商值由服务端侧记录并与「手工注入」区分', () async {
      harness.stub('GET', '/api/v1/gzip-default', (req) async {
        // MockResponse.gzip 要求的是「已实体压缩」的字节，必须用
        // dart:io gzip 编码，否则服务端声明 Content-Encoding: gzip 却发出
        // 明文，客户端解压会抛 Filter error（测试夹具自身失真）。
        return MockResponse.gzip(
          200,
          gzip.encode(
            utf8.encode(
              jsonEncode(
                ApiEnvelope.success(
                  data: <String, Object?>{'payload': 'A' * 512},
                  requestId: 'req_gzip_default',
                ),
              ),
            ),
          ),
        );
      });

      // 生产同款 dio（buildNetworkDio 装配 GzipInterceptor 默认态）。
      final response = await harness.dio.get<Object?>('/gzip-default');

      // 断言 1：GzipInterceptor 自身没有写该头——生产 dio 的
      // BaseOptions/拦截器链上不存在 Accept-Encoding 键（底层 HttpClient
      // 自动协商在 client 侧 headers 不可见，故服务端侧另做区分断言）。
      final baseHeaders = harness.dio.options.headers;
      expect(
        baseHeaders.keys.any((k) => k.toLowerCase() == 'accept-encoding'),
        isFalse,
        reason: '§11.5 默认取值不手动注入：拦截器/BaseOptions 均不得写该头',
      );

      // 断言 2：服务端实际收到的头值（dart:io HttpClient 自动协商的真实
      // 形态）——它来自底层而非拦截器，记录于测试名与注释以作区分。
      final seenAtServer = harness.server.lastRequest!.header('accept-encoding');
      // 不断言具体串（随 SDK 版本可能为 gzip 或 gzip, deflate, br 等），
      // 只断言底层确有自动协商：若底层不再自动添加，§11.5 结论需重审。
      expect(seenAtServer, isNotNull,
          reason: 'dart:io HttpClient 默认自动添加 Accept-Encoding（自动协商），'
              '该值非 GzipInterceptor 写入');

      // 断言 3（实证，非字符串断言）：响应已被自动解压并由
      // EnvelopeInterceptor 拆成信封 data，Map 类型即「自动解压」证据。
      expect(response.data, isA<Map>(),
          reason: '自动解压后 dio 拿到 JSON Map 而非未解压字节');
      final data = response.data! as Map;
      expect((data['payload'] as String).length, 512);

      // 断言 4（实测登记项）：dart:io 自动解压后，响应头中的
      // content-encoding 与 content-length 是否仍保留压缩态原值。
      // 实测值登记进 §11.5 实测结论；GzipInterceptor 的压缩后字节数正是
      // 依赖「解压后 content-length 头仍在」才能读到线上字节数，故这里对
      // 真实观察到的保留形态做机器断言（dart:io 保留压缩态响应头）。
      final contentEncodingAfterDecode =
          response.headers.value('content-encoding');
      final contentLengthAfterDecode =
          response.headers.value('content-length');
      expect(contentEncodingAfterDecode, 'gzip',
          reason: 'dart:io autoUncompress 解压实体但不移除 content-encoding '
              '响应头（实测，登记 §11.5）');
      expect(contentLengthAfterDecode, isNotNull,
          reason: '解压后 content-length 仍为压缩态字节数，体积统计据此读取');
      // ignore: avoid_print
      print('[U4实测一-条件A] data=${response.data.runtimeType} '
          'content-encoding=$contentEncodingAfterDecode '
          'content-length=$contentLengthAfterDecode '
          'server-seen-accept-encoding=$seenAtServer');
    });

    test('条件B：手工注入 Accept-Encoding: gzip 后 data 实际类型实证', () async {
      harness.stub('GET', '/api/v1/gzip-manual', (req) async {
        // 同条件A：发出真实 gzip 实体字节（见条件A夹具注释）。
        return MockResponse.gzip(
          200,
          gzip.encode(
            utf8.encode(
              jsonEncode(
                ApiEnvelope.success(
                  data: <String, Object?>{'payload': 'B' * 512},
                  requestId: 'req_gzip_manual',
                ),
              ),
            ),
          ),
        );
      });

      // 经单请求 Options 手工注入（§11.5 判定表第二行的可执行形态），
      // 不经 GzipInterceptor 的预留开关，保证实测的是「显式设置」本身
      // 对 dart:io 解压语义的影响，而非拦截器实现行为。
      Object? observed;
      String? observedTypeName;
      Object? thrown;
      String? contentEncodingHeader;
      try {
        final response = await harness.dio.get<Object?>(
          '/gzip-manual',
          options: Options(
            headers: {'Accept-Encoding': 'gzip'},
            // responseType 保持与生产一致（json），不改任何其他配置。
          ),
        );
        observed = response.data;
        contentEncodingHeader =
            response.headers.value('content-encoding');
      } on Object catch (error) {
        thrown = error;
      }
      observedTypeName =
          thrown == null ? observed.runtimeType.toString() : thrown.runtimeType.toString();

      // 服务端侧确认头确实由本次请求手工带到（区别于条件A的自动协商）。
      final seenAtServer = harness.server.lastRequest!.header('accept-encoding');
      expect(seenAtServer, 'gzip',
          reason: '手工注入经单请求 Options 必须逐字到达服务端');

      // 实测裁定（机器证据）：dart:io 即使应用层显式设置 Accept-Encoding，
      // HttpClient.autoUncompress 仍照常自动解压——data 是信封拆包后的
      // Map，而非 List<int>/Uint8List，也不抛「需自行解压」的错。
      // 因此「显式设置即需自行解压」的担忧在 5.11.1/当前 SDK 未复现，
      // §11.5 裁定「不手动注入」，理由是注入零收益（非注入会崩）。
      expect(thrown, isNull,
          reason: '手工注入后自动解压仍生效，不应抛解压异常；'
              '若此处抛错说明 §11.5 结论需按「注入会崩」重审');
      expect(observed, isA<Map>(),
          reason: '显式注入后 data 仍是拆包 Map（自动解压），实际类型见测试输出');
      expect((observed! as Map)['payload'], isA<String>());
      expect(((observed as Map)['payload'] as String).length, 512);
      expect(contentEncodingHeader, 'gzip',
          reason: '与条件A一致：解压后 content-encoding 响应头保留 gzip');
      // 类型名/头值进测试输出（print 只含类型名/头名等元数据，R16 安全）。
      // ignore: avoid_print
      print('[U4实测一-条件B] /gzip-manual data 运行时类型=$observedTypeName '
          'thrown=false content-encoding=$contentEncodingHeader');
    });
  });

  group('体积统计（R13：只统计，不压缩请求体）', () {
    test('gzip 响应：压缩后/解压后字节数写入 response.extra，data 正常拆包',
        () async {
      final plainBytes = utf8.encode(
        jsonEncode(
          ApiEnvelope.success(
            data: <String, Object?>{'repeat': 'C' * 1024},
            requestId: 'req_size_gzip',
          ),
        ),
      );
      harness.stub('GET', '/api/v1/size-gzip', (req) async {
        // 服务端发出的线上字节必须是 gzip 实体压缩结果。
        return MockResponse.gzip(200, gzip.encode(plainBytes));
      });

      final response = await harness.dio.get<Object?>('/size-gzip');

      final compressed = response.extra[GzipInterceptor.compressedBytesExtraKey];
      final uncompressed =
          response.extra[GzipInterceptor.uncompressedBytesExtraKey];
      final encoding = response.extra[GzipInterceptor.contentEncodingExtraKey];

      // 实测二结论：onResponse 按添加序执行，Gzip（第 2 位）先于 Envelope
      // （第 3 位）运行，故此刻 response.data 还是 dio 解码出的**完整信封**
      // Map；对它重新 jsonEncode+utf8 即服务端压缩前明文长度，逐字节相等，
      // 与「压缩后线上字节数」同口径（都是整个信封）。
      expect(uncompressed, plainBytes.length,
          reason: '解压后字节数按完整信封 utf8 重编码实测（Gzip 先于 Envelope）');
      // 压缩后字节数：有 content-length 时为整数；高重复文本 gzip 必更小。
      expect(compressed, isA<int>(),
          reason: 'gzip 响应有 Content-Length，压缩后字节数可读');
      expect(compressed as int, lessThan(plainBytes.length),
          reason: '1024 重复字符经 gzip 必显著缩小，佐证读到的是线上字节数');
      expect(encoding, 'gzip',
          reason: 'content-encoding 实际值原样登记（仅头名/值，非敏感数据）');
    });

    test('非 gzip JSON 响应：压缩后=Content-Length、解压后=明文长度、encoding=null',
        () async {
      final envelope = ApiEnvelope.success(
        data: <String, Object?>{'ok': true},
        requestId: 'req_size_plain',
      );
      final plainBytes = utf8.encode(jsonEncode(envelope));
      harness.stub('GET', '/api/v1/size-plain', (req) async {
        return MockResponse(status: 200, body: envelope);
      });

      final response = await harness.dio.get<Object?>('/size-plain');

      expect(response.extra[GzipInterceptor.uncompressedBytesExtraKey],
          plainBytes.length);
      // HttpServer 对普通 JSON 响应带 Content-Length；压缩后字节数就是它。
      final compressed = response.extra[GzipInterceptor.compressedBytesExtraKey];
      expect(compressed, isA<int>());
      expect(compressed as int, plainBytes.length,
          reason: '非 gzip 响应线上字节数即明文长度');
      expect(response.extra[GzipInterceptor.contentEncodingExtraKey], isNull,
          reason: '无 Content-Encoding 时登记 null，不猜值');
    });

    test('缺 Content-Length 头时降级为 null，不抛异常（统计永不阻断响应）',
        () async {
      final envelope = ApiEnvelope.success(
        data: <String, Object?>{'chunked': true},
        requestId: 'req_size_nolen',
      );
      harness.stub('GET', '/api/v1/size-nolen', (req) async {
        // 分块传输：mock 服务 omitContentLength 时不写 Content-Length，
        // dart:io HttpServer 自动改用 Transfer-Encoding: chunked
        // （受控头禁止调用方手写，由 HttpServer 决定传输编码）。
        return MockResponse.chunked(
          200,
          utf8.encode(jsonEncode(envelope)),
        );
      });

      final response = await harness.dio.get<Object?>('/size-nolen');
      expect(response.data, isNotNull, reason: '统计降级不得影响正常拆包');
      expect(response.extra[GzipInterceptor.compressedBytesExtraKey], isNull,
          reason: '缺 Content-Length 时压缩后字节数记 null（降级，不抛异常）');
      expect(response.extra[GzipInterceptor.uncompressedBytesExtraKey],
          isA<int>(),
          reason: '解压后长度不依赖 Content-Length，仍可测');
    });
  });

  group('实测二：dio 5.11.1 拦截器三方向执行序（§11.1 图）', () {
    /// 构造一条与生产同构（真实三类拦截器实例 + 同序添加）的链，在每个
    /// 真实拦截器之间插入只做有序标记的探针；探针不改变任何消息，
    /// 因此标记序即 dio 的实际遍历序。
    ///
    /// AuthRefresh/Retry 在 U5/U6 落地，当前链上只有 Header→Gzip→
    /// Envelope 三个真实拦截器，三方向序均可实测（onError 由 Envelope
    /// 对非信封 500 的 reject 触发）。
    Dio buildProbedDio(String baseUrl, List<String> trace) {
      final dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          validateStatus: (_) => true,
          responseType: ResponseType.json,
        ),
      );
      dio.interceptors.add(HeaderInterceptor(harness.hooksForProbe()));
      dio.interceptors.add(_MarkerInterceptor('Header', trace));
      dio.interceptors.add(const GzipInterceptor());
      dio.interceptors.add(_MarkerInterceptor('Gzip', trace));
      dio.interceptors.add(const EnvelopeInterceptor());
      dio.interceptors.add(_MarkerInterceptor('Envelope', trace));
      return dio;
    }

    test('onRequest 与 onResponse 均按添加序执行（FIFO）：实测证伪图注倒序',
        () async {
      final trace = <String>[];
      final dio = buildProbedDio(await harness.serverBaseUrl(), trace);
      addTearDown(dio.close);

      harness.stub('GET', '/api/v1/order-ok', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {'ok': true}, requestId: 'req_order'),
        );
      });

      await dio.get<Object?>('/order-ok');

      // 探针位于各真实拦截器「之后」添加：探针标记序即真实拦截器序。
      final requestOrder = trace
          .where((e) => e.endsWith(':onRequest'))
          .map((e) => e.split(':').first)
          .toList();
      expect(requestOrder, ['Header', 'Gzip', 'Envelope'],
          reason: '发出向：dio 5.11.1 按 Interceptors.add 顺序执行');

      // 实测：onResponse 同样按添加序执行（Header→Gzip→Envelope），并非
      // §11.1 图注所称「自下而上」倒序。源码 dio_mixin.dart 的 response
      // 链是对同一 future 依添加序逐个 .then 串联，无 reversed。
      // 该出入按计划 Assumptions 第 2 条「以实测为准」，U4 同批回写图注。
      // 直接后果：Gzip（第 2 位）在 Envelope（第 3 位）拆包前统计，量到
      // 的是完整信封明文——体积统计口径以此为准。
      final responseOrder = trace
          .where((e) => e.endsWith(':onResponse'))
          .map((e) => e.split(':').first)
          .toList();
      expect(responseOrder, ['Header', 'Gzip', 'Envelope'],
          reason: '返回向实测为添加序（FIFO），与图注「自下而上」不符，'
              '按 Assumptions 第 2 条回写图注');
    });

    test('onError 按添加序执行（FIFO，非信封 500 触发）：KTD2 承重前提成立',
        () async {
      final trace = <String>[];
      final dio = buildProbedDio(await harness.serverBaseUrl(), trace);
      addTearDown(dio.close);

      harness.stub('GET', '/api/v1/order-500', (req) async {
        // 网关直出 HTML 500：Envelope 在 onResponse 非 Map 分流必
        // reject(networkFailure, callFollowing=true)，错误随后进入
        // onError 链。
        return MockResponse.raw(500, utf8.encode('<html>boom</html>'));
      });

      try {
        await dio.get<Object?>('/order-500');
        fail('非信封 500 必须 reject 到调用方');
      } on Object {
        // 预期落调用方；本用例只关心 error 向遍历序。
      }

      final errorOrder = trace
          .where((e) => e.endsWith(':onError'))
          .map((e) => e.split(':').first)
          .toList();
      // 实测：dio 的 error 链是对同一 future 依添加序逐个 catchError
      // 串联（无 reversed）。Envelope 在 onResponse 内 reject 后，错误
      // 从链头按添加序穿过各 onError，故序为 Header→Gzip→Envelope。
      // 这正是 KTD2「reject(err, true) 让 40101 流向后续 AuthRefresh」与
      // KTD10「Retry 为链尾 error 归一点」的承重前提（Assumptions 第 2 条）：
      // 错误按添加序前进，第 4/5 位的 AuthRefresh/Retry 才能接到前序 reject。
      expect(errorOrder, ['Header', 'Gzip', 'Envelope'],
          reason: '错误向实测为添加序（FIFO）：KTD2/KTD10 承重前提成立，'
              '停止条件（证伪 onError 按添加序）未触发');
    });
  });

  group('R16 日志纪律（探针/统计产物无 Authorization 与 Token 字面量）', () {
    test('带 Token 请求跑完整链，日志候选产物 grep 不到 token 串', () async {
      // 刻意构造高辨识度 token，任何泄漏都会被全文匹配捕获。
      const secretToken = 'Bearer SECRET-U4-TOKEN-7f3c9a1e5b8d4026';
      harness.token = 'SECRET-U4-TOKEN-7f3c9a1e5b8d4026';
      harness.privacyConsented = true;
      harness.deviceId = 'device-u4-0001';

      final logProbe = <String>[];
      harness.stub('GET', '/api/v1/r16-ping', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {'ok': true}, requestId: 'req_r16'),
        );
      });

      // GzipInterceptor 的统计回调即「日志候选内容」：只允许
      // path/状态码/字节数/头名与类型名。
      final dio = Dio(
        BaseOptions(
          baseUrl: await harness.serverBaseUrl(),
          validateStatus: (_) => true,
          responseType: ResponseType.json,
          headers: {'Authorization': secretToken},
        ),
      );
      dio.interceptors.add(HeaderInterceptor(harness.hooksForProbe()));
      dio.interceptors.add(
        GzipInterceptor(
          onStats: (stats) => logProbe.add(
            'path=${stats.path} code=${stats.statusCode} '
            'wire=${stats.compressedBytes} json=${stats.uncompressedBytes} '
            'encoding=${stats.contentEncoding}',
          ),
        ),
      );
      dio.interceptors.add(const EnvelopeInterceptor());
      addTearDown(dio.close);

      final response = await dio.get<Object?>('/r16-ping');
      expect(response.data, {'ok': true});

      // 探针全文（模拟真实日志行）不得包含 token 的任何片段。
      final probeText = logProbe.join('\n');
      expect(probeText, isNot(contains('SECRET-U4-TOKEN')));
      expect(probeText, isNot(contains('Bearer')));
      expect(probeText, isNot(contains('Authorization')));
      // 产物只含允许的元数据字段。
      expect(logProbe.single, startsWith('path=/r16-ping code=200 wire='));
    });
  });
}

/// 顺序探针拦截器：三方向各只追加一条标记，不改变消息流向。
///
/// 为什么独立于生产代码：探针仅服务 §11.1 实测，进入生产链会污染体积
/// 统计与 R16 日志面；放测试文件内保证「实测代码不进 lib/」。
class _MarkerInterceptor extends Interceptor {
  /// 构造探针。
  ///
  /// 参数：
  ///   [name]  被标记的真实拦截器名（Header/Gzip/Envelope）；
  ///   [trace] 有序标记收集列表。
  _MarkerInterceptor(this.name, this.trace);

  /// 真实拦截器名。
  final String name;

  /// 标记收集列表。
  final List<String> trace;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) {
    trace.add('$name:onRequest');
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    trace.add('$name:onResponse');
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    trace.add('$name:onError');
    handler.next(err);
  }
}
