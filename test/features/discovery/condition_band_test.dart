import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/condition_band.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';
import 'package:zhaoyazhao/features/discovery/search_intent.dart';

/// 条件带的渲染单测（U4 / U10）。
///
/// 只钉「从投影长出来」这一层：默认条件不常驻、灰态项不计数、
/// 「没听懂」走搜索栏下方提示而不是 chip 行。
void main() {
  /// 渲染条件带。
  ///
  /// 参数：
  /// - [tester]：测试器；
  /// - [container]：Riverpod 容器；
  /// - [onRetry]：是否提供重试回调（决定「没听懂」提示是否渲染）。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> pumpBand(
    WidgetTester tester,
    ProviderContainer container, {
    VoidCallback? onRetry,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: ConditionBand(onFilter: () {}, onRetry: onRetry),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('默认条件不常驻，只有显式设置才长出 chip', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(discoveryFilterProvider.notifier)
        .setRadius(SearchRadius.km1);
    container.read(discoveryFilterProvider.notifier).setPriceRange(min: 500);

    await pumpBand(tester, container);

    expect(find.text('1km'), findsOneWidget);
    expect(find.text('≥500 元'), findsOneWidget);
    // 默认的 5km / 资源+需求 / 全部分类不再出现。
    expect(find.text('5km'), findsNothing);
    expect(find.text('资源+需求'), findsNothing);
    expect(find.text('全部分类'), findsNothing);
    // 漏斗与语音/发送键仍在。
    expect(find.byIcon(Icons.filter_alt_outlined), findsOneWidget);
  });

  testWidgets('完全默认时不出现 chip 行', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await pumpBand(tester, container);

    expect(find.text('5km'), findsNothing);
    expect(find.text('资源+需求'), findsNothing);
    expect(find.text('全部分类'), findsNothing);
  });

  testWidgets('没听懂的字段进灰态，「没听懂」走搜索栏下方提示', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container
        .read(searchIntentProvider.notifier)
        .replace(
          const SearchIntent(
            queryText: '那个离地铁近点的',
            unresolvedFields: ['location'],
          ),
        );

    await pumpBand(tester, container, onRetry: () {});

    expect(find.text('地点 · 没敢用'), findsOneWidget);
    expect(find.text('没听懂 · 重试'), findsOneWidget);
  });

  testWidgets('叶子 chip 的叉号只删这一枚叶子', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(discoveryFilterProvider.notifier).setLeafCategoryIds({
      50101,
      50102,
    });

    await pumpBand(tester, container);

    expect(find.text('日常保洁'), findsOneWidget);
    expect(find.text('深度清洁'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();

    expect(container.read(discoveryFilterProvider).leafCategoryIds, {50102});
  });
}
