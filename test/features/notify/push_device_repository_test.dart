/// 推送设备上报仓库测试（B2-2 阶段 2）。
///
/// 走 NetworkChainHarness 生产同款五拦截器链 + MockApiServer 真 HTTP 栈；
/// 断言：请求体契约字段、响应解析、业务错误抛 ApiException、未知通道按契约违约处理。
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/notify/push_device_repository.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

void main() {
  late NetworkChainHarness harness;
  late PushDeviceRepository repo;

  setUp(() async {
    harness = NetworkChainHarness(retrySleeper: (_) async {});
    await harness.start();
    repo = PushDeviceRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('upsert', () {
    test('成功：请求体为 platform/token，解析 device_id 与通道', () async {
      late Map<String, Object?> sentBody;
      harness.stub('POST', '/api/v1/users/me/devices', (req) async {
        sentBody = (req.body as Map).cast<String, Object?>();
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'device_id': 12,
            'platform': 'mi',
          }),
        );
      });

      final result = await repo.upsert(
        channel: PushChannel.mi,
        token: 'reg-token-1',
        interactionId: 'it-1',
      );

      expect(sentBody['platform'], 'mi');
      expect(sentBody['token'], 'reg-token-1');
      expect(result.deviceId, 12);
      expect(result.channel, PushChannel.mi);
    });

    test('业务错误：40001 抛 ApiException', () async {
      harness.stub('POST', '/api/v1/users/me/devices', (req) async {
        return MockResponse(body: ApiEnvelope.failure(40001, '参数非法'));
      });

      await expectLater(
        repo.upsert(channel: PushChannel.hw, token: 'token'),
        throwsA(
          isA<DioException>().having((e) => e.error, 'error', isA<ApiException>()),
        ),
      );
    });

    test('响应通道未知：按契约违约抛解析异常', () async {
      harness.stub('POST', '/api/v1/users/me/devices', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {
            'device_id': 1,
            'platform': 'unknown',
          }),
        );
      });

      await expectLater(
        repo.upsert(channel: PushChannel.mi, token: 't'),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
