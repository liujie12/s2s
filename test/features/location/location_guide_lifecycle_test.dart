/// 定位引导页生命周期复评测试（DEF-02 回归）。
///
/// 锁定缺陷场景：用户按「去系统设置打开」授权后返回 App，引导页必须重新评估
/// 权限态，而不是停在「定位被关掉了」直到杀进程重启。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/location_guide.dart';
import 'package:zhaoyazhao/features/location/location_permission.dart';

/// 计数用假 Notifier：固定停在 B 态，只记录 [evaluate] 被调用次数。
class _CountingLocationPermission extends LocationPermissionNotifier {
  /// [evaluate] 调用次数。
  int evaluateCalls = 0;

  /// 初始态固定为 B（曾授权后被关），不触发真实权限读取。
  ///
  /// 参数：无。
  /// 返回：固定返回 [LocationPermissionPhase.revoked]。
  @override
  LocationPermissionPhase build() => LocationPermissionPhase.revoked;

  /// 记录一次复评调用，不做真实权限查询。
  ///
  /// 参数：无。
  /// 返回：无。
  @override
  Future<void> evaluate() async {
    evaluateCalls += 1;
  }
}

void main() {
  testWidgets('App 回到前台（resumed）时重新评估定位权限', (tester) async {
    final fake = _CountingLocationPermission();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [locationPermissionProvider.overrideWith(() => fake)],
        child: const MaterialApp(home: LocationGuide()),
      ),
    );
    await tester.pump();

    expect(fake.evaluateCalls, 0, reason: '首帧不应额外复评');
    expect(find.text('定位被关掉了'), findsOneWidget);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(fake.evaluateCalls, 1, reason: '从系统设置返回必须复评一次');
  });
}
