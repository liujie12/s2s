/// 底部四 Tab 导航栏测试（计划 U11）。
///
/// [HomeNavBar] 是纯展示组件（未读总数由调用方传入），故不走网络装配：
/// 断言四项等分、顺序（丫圈/消息/发布/我的）、角标三态与选中态配色。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/design_tokens.dart';
import 'package:zhaoyazhao/router/home_shell.dart';

void main() {
  /// 挂载导航栏。
  ///
  /// 参数：[selectedIndex] 当前分支；[unreadTotal] 未读总数；
  ///   [onSelectBranch] 分支切换回调；[onPublish] 发布键回调。
  /// 返回：[Future<void>] pump 完成。
  Future<void> pumpBar(
    WidgetTester tester, {
    int selectedIndex = HomeBranch.discovery,
    int unreadTotal = 0,
    ValueChanged<int>? onSelectBranch,
    VoidCallback? onPublish,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeNavBar(
            selectedIndex: selectedIndex,
            unreadTotal: unreadTotal,
            onSelectBranch: onSelectBranch ?? (_) {},
            onPublish: onPublish ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('四项等分且顺序为 丫圈/消息/发布/我的', (tester) async {
    await pumpBar(tester, unreadTotal: 0);

    final widths = [
      for (int i = 0; i < 4; i++) tester.getSize(find.byType(InkWell).at(i)).width,
    ];
    expect(widths.toSet().length, 1, reason: '四个导航项必须等宽，实际：$widths');

    final labels = ['丫圈', '消息', '发布', '我的'];
    final xs = [for (final label in labels) tester.getCenter(find.text(label)).dx];
    expect(xs, orderedEquals([...xs]..sort()));
  });

  testWidgets('未读为 0 不渲染角标，12 显示 12，120 显示 99+', (tester) async {
    await pumpBar(tester, unreadTotal: 0);
    expect(find.text('0'), findsNothing);

    await pumpBar(tester, unreadTotal: 12);
    expect(find.text('12'), findsOneWidget);

    await pumpBar(tester, unreadTotal: 120);
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('点消息切分支、点发布走 push、点我的切分支', (tester) async {
    final branches = <int>[];
    var publishTaps = 0;
    await pumpBar(
      tester,
      onSelectBranch: branches.add,
      onPublish: () => publishTaps++,
    );

    await tester.tap(find.text('消息'));
    await tester.tap(find.text('发布'));
    await tester.tap(find.text('我的'));

    expect(branches, [HomeBranch.messages, HomeBranch.profile]);
    expect(publishTaps, 1);
  });

  testWidgets('选中态文案用品牌主色，未选中用次要文字色', (tester) async {
    await pumpBar(tester, selectedIndex: HomeBranch.messages);

    final selected = tester.widget<Text>(find.text('消息'));
    final unselected = tester.widget<Text>(find.text('我的'));

    expect(selected.style?.color, const Color(AppColors.primary));
    expect(unselected.style?.color, const Color(AppColors.textSecondary));
  });
}
