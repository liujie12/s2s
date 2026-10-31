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

  group('推送点击落点（R16a）', () {
    test('payload 为 JSON 字符串：解析出会话落点与目标 ID', () {
      final target = pushClickTargetOf({
        'payload': '{"type":"interaction","targetId":42,"landingType":"conversation"}',
      });

      expect(target?.landingType, pushLandingConversation);
      expect(target?.targetId, 42);
      expect(target?.opensConversation, isTrue);
    });

    test('payload 已是 Map：同样可解析', () {
      final target = pushClickTargetOf({
        'payload': {'landingType': 'conversation', 'targetId': 7},
      });

      expect(target?.targetId, 7);
    });

    test('厂商把落点放进 extra（JSON 字符串）也能解析', () {
      final target = pushClickTargetOf({
        'extra': '{"landingType":"conversation","targetId":"9"}',
      });

      expect(target?.targetId, 9);
    });

    test('无落点类型：返回 null，点击退回默认行为', () {
      expect(pushClickTargetOf({'content': '你有一条新消息'}), isNull);
      expect(pushClickTargetOf({'payload': '不是 JSON'}), isNull);
      expect(
        pushClickTargetOf({'payload': '{"type":"cert"}'}),
        isNull,
      );
    });

    test('会话落点缺 targetId：不认为可直接打开会话', () {
      final target = pushClickTargetOf({'payload': '{"landingType":"conversation"}'});

      expect(target?.opensConversation, isFalse);
    });
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
