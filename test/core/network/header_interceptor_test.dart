/// HeaderInterceptor 测试（详细设计 §11.1/§11.1.1/§11.2，计划 R7 / U3）。
///
/// 覆盖请求头纪律的全部机器断言（编码规范 §5.3）：
///   1. 三头 containsKey 才写：调用方经 Options 透传的值绝不被覆盖，
///      未透传时由拦截器兜底生成（§11.1.1）；
///   2. Authorization 是唯一「每次重写」的头：登录态变化后带新 Token，
///      未登录时**头键不存在**（非空串，§11.2）；
///   3. Idempotency-Key 仅 POST/PATCH 注入，GET 不注入（§11.2）；
///   9. 隐私同意前无 X-Device-Id，同意后注入（R7，PRD §6.5.1 隐私门）。
///
/// 走生产同款 harness（真实 HTTP 栈 + 完整拦截器链），断言落在 mock 服务
/// 实际收到的请求头上 —— 只在 dio 内存对象上断言证明不了真的发出去了。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/network_chain_harness.dart';
import '../../support/test_support.dart';

/// mock 服务统一前缀（mock 按含前缀的 `uri.path` 匹配路由）。
const String _apiPrefix = '/api/v1';

void main() {
  late NetworkChainHarness harness;

  /// 登记一个回 200 信封的通用桩并发起请求，返回服务端实际看到的请求。
  ///
  /// [path] 为**不含** [_apiPrefix] 的逻辑路径（如 `/echo`）：dio 的
  /// baseUrl 已含前缀，请求走逻辑路径；桩键按 mock 匹配规则补全前缀。
  /// 两处形态不同（与契约示范测试一致：那里 dio 发 `/ping`、桩登记
  /// `/api/v1/ping`）。
  Future<MockRequest> echoRequest(
    String method,
    String path, {
    Options? options,
  }) async {
    harness.stub(method, '$_apiPrefix$path', (req) async {
      return MockResponse(body: ApiEnvelope.success(data: {'seen': true}));
    });
    switch (method) {
      case 'GET':
        await harness.dio.get<Object?>(path, options: options);
      case 'POST':
        await harness.dio.post<Object?>(path, data: const {}, options: options);
      case 'PATCH':
        await harness.dio.patch<Object?>(path, data: const {}, options: options);
      default:
        throw ArgumentError('echoRequest 未覆盖方法：$method');
    }
    return harness.server.received.single;
  }

  setUp(() async {
    harness = NetworkChainHarness();
    await harness.start();
  });

  tearDown(() => harness.dispose());

  group('三头 containsKey 才写（§11.1.1）', () {
    test('调用方透传的三头逐字保留，拦截器不覆盖（POST）', () async {
      // 隐私先同意，保证 X-Device-Id 具备注入条件；三头值仍应取透传值。
      harness.privacyConsented = true;
      harness.deviceId = TestFixtures.deviceId;
      harness.token = 'token-A';

      final req = await echoRequest(
        'POST',
        '/echo',
        options: Options(headers: {
          'X-Interaction-Id': TestFixtures.interactionId,
          'X-Device-Id': TestFixtures.deviceId,
          'Idempotency-Key': TestFixtures.idempotencyKey,
        }),
      );

      expect(req.header('x-interaction-id'), TestFixtures.interactionId);
      expect(req.header('x-device-id'), TestFixtures.deviceId);
      expect(req.header('idempotency-key'), TestFixtures.idempotencyKey);
      expect(harness.uuidCallCount, 0,
          reason: '三头全部由调用方透传时，拦截器不得生成任何 UUID（§11.1.1）');
    });

    test('三头均未透传时由拦截器兜底生成（POST，全部补齐）', () async {
      harness.privacyConsented = true;
      harness.deviceId = TestFixtures.deviceId;

      final req = await echoRequest('POST', '/echo');

      expect(req.header('x-interaction-id'), isNotNull,
          reason: 'X-Interaction-Id 缺失时拦截器兜底补 UUID v4（§11.2）');
      expect(req.header('x-device-id'), TestFixtures.deviceId);
      expect(req.header('idempotency-key'), isNotNull,
          reason: 'POST 缺键时兜底注入幂等键（§11.2）');
      // 三头中 interaction 与 idempotency 两个由生成器产出，设备 ID 走存储。
      expect(harness.uuidCallCount, 2,
          reason: '兜底生成 X-Interaction-Id 与 Idempotency-Key 各一次');
    });

    test('只透传 Idempotency-Key 时其余两头按各自规则处理（部分透传）', () async {
      final req = await echoRequest(
        'POST',
        '/echo',
        options: Options(headers: {'Idempotency-Key': TestFixtures.idempotencyKey}),
      );

      expect(req.header('idempotency-key'), TestFixtures.idempotencyKey);
      expect(req.header('x-interaction-id'), isNotNull,
          reason: '未透传的交互 ID 仍须兜底生成');
      expect(req.header('x-device-id'), isNull,
          reason: '隐私未同意，设备 ID 键不得出现（与透传无关）');
      expect(harness.uuidCallCount, 1, reason: '仅 X-Interaction-Id 走生成器');
    });
  });

  group('Authorization 每次重写、未登录不注入（§11.2）', () {
    test('带 Token 时注入 Bearer 形态', () async {
      harness.token = 'token-A';
      final req = await echoRequest('GET', '/echo');
      expect(req.header('authorization'), 'Bearer token-A');
    });

    test('同一 dio 上登录态变化后重写为新 Token（不保留旧值）', () async {
      harness.stub('GET', '$_apiPrefix/echo',
          (req) async => MockResponse(body: ApiEnvelope.success()));

      harness.token = 'token-A';
      await harness.dio.get<Object?>('/echo');
      expect(harness.server.received[0].header('authorization'), 'Bearer token-A');

      // 切换登录态（模拟续期/换账号）：Authorization 是唯一每次重写的头，
      // 不能走「缺失才写」，否则重放会带着旧 Token 再吃一次 40101。
      harness.token = 'token-B';
      await harness.dio.get<Object?>('/echo');
      expect(harness.server.received[1].header('authorization'), 'Bearer token-B');
    });

    test('未登录时请求头中无 Authorization 键（不是空串）', () async {
      // token 保持 null：服务端要处理的是「头不存在」这一种形态。
      final req = await echoRequest('GET', '/echo');
      expect(req.headers.containsKey('authorization'), isFalse,
          reason: '未登录不注入 Authorization，连空串都不写（§11.2）');
    });
  });

  group('幂等键仅写接口注入（§11.2）', () {
    test('GET 请求无 Idempotency-Key', () async {
      final req = await echoRequest('GET', '/echo');
      expect(req.headers.containsKey('idempotency-key'), isFalse);
      expect(harness.uuidCallCount, 1,
          reason: 'GET 仍兜底生成 X-Interaction-Id，但不生成幂等键');
    });

    test('POST 请求注入 Idempotency-Key', () async {
      final req = await echoRequest('POST', '/echo');
      expect(req.header('idempotency-key'), isNotNull);
    });

    test('PATCH 请求注入 Idempotency-Key', () async {
      final req = await echoRequest('PATCH', '/echo');
      expect(req.header('idempotency-key'), isNotNull);
    });
  });

  group('隐私同意门（R7 / PRD §6.5.1）', () {
    test('同意态回调为 false 时无 X-Device-Id 键（即使设备 ID 已存在）', () async {
      harness.privacyConsented = false;
      harness.deviceId = TestFixtures.deviceId;

      final req = await echoRequest('GET', '/echo');

      expect(req.headers.containsKey('x-device-id'), isFalse,
          reason: '隐私门是硬门：同意前设备标识不得外发，与设备 ID 是否已生成无关');
    });

    test('同意态回调为 true 后注入 X-Device-Id（同一 harness 两态各断言）', () async {
      harness.privacyConsented = false;
      harness.deviceId = TestFixtures.deviceId;
      harness.stub('GET', '$_apiPrefix/echo',
          (req) async => MockResponse(body: ApiEnvelope.success()));

      await harness.dio.get<Object?>('/echo');
      expect(harness.server.received[0].headers.containsKey('x-device-id'),
          isFalse);

      // 用户在隐私门点同意：下一请求起注入设备 ID（不重建 dio，回调实时读）。
      harness.privacyConsented = true;
      await harness.dio.get<Object?>('/echo');
      expect(harness.server.received[1].header('x-device-id'),
          TestFixtures.deviceId);
    });
  });
}
