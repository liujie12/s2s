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
import 'package:zhaoyazhao/features/perf/layer_switch_recorder.dart';
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

  testWidgets('档位行默认隐藏，连点标题 7 次才解锁（防误触换上假数据）', (tester) async {
    await pumpPanelAtPhoneSize(tester, p95Ms: 12.0);

    // 注意：初始为收起态，故**奇数次**点击才是展开态。断言必须落在展开态上，
    // 否则「没看到档位」会被「已收起」污染，测不出真正想测的隐藏。
    Future<void> tapHeader() async {
      await tester.tap(find.text('P95 12.0ms'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
    }

    await tapHeader(); // 1 次：展开，未解锁
    expect(
      find.text('1 万点'),
      findsNothing,
      reason: '档位行默认不得渲染 —— 它会换上 1 万/5 万假数据，误触后表现为「数据错了」',
    );

    for (int i = 0; i < 4; i++) {
      await tapHeader(); // 累计 5 次：展开态、仍未达解锁阈值
    }
    expect(find.text('1 万点'), findsNothing, reason: '未达 7 次不得解锁');

    await tapHeader(); // 第 6 次
    await tapHeader(); // 第 7 次：展开态 + 达阈值，应解锁
    expect(find.text('1 万点'), findsOneWidget, reason: '连点 7 次后档位行必须可用');
    expect(tester.takeException(), isNull);
  });

  testWidgets('展开态：显示图层切换 P95 与四段分解（[140]）', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    final metrics = FrameMetrics()..addSampleMs(12.0);
    addTearDown(metrics.stop);

    // 造一条 success 样本：start → 渲染段 → 收尾。
    final switches = LayerSwitchRecorder();
    switches.start();
    switches.markRenderStart();
    switches.finish(
      sessionId: switches.activeSessionId!,
      outcome: LayerSwitchOutcome.success,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          frameMetricsProvider.overrideWithValue(metrics),
          layerSwitchRecorderProvider.overrideWithValue(switches),
        ],
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 展开：面板初始为收起态，点一次标题即展开。
    await tester.tap(find.text('P95 12.0ms'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('图层切换'), findsOneWidget);
    // 判据（轴② 占比）与工程 SLA（切换 P95）两条线都必须可读且分列。
    expect(find.text('轴② 占比'), findsOneWidget);
    expect(find.text('切换 P95'), findsOneWidget);
    expect(find.text('缓/网/聚/绘'), findsOneWidget);
    expect(find.text('切换样本'), findsOneWidget);
    expect(
      tester.takeException(),
      isNull,
      reason: '新增读数行不得让展开态溢出（该面板压在真机地图角上）',
    );
  });
}
