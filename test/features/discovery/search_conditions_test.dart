import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/condition_slots.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';
import 'package:zhaoyazhao/features/discovery/effective_filter.dart';
import 'package:zhaoyazhao/features/discovery/effective_filter_provider.dart';
import 'package:zhaoyazhao/features/discovery/search_conditions.dart';
import 'package:zhaoyazhao/features/discovery/search_intent.dart';
import 'package:zhaoyazhao/features/discovery/search_repository.dart';

/// 解析仓库替身：只记录收到的交互标识，不发网络请求。
class _FakeSearchRepository extends SearchRepository {
  _FakeSearchRepository() : super(Dio());

  /// 每次解析收到的交互标识（按调用顺序）。
  final List<String?> seen = <String?>[];

  @override
  Future<SearchIntent> resolve({
    String? text,
    String? voiceMediaId,
    String? voiceBase64,
    String? voiceContentType,
    double? anchorLat,
    double? anchorLng,
    double? currentLat,
    double? currentLng,
    String? interactionId,
  }) async {
    seen.add(interactionId);
    return SearchIntent(queryText: text ?? '');
  }
}

/// 条件写入门面的单测（U3）。
///
/// 只测状态写入路由与撤销：解析链路需要网络，由既有的 search_intent_test 覆盖。
void main() {
  ProviderContainer containerWith({SearchIntent? intent}) {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    if (intent != null) {
      container.read(searchIntentProvider.notifier).replace(intent);
    }
    return container;
  }

  group('写入路由', () {
    test('无搜索态改半径只动持久筛选', () {
      final container = containerWith();
      container.read(searchConditionsProvider.notifier).setRadius(SearchRadius.km1);

      expect(container.read(discoveryFilterProvider).radius, SearchRadius.km1);
      expect(container.read(searchIntentProvider).intent, isNull);
    });

    test('搜索态改半径只动当前槽位卡', () {
      final intent = SearchIntent(queryText: '合租', radius: '5', radiusMeters: 5000);
      final container = containerWith(intent: intent);

      container.read(searchConditionsProvider.notifier).setRadius(SearchRadius.km3);

      final SearchIntent? next = container.read(searchIntentProvider).intent;
      expect(next?.radius, '3');
      expect(next?.radiusMeters, 3000);
      expect(container.read(discoveryFilterProvider).radius, SearchRadius.km5);
    });

    test('搜索态改价格写持久筛选（价格是持久条件）', () {
      final intent = SearchIntent(queryText: '合租', radius: '5');
      final container = containerWith(intent: intent);

      container.read(searchConditionsProvider.notifier).setPrice(min: 500, max: 2000);

      expect(container.read(discoveryFilterProvider).priceMin, 500);
      expect(container.read(discoveryFilterProvider).priceMax, 2000);
      expect(container.read(searchIntentProvider).intent?.priceMin, isNull);
    });

    test('搜索态取消最后一个供需方向被忽略（不允许空集）', () {
      final intent = SearchIntent(queryText: '合租', postType: 'resource');
      final container = containerWith(intent: intent);

      container.read(searchConditionsProvider.notifier).setSupplyDemand({});

      expect(container.read(searchIntentProvider).intent?.postType, 'resource');
    });

    test('无搜索态取消最后一个供需方向同样被忽略', () {
      final container = containerWith();

      container.read(searchConditionsProvider.notifier).setSupplyDemand({});

      expect(
        container.read(discoveryFilterProvider).supplyDemand,
        {SupplyDemand.supply, SupplyDemand.demand},
      );
    });

    test('搜索态切换供需写当前槽位卡，持久筛选不变', () {
      final intent = SearchIntent(queryText: '合租', postType: 'resource');
      final container = containerWith(intent: intent);
      final DiscoveryFilter before = container.read(discoveryFilterProvider);

      container.read(searchConditionsProvider.notifier).toggleSupplyDemand(SupplyDemand.demand);

      expect(container.read(searchIntentProvider).intent, isNotNull);
      expect(container.read(discoveryFilterProvider), before);
    });
  });

  group('删除与撤销', () {
    test('删除搜索态类目 chip 后该 chip 消失且不回落持久类目', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container
          .read(discoveryFilterProvider.notifier)
          .setCategories({ListingCategory.house});
      container.read(searchIntentProvider.notifier).replace(
            SearchIntent(
              queryText: '合租',
              leafCategoryIds: const [10101],
              categoryLabels: const ['合租'],
            ),
          );

      final ConditionChip chip = container
          .read(effectiveFilterProvider)
          .chips
          .firstWhere((c) => c.slot == ConditionSlot.category);
      expect(chip.label, '合租');

      container.read(searchConditionsProvider.notifier).removeSlot(chip);

      final EffectiveFilter after = container.read(effectiveFilterProvider);
      expect(after.categoryLabels, isEmpty);
      expect(after.chips.any((c) => c.slot == ConditionSlot.category), isFalse);
    });

    test('撤销同时回退两个源', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(searchIntentProvider.notifier)
          .replace(SearchIntent(queryText: '合租', radius: '5'));

      final notifier = container.read(searchConditionsProvider.notifier);
      notifier.setPrice(min: 1000);
      notifier.setRadius(SearchRadius.km1);

      expect(container.read(searchConditionsProvider).canUndo, isTrue);
      notifier.undo();

      expect(container.read(discoveryFilterProvider).priceMin, isNull);
      expect(container.read(searchIntentProvider).intent?.radius, '5');
      expect(container.read(searchConditionsProvider).canUndo, isFalse);
    });
  });

  group('交互标识', () {
    test('提交生成标识，重试复用、新提交换新、清除置空', () async {
      final repo = _FakeSearchRepository();
      final container = ProviderContainer(
        overrides: [searchRepositoryProvider.overrideWithValue(repo)],
      );
      addTearDown(container.dispose);
      final notifier = container.read(searchConditionsProvider.notifier);

      await notifier.submit(text: '合租');
      final String? first = container.read(searchConditionsProvider).interactionId;
      expect(first, isNotNull);
      expect(repo.seen.last, first);

      await notifier.submit(text: '合租', retry: true);
      expect(repo.seen.last, first, reason: '重试应复用同一标识');

      await notifier.submit(text: '保洁');
      expect(repo.seen.last, isNot(first), reason: '新一次搜索应换新标识');

      notifier.clearAll();
      expect(container.read(searchConditionsProvider).interactionId, isNull);
    });
  });

  group('清除与清文本', () {
    test('清除结束搜索且清空撤销栈，持久筛选保留', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(discoveryFilterProvider.notifier).setPriceRange(min: 500);
      container.read(searchIntentProvider.notifier)
          .replace(SearchIntent(queryText: '合租', radius: '1'));

      final notifier = container.read(searchConditionsProvider.notifier);
      notifier.setQueryText('合租');
      notifier.clearAll();

      expect(container.read(searchIntentProvider).intent, isNull);
      expect(container.read(searchConditionsProvider).queryText, isEmpty);
      expect(container.read(searchConditionsProvider).canUndo, isFalse);
      expect(container.read(discoveryFilterProvider).priceMin, 500);
    });

    test('叉号只清文本，条件与搜索态都保留', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(searchIntentProvider.notifier)
          .replace(SearchIntent(queryText: '合租', radius: '1'));

      final notifier = container.read(searchConditionsProvider.notifier);
      notifier.setQueryText('合租');
      notifier.clearText();

      expect(container.read(searchConditionsProvider).queryText, isEmpty);
      expect(container.read(searchIntentProvider).intent?.radius, '1');
    });
  });
}
