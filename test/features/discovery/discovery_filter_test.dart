import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';

/// 持久筛选态：价格字段与值相等的单测（U1）。
///
/// 用纯 Dart 断言而不是 widget 测试：这些是状态层语义，与渲染无关；
/// 面板上的价格输入交互由 widget 测试另行覆盖。
void main() {
  group('价格文案', () {
    test('只设下限时摘要出现「≥500 元」', () {
      const filter = DiscoveryFilter(priceMin: 500);
      expect(filter.summaryLabel, contains('≥500 元'));
      expect(filter.hasPrice, isTrue);
    });

    test('只设上限时摘要出现「≤2000 元」', () {
      const filter = DiscoveryFilter(priceMax: 2000);
      expect(filter.summaryLabel, contains('≤2000 元'));
    });

    test('两侧都设时摘要出现区间', () {
      const filter = DiscoveryFilter(priceMin: 500, priceMax: 2000);
      expect(filter.summaryLabel, contains('500–2000 元'));
    });

    test('未设价格时摘要不含价格段', () {
      const filter = DiscoveryFilter();
      expect(filter.hasPrice, isFalse);
      expect(filter.summaryLabel.contains('元'), isFalse);
    });
  });

  group('copyWith 的显式清空', () {
    test('不传价格参数时保留原值', () {
      const filter = DiscoveryFilter(priceMin: 500, priceMax: 2000);
      final next = filter.copyWith(radius: SearchRadius.km1);
      expect(next.priceMin, 500);
      expect(next.priceMax, 2000);
    });

    test('只清上限时下限保留，文案只剩单侧', () {
      const filter = DiscoveryFilter(priceMin: 500, priceMax: 2000);
      final next = filter.copyWith(priceMax: null);
      expect(next.priceMax, isNull);
      expect(next.priceMin, 500);
      expect(next.summaryLabel, contains('≥500 元'));
    });

    test('两侧都显式置空即回到不限', () {
      const filter = DiscoveryFilter(priceMin: 500, priceMax: 2000);
      final next = filter.copyWith(priceMin: null, priceMax: null);
      expect(next.hasPrice, isFalse);
    });
  });

  group('值相等', () {
    test('字段全同的两个实例相等且 hash 相同', () {
      const a = DiscoveryFilter(priceMin: 500, priceMax: 2000);
      const b = DiscoveryFilter(priceMin: 500, priceMax: 2000);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('仅价格不同即不相等', () {
      const a = DiscoveryFilter(priceMax: 2000);
      const b = DiscoveryFilter(priceMax: 1500);
      expect(a == b, isFalse);
    });

    test('集合内容相同但实例不同仍相等', () {
      final a = const DiscoveryFilter().copyWith(supplyDemand: {SupplyDemand.supply});
      final b = const DiscoveryFilter().copyWith(supplyDemand: {SupplyDemand.supply});
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('notifier 写入', () {
    test('setPriceRange 一侧传 null 即只保留另一侧', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(discoveryFilterProvider.notifier);

      notifier.setPriceRange(min: 500, max: 2000);
      expect(container.read(discoveryFilterProvider).priceMax, 2000);

      notifier.setPriceRange(min: 500);
      expect(container.read(discoveryFilterProvider).priceMax, isNull);
      expect(container.read(discoveryFilterProvider).priceMin, 500);
    });
  });
}
