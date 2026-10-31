/// 未读角标桥测试（计划 U14；R9 / R11 / KTD13 / KTD14）。
///
/// 覆盖三件事：
///   1. 桌面角标只消费未读总数，且与 Tab「99+」同源（上限 99）；
///   2. 0 表示清除，仍下发一次（否则旧角标会留在桌面）；
///   3. iOS 不调用原生通道；原生回执的降级原因能解析出来。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/badge/app_badge.dart';
import 'package:zhaoyazhao/features/message/message_list_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(AppBadge.channelName);
  late List<int> sentCounts;
  late AppBadge badge;

  setUp(() {
    sentCounts = <int>[];
    badge = AppBadge(channel: channel);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  /// 打桩原生通道，并记录每次下发的 count。
  ///
  /// 参数：[response] 原生回执。
  void stubNative(Map<String, Object?> response) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, AppBadge.methodSetBadge);
      sentCounts.add((call.arguments as Map)['count']! as int);
      return response;
    });
  }

  test('未读 12 → 下发 12；120 → 下发 99（与 Tab 的 99+ 同源）', () async {
    stubNative({'applied': true, 'degraded': null});

    await badge.apply(12);
    await badge.apply(120);

    expect(sentCounts, [12, 99]);
    expect(unreadBadgeLabel(120), '99+');
  });

  test('未读 0 → 下发 0（清除桌面角标）', () async {
    stubNative({'applied': true, 'degraded': null});

    await badge.apply(0);

    expect(sentCounts, [0]);
  });

  test('原生降级为红点时带回降级原因', () async {
    stubNative({'applied': true, 'degraded': 'dot_fallback'});

    final result = await badge.apply(5);

    expect(result.applied, isTrue);
    expect(result.degraded, isTrue);
    expect(result.degradedReason, 'dot_fallback');
  });

  test('原生完全不可用时 applied=false，不抛异常', () async {
    stubNative({'applied': false, 'degraded': 'unsupported_launcher'});

    final result = await badge.apply(5);

    expect(result.applied, isFalse);
    expect(result.degradedReason, 'unsupported_launcher');
  });

  test('iOS 不调用原生通道（R11：本期只做 Android）', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    stubNative({'applied': true, 'degraded': null});

    final result = await badge.apply(8);

    expect(result.applied, isFalse);
    expect(result.degradedReason, 'unsupported_platform');
    expect(sentCounts, isEmpty);
  });
}
