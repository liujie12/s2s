/// 筛选面板的图层切换起点接线单测（[140]）。
///
/// 面板被地图页与列表页复用（PRD §10.1），但只有地图页能成为一次图层切换的
/// 起点 —— 列表页没有 Pin 渲染终点，会话收不了尾。本测试锁这个开关，
/// 并锁「已是全部时再点」不产生零耗时假样本。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';
import 'package:zhaoyazhao/features/discovery/effective_filter_provider.dart';
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
          home: Scaffold(body: FilterPanel(measureLayerSwitch: measure)),
        ),
      ),
    );
    return container;
  }

  testWidgets('地图页：点分类胶囊开一次切换会话', (tester) async {
    final container = await pumpPanel(tester, measure: true);

    await tester.ensureVisible(find.text('房屋'));
    await tester.pumpAndSettle();
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

    await tester.ensureVisible(find.text('房屋'));
    await tester.pumpAndSettle();
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

    await tester.ensureVisible(find.text('全部'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pump();

    expect(
      container.read(layerSwitchRecorderProvider).hasActiveSession,
      isFalse,
      reason: '筛选态未改变不构成一次切换',
    );
  });

  testWidgets('三级下钻：服务 → 家政/保洁 → 叶子多选写入持久筛选', (tester) async {
    final container = await pumpPanel(tester, measure: true);

    // 一级「服务」右侧箭头（「全部」没有箭头，故它是第 5 个）。
    await tester.ensureVisible(find.byIcon(Icons.chevron_right).at(4));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right).at(4));
    await tester.pumpAndSettle();
    expect(find.text('选择子类'), findsOneWidget);
    expect(find.text('家政/保洁'), findsOneWidget);

    // 二级「家政/保洁」右侧箭头进入三级。
    await tester.ensureVisible(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pumpAndSettle();
    expect(find.text('日常保洁'), findsOneWidget);
    expect(find.text('深度清洁'), findsOneWidget);

    await tester.tap(find.text('日常保洁'));
    await tester.pump();
    expect(container.read(discoveryFilterProvider).leafCategoryIds, {50101});

    await tester.tap(find.text('深度清洁'));
    await tester.pump();
    expect(container.read(discoveryFilterProvider).leafCategoryIds, {
      50101,
      50102,
    });

    // 再点一次取消，叶子集合精确回退。
    await tester.tap(find.text('日常保洁'));
    await tester.pump();
    expect(container.read(discoveryFilterProvider).leafCategoryIds, {50102});
  });

  testWidgets('二级分类点主体即可整组选中（不必下钻到三级）', (tester) async {
    final container = await pumpPanel(tester, measure: true);

    // 一级「生活」的右侧箭头（「全部」没有箭头，故它是第 4 个）。
    await tester.ensureVisible(find.byIcon(Icons.chevron_right).at(3));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.chevron_right).at(3));
    await tester.pumpAndSettle();
    expect(find.text('选择子类'), findsOneWidget);

    // 点二级「宠物相关」主体：写入该二级下全部叶子（40401 寄养 / 40402 领养）。
    // 曾经的缺陷是 _leavesOf 只展开一层，传二级节点得到空集，点了没反应。
    await tester.tap(find.text('宠物相关'));
    await tester.pumpAndSettle();
    expect(container.read(discoveryFilterProvider).leafCategoryIds, {
      40401,
      40402,
    });

    // 再点一次整组取消。
    await tester.tap(find.text('宠物相关'));
    await tester.pumpAndSettle();
    expect(container.read(discoveryFilterProvider).leafCategoryIds, isEmpty);
  });

  testWidgets('价格输入即生效：不依赖失焦，点面板外收起也不丢', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FilterPanel())),
      ),
    );

    await tester.ensureVisible(find.byType(TextField).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '100');
    await tester.pump();

    expect(
      container.read(effectiveFilterProvider).priceMin,
      100,
      reason: '面板没有确认按钮，改完直接点地图收面板时不能丢价格',
    );
  });

  testWidgets('拖动价格滑杆：输入框同步显示区间（焦点在输入框时也不落空）', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: FilterPanel())),
      ),
    );

    await tester.ensureVisible(find.byType(RangeSlider));
    await tester.pumpAndSettle();

    // 复现真机场景：键盘还开着、焦点停在输入框里，再拖滑杆。
    await tester.tap(find.byType(TextField).first);
    await tester.pump();

    final RangeSlider slider = tester.widget<RangeSlider>(
      find.byType(RangeSlider),
    );
    slider.onChanged!(const RangeValues(300, 800));
    await tester.pump();

    final List<TextField> fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.first.controller?.text, '300', reason: '下限输入框要跟着滑杆走');
    expect(fields.last.controller?.text, '800', reason: '上限输入框要跟着滑杆走');
    expect(container.read(effectiveFilterProvider).priceMin, 300);
    expect(container.read(effectiveFilterProvider).priceMax, 800);
  });
}
