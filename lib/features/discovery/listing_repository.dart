/// 信息数据源（M4 阶段为本地样例数据）。
///
/// 为什么现在就立一个 Repository 而不是把样例数据写进页面：地图页要验证的是
/// 「筛选 → 聚合 → 渲染」这条链路，链路两端必须可替换。数据写死在页面里，
/// 后端接通时就得把页面拆开重写，而拆的过程中很容易顺手改坏渲染逻辑。
///
/// 样例数据刻意围绕一个中心点按不同密度撒开 —— 均匀撒点看不出聚合效果，
/// 而聚合正是本页最需要肉眼验收的部分。
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import 'discovery_filter.dart';
import 'stress_data.dart';

/// 默认地图中心（杭州市中心附近，GCJ-02）。
///
/// 定位权限尚未接入（PRD §6.5 第 1 步，属 M4-3 后续），先给一个确定的中心，
/// 避免地图开在 (0,0) 的几内亚湾。
const double kDefaultCenterLat = 30.2741;
const double kDefaultCenterLng = 120.1551;

/// 样例数据的时间基准。
///
/// 用固定时刻而非 `DateTime.now()`：随时间漂移的数据会让「最新排序对不对」
/// 这类判断每天得到不同结果，也让截图与实测无法对照。
final DateTime _sampleNow = DateTime(2026, 8, 28, 12);

/// 生成样例数据。
///
/// 固定随机种子：每次启动看到同样的分布，聚合效果的前后对比才有意义。
/// 用随机种子会让「刚才那个簇怎么没了」无法判断是改坏了还是数据变了。
List<Listing> _buildSampleListings() {
  final random = math.Random(20260827);
  final List<Listing> listings = [];

  // 三个密度不同的片区：市中心（密）、次中心（中）、郊区（疏）。
  const List<({double lat, double lng, double spreadKm, int count})> zones = [
    (lat: kDefaultCenterLat, lng: kDefaultCenterLng, spreadKm: 0.8, count: 60),
    (
      lat: kDefaultCenterLat + 0.02,
      lng: kDefaultCenterLng + 0.025,
      spreadKm: 2.0,
      count: 30,
    ),
    (
      lat: kDefaultCenterLat - 0.035,
      lng: kDefaultCenterLng - 0.03,
      spreadKm: 4.0,
      count: 15,
    ),
  ];

  const List<String> titles = [
    '专业家庭日常保洁',
    '城西到滨江拼车',
    '一室一厅整租',
    '闲置婴儿车转让',
    '空调清洗维修',
    '找周末兼职',
    '求租单间',
    '顺风车找同路',
    '免费送猫粮',
    '小学数学家教',
  ];

  int seq = 0;
  for (final zone in zones) {
    for (int i = 0; i < zone.count; i++) {
      // 0.009 度 ≈ 1km（纬度方向）。经度方向未按 cos 修正，
      // 样例数据的分布形状不需要精确，此处按精确算会让代码变复杂而无收益。
      final double spreadDeg = zone.spreadKm * 0.009;
      final category =
          ListingCategory.values[random.nextInt(ListingCategory.values.length)];
      // 有价与无价约各半：列表页要能同时验证「有价格显示」与「无价格不留空行」，
      // 也让价格排序有 null 需要处理。
      final double? price = random.nextBool()
          ? (random.nextInt(20) * 10 + 30).toDouble()
          : null;
      listings.add(
        Listing(
          id: 'sample-${seq++}',
          title: titles[random.nextInt(titles.length)],
          category: category,
          supplyDemand: random.nextDouble() < 0.65
              ? SupplyDemand.supply
              : SupplyDemand.demand,
          // nextDouble() - 0.5 使点以 zone 中心对称分布。
          latitude: zone.lat + (random.nextDouble() - 0.5) * spreadDeg,
          longitude: zone.lng + (random.nextDouble() - 0.5) * spreadDeg,
          // 铺开在过去 7 天内，分钟级错开：同分钟会让「最新」排序出现并列，
          // 而并列项的相对顺序取决于原始顺序，看起来像排序不稳定。
          createdAt: _sampleNow.subtract(
            Duration(minutes: random.nextInt(7 * 24 * 60)),
          ),
          price: price,
          // 单位随分类而定（PRD §13.2 `price_unit` 取模板 price_units 之一）。
          // 模板引擎（§5.7）尚未实现，这里按大类给一个合理默认，
          // 目的是让详情页与列表页能验证「50 元/小时」这类带单位文案的排版。
          priceUnit: price == null ? null : _sampleUnitOf(category),
        ),
      );
    }
  }
  return List.unmodifiable(listings);
}

/// 样例数据的价格单位。
///
/// 真实单位应由 §5.7 模板 Schema 的 `price_units` 提供，模板引擎未实现前
/// 用大类兜底 —— 目的只是让展示层能验证带单位文案的排版与截断，
/// **不代表最终业务口径**（例如房屋实际还应有「元/日」短租选项）。
String _sampleUnitOf(ListingCategory category) => switch (category) {
  ListingCategory.work => '天',
  ListingCategory.house => '月',
  ListingCategory.vehicle => '次',
  ListingCategory.life => '件',
  ListingCategory.service => '小时',
};

/// 全量信息（未筛选）。
///
/// 压测档位开启时返回压测数据（PRD §6.10.1 POC-B）。在此处切换而不是另建
/// 一个 demo 页：POC-B 要测的是首页这条完整链路，绕开筛选与信息卡会让数字
/// 偏乐观，而这个数字要用来对外承诺 SLA。
final allListingsProvider = Provider<List<Listing>>((ref) {
  final stress = ref.watch(stressLevelProvider);
  if (stress != StressLevel.off) {
    return buildStressListings(stress.pointCount);
  }
  return _buildSampleListings();
});

/// 按当前筛选条件过滤后的信息。
///
/// 距离过滤以 [kDefaultCenterLat]/[kDefaultCenterLng] 为基准点。定位接入后
/// 改为读用户实际位置 —— 基准点是唯一需要改的地方，过滤逻辑不动。
final filteredListingsProvider = Provider<List<Listing>>((ref) {
  final listings = ref.watch(allListingsProvider);
  final filter = ref.watch(discoveryFilterProvider);

  return listings
      .where((l) {
        if (!filter.supplyDemand.contains(l.supplyDemand)) return false;
        if (!filter.isAllCategories &&
            !filter.categories.contains(l.category)) {
          return false;
        }
        if (filter.keyword.isNotEmpty && !l.title.contains(filter.keyword)) {
          return false;
        }
        final int? km = filter.radius.km;
        if (km != null) {
          final double meters = distanceInMeters(
            kDefaultCenterLat,
            kDefaultCenterLng,
            l.latitude,
            l.longitude,
          );
          if (meters > km * 1000) return false;
        }
        return true;
      })
      .toList(growable: false);
});
