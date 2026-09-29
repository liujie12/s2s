/// 隐私协议门 widget 测试（2026-09-29 真机阻断缺陷的回归锁）。
///
/// **回归对象**：首次启动（本地无同意记录）时 `_load()` 得到 `notAgreed`，
/// 若界面据此翻成受限态，用户来不及点「同意」就已被挡住；此时唯一的
/// 「重新阅读协议」又只是重读盘，结果仍是 `notAgreed` —— 界面原地打转，
/// 应用彻底进不去（真机实测命中，见 privacy_gate_screen.dart 类注释）。
///
/// 覆盖四条：① 首启停在协议页 ② 点「不同意」进受限态
/// ③「重新阅读协议」能回到协议页 ④ 点「同意并继续」真的落盘（冷启动后仍为已同意）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/features/privacy/privacy_consent.dart';
import 'package:zhaoyazhao/features/privacy/privacy_gate_screen.dart';

void main() {
  /// 渲染协议门并等待读盘完成。
  ///
  /// 参数：
  /// - [tester]：测试器。
  /// - [container]：可选外部容器，用于断言同意状态；不传则用默认容器。
  ///
  /// 返回：[Future<void>] 界面稳定后的 Future。
  Future<void> pumpGate(WidgetTester tester, {ProviderContainer? container}) async {
    const screen = MaterialApp(home: PrivacyGateScreen());
    await tester.pumpWidget(
      container == null
          ? const ProviderScope(child: screen)
          : UncontrolledProviderScope(container: container, child: screen),
    );
    // 读盘走 mock method channel（微任务，不经帧管线），pumpAndSettle 即可推进并等稳定
    // （同 category_selector_screen_test 的既有写法）。
    //
    // 注意：此处不可用 pumpEventQueue —— 它内部靠 Future.delayed 循环，在 testWidgets
    // 的假时钟下没有显式 pump 推进就永不返回，本文件首版曾因此整进程卡死。
    await tester.pumpAndSettle();
  }

  testWidgets('首启无同意记录：停在协议页，不得翻成受限态', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});

    await pumpGate(tester);

    expect(find.text('同意并继续'), findsOneWidget, reason: '首启必须留有同意入口');
    expect(
      find.textContaining('你尚未同意隐私政策'),
      findsNothing,
      reason: '「本地无同意记录」不是「用户已拒绝」，不得进受限态',
    );
  });

  testWidgets('点「不同意」进受限态，点「重新阅读协议」可回到协议页', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});

    await pumpGate(tester);

    await tester.tap(find.text('不同意'));
    await tester.pumpAndSettle();
    expect(find.text('地图功能需要你的同意'), findsOneWidget);
    expect(find.text('同意并继续'), findsNothing);

    await tester.tap(find.text('重新阅读协议'));
    await tester.pumpAndSettle();
    expect(find.text('同意并继续'), findsOneWidget, reason: '受限态必须留有改主意的入口');
  });

  testWidgets('点「同意并继续」：转已同意，且冷启动后仍为已同意', (tester) async {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await pumpGate(tester, container: container);

    await tester.tap(find.text('同意并继续'));
    await tester.pumpAndSettle();
    expect(container.read(privacyConsentProvider), PrivacyConsentStatus.agreed);

    // 模拟冷启动：换一个容器重新读盘，必须是 agreed（证明真的落了盘，
    // 而不是只在内存里放行 —— 否则用户会认为「我明明同意过」）。
    final restarted = ProviderContainer();
    addTearDown(restarted.dispose);
    restarted.read(privacyConsentProvider);
    await tester.pump(); // 推进假时钟，让 mock 通道的读盘 Future 落地
    expect(
      restarted.read(privacyConsentProvider),
      PrivacyConsentStatus.agreed,
      reason: '同意必须落盘，冷启动不得重弹协议门',
    );
  });
}
