import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/condition_band.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';
import 'package:zhaoyazhao/features/discovery/search_intent.dart';

/// 条件带的渲染单测（U4 / U10）。
///
/// 只钉「从投影长出来」这一层：chip 内容、计数、灰态项不计数。
void main() {
  Future<void> pumpBand(
    WidgetTester tester,
    ProviderContainer container, {
    String? countLabel,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ConditionBand(countLabel: countLabel, onAddCondition: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('无搜索态：显示持久筛选 chip、追加入口与命中数', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(discoveryFilterProvider.notifier).setRadius(SearchRadius.km1);
    container.read(discoveryFilterProvider.notifier).setPriceRange(min: 500);

    await pumpBand(tester, container, countLabel: '3 条');

    expect(find.text('1km'), findsOneWidget);
    expect(find.text('资源+需求'), findsOneWidget);
    expect(find.text('全部分类'), findsOneWidget);
    expect(find.text('≥500 元'), findsOneWidget);
    expect(find.text('＋ 条件'), findsOneWidget);
    expect(find.text('3 条'), findsOneWidget);
  });

  testWidgets('没听懂的字段进灰态，不计入过滤 chip', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(searchIntentProvider.notifier).replace(
          const SearchIntent(queryText: '那个离地铁近点的', unresolvedFields: ['location']),
        );

    await pumpBand(tester, container, countLabel: '0 条');

    expect(find.text('地点 · 没敢用'), findsOneWidget);
    // 「没听懂」时右端不给命中数（R6）。
    expect(find.text('没听懂'), findsOneWidget);
    expect(find.text('0 条'), findsNothing);
  });
}
