/// 推送服务测试（B2-2 阶段 2）。
///
/// 覆盖：注册成功 → 取 token → 上报；未配置凭据 → 不上报；
/// 通知权限透传；原生 `onToken` 事件 → 补报。
/// HTTP 侧由注入的假 reporter 承接（真实上报解析见 push_device_repository_test）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/notify/push_device_repository.dart';
import 'package:zhaoyazhao/features/notify/push_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(PushService.channelName);
  late PushService service;
  late List<(PushChannel, String)> reported;

  setUp(() {
    reported = <(PushChannel, String)>[];
    service = PushService(
      (channel, token) async => reported.add((channel, token)),
      channel: channel,
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await service.dispose();
  });

  /// 打桩原生通道。
  ///
  /// 参数：[register] 注册返回值；[token] getToken 返回值。
  void stubNative({required Object? register, String? token}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return switch (call.method) {
        PushService.methodRegister => register,
        PushService.methodGetToken => token,
        _ => null,
      };
    });
  }

  test('注册成功：取 token 并上报 mi 通道', () async {
    stubNative(register: PushService.statusOk, token: 'reg-id-1');

    await service.registerIfAvailable();

    expect(reported, [(PushChannel.mi, 'reg-id-1')]);
  });

  test('未配置凭据：不读 token、不上报', () async {
    stubNative(register: 'not_configured');

    await service.registerIfAvailable();

    expect(reported, isEmpty);
  });

  test('通知权限：透传原生返回值', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, PushService.methodRequestPermission);
      return true;
    });

    expect(await service.requestPermission(), isTrue);
  });

  test('原生 onToken 事件：补报新 token', () async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      PushService.channelName,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall(PushService.eventToken, 'reg-id-2')),
      (_) {},
    );

    expect(reported, [(PushChannel.mi, 'reg-id-2')]);
  });
}
