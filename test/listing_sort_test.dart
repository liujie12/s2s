/// 列表页排序的单元测试（PRD §6.4.3）。
///
/// 排序为什么值得测：错误的表现是「顺序看着差不多但就是不对」—— 没有报错、
/// 没有崩溃，肉眼在几十条数据里也难以核对。而排序恰是列表页用户最先感知的行为。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/listing_sort.dart';

/// 构造一条测试用信息。
///
/// [id] 用于断言顺序，[minutesAgo] 相对 [_now] 倒推，[price] 为 null 表示无价格，
/// [meters] 通过 distanceOf 注入而非真实坐标 —— 用坐标就得先算一遍 haversine
/// 才能知道期望顺序，测试会变成在验证「我算对了没有」。
Listing _listing(String id, {int minutesAgo = 0, double? price}) {
  return Listing(
    id: id,
    title: id,
    category: ListingCategory.work,
    supplyDemand: SupplyDemand.supply,
    latitude: 30.0,
    longitude: 120.0,
    createdAt: _now.subtract(Duration(minutes: minutesAgo)),
    price: price,
  );
}

final DateTime _now = DateTime(2026, 8, 28, 12);

/// 取排序结果的 id 序列，断言时比对它而非整个对象。
List<String> _ids(List<Listing> list) => list.map((l) => l.id).toList();

void main() {
  group('距离排序', () {
    test('近的在前', () {
      final list = [_listing('远'), _listing('近'), _listing('中')];
      final distances = {'近': 100.0, '中': 500.0, '远': 3000.0};

      final sorted = sortListings(
        list,
        sort: ListingSort.distance,
        now: _now,
        distanceOf: (l) => distances[l.id]!,
      );

      expect(_ids(sorted), ['近', '中', '远']);
    });
  });

  group('最新排序', () {
    test('新的在前', () {
      final list = [
        _listing('三天前', minutesAgo: 3 * 24 * 60),
        _listing('一小时前', minutesAgo: 60),
        _listing('一天前', minutesAgo: 24 * 60),
      ];

      final sorted = sortListings(
        list,
        sort: ListingSort.newest,
        now: _now,
        distanceOf: (_) => 0,
      );

      expect(_ids(sorted), ['一小时前', '一天前', '三天前']);
    });
  });

  group('价格排序', () {
    test('升序：小的在前，无价格沉底', () {
      final list = [
        _listing('无价'),
        _listing('贵', price: 500),
        _listing('便宜', price: 30),
      ];

      final sorted = sortListings(
        list,
        sort: ListingSort.priceAsc,
        now: _now,
        distanceOf: (_) => 0,
      );

      expect(_ids(sorted), [
        '便宜',
        '贵',
        '无价',
      ], reason: '无价格不是「最便宜」，把 null 当 0 会让它霸占升序首屏');
    });

    test('降序：大的在前，无价格同样沉底（不是当成极大值）', () {
      final list = [
        _listing('无价'),
        _listing('便宜', price: 30),
        _listing('贵', price: 500),
      ];

      final sorted = sortListings(
        list,
        sort: ListingSort.priceDesc,
        now: _now,
        distanceOf: (_) => 0,
      );

      expect(_ids(sorted), [
        '贵',
        '便宜',
        '无价',
      ], reason: '两个方向都沉底，才符合「不参与价格比较」的语义');
    });

    test('全部无价格时不抛异常，保持原序', () {
      final list = [_listing('a'), _listing('b')];

      final sorted = sortListings(
        list,
        sort: ListingSort.priceAsc,
        now: _now,
        distanceOf: (_) => 0,
      );

      expect(_ids(sorted), ['a', 'b']);
    });
  });

  group('综合排序', () {
    test('距离与时间各占一半：很近但很旧，输给中等距离的新信息', () {
      final list = [
        // 距离 0，但已 7 天：得分 0×0.5 + 1×0.5 = 0.5
        _listing('近而旧', minutesAgo: 7 * 24 * 60),
        // 距离 10km（上界 20km 的一半），刚发布：0.5×0.5 + 0 = 0.25
        _listing('中而新', minutesAgo: 0),
      ];
      final distances = {'近而旧': 0.0, '中而新': 10000.0};

      final sorted = sortListings(
        list,
        sort: ListingSort.composite,
        now: _now,
        distanceOf: (l) => distances[l.id]!,
      );

      expect(_ids(sorted), ['中而新', '近而旧']);
    });

    test('超出上界的距离一律按最远处理，不继续拉开差距', () {
      // 30km 与 50km 都 clamp 到 1，得分相同；此时由时间决定顺序。
      final list = [
        _listing('三十公里但新', minutesAgo: 0),
        _listing('五十公里但更旧', minutesAgo: 24 * 60),
      ];
      final distances = {'三十公里但新': 30000.0, '五十公里但更旧': 50000.0};

      final sorted = sortListings(
        list,
        sort: ListingSort.composite,
        now: _now,
        distanceOf: (l) => distances[l.id]!,
      );

      expect(_ids(sorted), [
        '三十公里但新',
        '五十公里但更旧',
      ], reason: '距离均已 clamp 到 1，差异只能来自时间');
    });
  });

  group('不修改入参', () {
    test('排序返回新列表，原列表顺序不变', () {
      final original = [
        _listing('b', minutesAgo: 10),
        _listing('a', minutesAgo: 5),
      ];

      sortListings(
        original,
        sort: ListingSort.newest,
        now: _now,
        distanceOf: (_) => 0,
      );

      expect(_ids(original), ['b', 'a'], reason: '就地排序会让共享同一份数据的地图页顺序也被改掉');
    });
  });
}
