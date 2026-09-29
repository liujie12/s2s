/// POC-B 性能面板 widget 测试（2026-09-29 真机溢出缺陷的回归锁）。
///
/// **回归对象**：折叠态胶囊原先锁死 96px 宽，内容为「图标 + P95 读数 + 展开箭头」。
/// 读数 "P95 45.7ms" 时固定项约 85.3px，而可用宽仅 80px（96 − 2×8 内边距），
/// 于是在**真机上**画出黄黑条纹（`RenderFlex overflowed by 5.3 pixels`）。
/// 该溢出与读数长度、字体度量都相关，故不能靠「把 96 调大」消除。
///
/// 本测试在手机尺寸下用较长的读数渲染，断言**没有 layout 异常** ——
/// 溢出属 layout 期异常，会经 `tester.takeException()` 取到。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/perf/frame_metrics.dart';
import 'package:zhaoyazhao/features/perf/perf_panel.dart';

void main() {
  /// 以手机尺寸渲染面板。
  ///
  /// 为什么必须显式设视口：`testWidgets` 默认视口 800×600，比真机宽得多，
  /// 会让面板拿到过宽的行约束，从而漏掉只在真机出现的溢出。
  ///
  /// 参数：
  /// - [tester]：测试器。
  /// - [p95Ms]：注入的帧耗时样本（单样本时 P95 即该值，见 FrameMetrics 的最近秩法）。
  ///
  /// 返回：[Future<void>] 面板完成布局后的 Future。
  Future<void> pumpPanelAtPhoneSize(
    WidgetTester tester, {
    required double p95Ms,
  }) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final metrics = FrameMetrics()..addSampleMs(p95Ms);
    addTearDown(metrics.stop);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [frameMetricsProvider.overrideWithValue(metrics)],
        child: const MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(right: 12, bottom: 12, child: PerfPanel()),
              ],
            ),
          ),
        ),
      ),
    );
    // 面板每秒自调度一帧（递归 addPostFrameCallback），pumpAndSettle 会超时，
    // 故只泵固定帧数。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('折叠态：读数偏长时不得溢出（真机 5.3px 溢出回归）', (tester) async {
    await pumpPanelAtPhoneSize(tester, p95Ms: 145.7);

    expect(find.text('P95 145.7ms'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '折叠态胶囊必须容得下读数，否则真机画出黄黑条纹',
    );
  });

  testWidgets('折叠态：常规读数（真机复现的那一档）不得溢出', (tester) async {
    await pumpPanelAtPhoneSize(tester, p95Ms: 45.7);

    expect(find.text('P95 45.7ms'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开态：切到展开后也不得溢出', (tester) async {
    await pumpPanelAtPhoneSize(tester, p95Ms: 45.7);

    await tester.tap(find.text('P95 45.7ms'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '展开态含直方图等更多内容，同样不得溢出');
  });
}
