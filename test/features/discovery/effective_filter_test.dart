import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/condition_slots.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';
import 'package:zhaoyazhao/features/discovery/effective_filter.dart';
import 'package:zhaoyazhao/features/discovery/search_intent.dart';

/// 投影的纯函数单测（U2）。
///
/// 直接调 `effectiveFilterOf` 而不是起 ProviderContainer：投影必须是纯函数，
/// 用纯函数测试才能证明「同一输入两次调用结果相等」。
void main() {
  const DiscoveryFilter persistent = DiscoveryFilter(
    radius: SearchRadius.km5,
    categories: {ListingCategory.house},
  );

  SearchIntent intentOf({
    String? postType,
    List<int> leafCategoryIds = const <int>[],
    List<String> categoryLabels = const <String>[],
    String? radius,
    Set<ConditionSlot> cleared = const <ConditionSlot>{},
  }) {
    return SearchIntent(
      queryText: '测试',
      postType: postType,
      leafCategoryIds: leafCategoryIds,
      categoryLabels: categoryLabels,
      radius: radius,
      clearedSlots: cleared,
    );
  }

  test('无搜索态：全部来自持久筛选', () {
    final result = effectiveFilterOf(persistent, null);
    expect(result.active, isFalse);
    expect(result.radius, SearchRadius.km5);
    expect(result.leafCategoryIds, isNotEmpty);
    expect(result.chips.map((c) => c.source).toSet(), {ConditionSource.persistent});
  });

  test('意图覆盖半径与类目，供需回落持久并标为持久', () {
    final result = effectiveFilterOf(
      persistent,
      intentOf(radius: '1', leafCategoryIds: const [10101], categoryLabels: const ['房屋']),
    );
    expect(result.radius, SearchRadius.km1);
    expect(result.leafCategoryIds, const [10101]);
    expect(result.supplyDemand, persistent.supplyDemand);

    final supplyChip = result.chips.firstWhere((c) => c.slot == ConditionSlot.supplyDemand);
    expect(supplyChip.source, ConditionSource.persistent);
  });

  test('显式清空类目后不再回落持久类目', () {
    final result = effectiveFilterOf(
      persistent,
      intentOf(cleared: const {ConditionSlot.category}),
    );
    expect(result.leafCategoryIds, isEmpty);
  });

  test('显式清空半径即全城', () {
    final result = effectiveFilterOf(
      persistent,
      intentOf(cleared: const {ConditionSlot.radius}),
    );
    expect(result.radius, SearchRadius.city);
    expect(result.radiusMeters, isNull);
  });

  test('未解析字段只进 unresolved，不产生过滤 chip', () {
    final intent = SearchIntent(queryText: '那个离地铁近的', unresolvedFields: const ['location']);
    final result = effectiveFilterOf(persistent, intent);
    expect(result.unresolvedLabels, const ['地点']);
    expect(result.chips.map((c) => c.label), isNot(contains('地点')));
  });

  test('同一输入两次投影结果相等', () {
    final intent = intentOf(radius: '3');
    final a = effectiveFilterOf(persistent, intent);
    final b = effectiveFilterOf(persistent, intent);
    expect(a.chips.length, b.chips.length);
    expect(a.radius, b.radius);
    expect(a.leafCategoryIds, b.leafCategoryIds);
  });

  test('价格来自持久筛选，设置上限即排除面议', () {
    final result = effectiveFilterOf(
      persistent.copyWith(priceMin: 500, priceMax: 2000),
      intentOf(radius: '3'),
    );
    expect(result.priceMin, 500);
    expect(result.priceMax, 2000);
    expect(result.priceExcludesNegotiable, isTrue);
    expect(result.chips.any((c) => c.slot == ConditionSlot.price), isTrue);
  });

  test('删除地点 chip 后锚点与小区一并清空', () {
    final intent = SearchIntent(
      queryText: '锦绣小区',
      anchorLat: 30.1,
      anchorLng: 120.2,
      anchorName: '锦绣小区',
      communityId: 'c1',
      communityName: '锦绣小区',
    );
    final before = effectiveFilterOf(persistent, intent);
    expect(before.anchorLat, 30.1);
    expect(before.communityId, 'c1');

    final after = effectiveFilterOf(persistent, intent.withoutAnchor());
    expect(after.anchorLat, isNull);
    expect(after.communityId, isNull);
    expect(after.chips.any((c) => c.slot == ConditionSlot.anchor), isFalse);
  });
}
