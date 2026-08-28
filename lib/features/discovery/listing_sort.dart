/// 列表页排序（PRD §6.4.3：综合 / 距离（默认）/ 最新 / 价格升序 / 价格降序）。
///
/// 独立于 [DiscoveryFilter]：排序是**列表页专属**的，地图页没有「顺序」这个概念。
/// 塞进共享筛选态会让地图页也 watch 到它，改排序时地图跟着重建一次 —— 白白多
/// 一次全量聚合与重绘，而地图上什么都没变。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/listing.dart';
import 'listing_repository.dart';

/// 排序档位。
enum ListingSort {
  /// 综合：距离与新鲜度的加权。PRD 未定义权重，本期实现见 [_compositeScore]。
  composite('综合'),

  /// 距离近优先。PRD §6.4.3 标注为默认。
  distance('距离'),

  /// 发布时间新优先。
  newest('最新'),

  priceAsc('价格 ↑'),

  priceDesc('价格 ↓');

  const ListingSort(this.label);

  final String label;
}

class ListingSortNotifier extends Notifier<ListingSort> {
  @override
  ListingSort build() => ListingSort.distance;

  void set(ListingSort sort) => state = sort;
}

/// 当前排序档位。
final listingSortProvider = NotifierProvider<ListingSortNotifier, ListingSort>(
  ListingSortNotifier.new,
);

/// 综合排序得分：距离与新鲜度各占一半，越小越靠前。
///
/// **为什么不直接把米数和分钟数相加**：两者量纲不同，10km（10000）与 7 天
/// （10080 分钟）数值恰好接近纯属巧合，换个单位（秒）时间就会完全压过距离。
/// 故各自先归一化到 0–1 再加权。
///
/// 归一化上界取「本期业务边界」而非样本极值：用样本极值会让同一条信息的
/// 排名随其他信息的增删而跳动，用户看到的是「我什么都没做，顺序自己变了」。
/// - 距离上界 20km：范围筛选最大档为 10km，全城档给一倍余量；
/// - 时间上界 7 天：与 §6.4.4 兜底里「过去 7 天」的时效口径一致。
///
/// 超出上界的一律按 1 处理（clamp），不做外推 —— 30km 与 50km 都属「很远」，
/// 让它们继续拉开差距只会挤压近距离条目之间的分辨率。
///
/// 参数 [distanceMeters] 为到基准点的距离（米），[ageMinutes] 为发布至今的分钟数。
/// 返回 0–1 的得分。
double _compositeScore(double distanceMeters, int ageMinutes) {
  const double maxDistanceMeters = 20000;
  const double maxAgeMinutes = 7 * 24 * 60;
  final double d = (distanceMeters / maxDistanceMeters).clamp(0.0, 1.0);
  final double a = (ageMinutes / maxAgeMinutes).clamp(0.0, 1.0);
  return d * 0.5 + a * 0.5;
}

/// 按 [sort] 排序。
///
/// **无价格的条目在价格排序中恒排末尾**，升序降序都是。把 null 当 0 会让
/// 「免费送猫粮」在升序时霸占首屏，而它根本不是「最便宜」——它是没有价格。
/// 若当作极大值，降序时同样霸屏。两个方向都沉底才符合「不参与价格比较」的语义。
///
/// [now] 由调用方传入而非在内部取 `DateTime.now()`：函数内部取当前时间会让
/// 单测无法固定输入，测试要么依赖真实时钟、要么只能断言相对顺序。
///
/// [distanceOf] 返回某条信息到基准点的距离（米）。由调用方注入，
/// 使排序不必知道「基准点是用户定位还是默认中心」。
///
/// 返回新列表，不修改入参。
List<Listing> sortListings(
  List<Listing> listings, {
  required ListingSort sort,
  required DateTime now,
  required double Function(Listing) distanceOf,
}) {
  final result = List<Listing>.of(listings);

  switch (sort) {
    case ListingSort.distance:
      result.sort((a, b) => distanceOf(a).compareTo(distanceOf(b)));
    case ListingSort.newest:
      result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    case ListingSort.priceAsc:
      result.sort((a, b) => _comparePrice(a, b, ascending: true));
    case ListingSort.priceDesc:
      result.sort((a, b) => _comparePrice(a, b, ascending: false));
    case ListingSort.composite:
      result.sort((a, b) {
        final sa = _compositeScore(
          distanceOf(a),
          now.difference(a.createdAt).inMinutes,
        );
        final sb = _compositeScore(
          distanceOf(b),
          now.difference(b.createdAt).inMinutes,
        );
        return sa.compareTo(sb);
      });
  }
  return result;
}

/// 价格比较。无价格恒沉底（与 [ascending] 无关）。
int _comparePrice(Listing a, Listing b, {required bool ascending}) {
  final pa = a.priceValue;
  final pb = b.priceValue;
  if (pa == null && pb == null) return 0;
  if (pa == null) return 1;
  if (pb == null) return -1;
  return ascending ? pa.compareTo(pb) : pb.compareTo(pa);
}

/// 筛选并排序后的列表（列表页直接消费）。
///
/// 建在 [filteredListingsProvider] 之上而不是替换它：地图页只要筛选不要排序，
/// 两页共用一个 Provider 会让地图页也承担排序开销。
final sortedListingsProvider = Provider<List<Listing>>((ref) {
  final listings = ref.watch(filteredListingsProvider);
  final sort = ref.watch(listingSortProvider);

  return sortListings(
    listings,
    sort: sort,
    now: DateTime.now(),
    distanceOf: (l) => distanceInMeters(
      kDefaultCenterLat,
      kDefaultCenterLng,
      l.latitude,
      l.longitude,
    ),
  );
});
