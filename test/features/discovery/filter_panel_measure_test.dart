/// 筛选面板的图层切换起点接线单测（[140]）。
///
/// 面板被地图页与列表页复用（PRD §10.1），但只有地图页能成为一次图层切换的
/// 起点 —— 列表页没有 Pin 渲染终点，会话收不了尾。本测试锁这个开关，
/// 并锁「已是全部时再点」不产生零耗时假样本。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/filter_panel.dart';
import 'package:zhaoyazhao/features/perf/layer_switch_recorder.dart';

void main() {
  /// 渲染筛选面板并返回其 Provider 容器。
  ///
  /// 参数：
  /// - [tester]：测试器；
  /// - [measure]：是否把分类切换计为图层切换（地图页 true / 列表页 false）。
  ///
  /// 返回：[ProviderContainer] 供断言记录器状态。
  Future<ProviderContainer> pumpPanel(
    WidgetTester tester, {
    required bool measure,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: FilterPanel(measureLayerSwitch: measure),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('地图页：点分类胶囊开一次切换会话', (tester) async {
    final container = await pumpPanel(tester, measure: true);

    await tester.tap(find.text('房屋'));
    await tester.pump();

    expect(
      container.read(layerSwitchRecorderProvider).hasActiveSession,
      isTrue,
      reason: '地图页的分类点击必须成为判据 A 的计时起点',
    );
  });

  testWidgets('列表页：同样的点击不开会话（无 Pin 渲染终点）', (tester) async {
    final container = await pumpPanel(tester, measure: false);

    await tester.tap(find.text('房屋'));
    await tester.pump();

    expect(
      container.read(layerSwitchRecorderProvider).hasActiveSession,
      isFalse,
      reason: '列表页没有 Pin 首屏绘制，会话会永远收不了尾',
    );
  });

  testWidgets('已是「全部」时再点：不开新会话（防零耗时假样本拉低 P95）', (tester) async {
    final container = await pumpPanel(tester, measure: true);

    await tester.tap(find.text('全部'));
    await tester.pump();

    expect(
      container.read(layerSwitchRecorderProvider).hasActiveSession,
      isFalse,
      reason: '筛选态未改变不构成一次切换',
    );
  });
}
