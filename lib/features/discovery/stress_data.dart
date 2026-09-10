/// POC-B 压测档位（PRD §6.10.1）。
///
/// **为什么压测数据走与真实数据同一个 Provider**：POC-B 要测的是首页地图这条
/// 完整链路（筛选 → 投影 → 聚合 → 绘制），另建一个 demo 页会漏掉筛选与信息卡
/// 这些真实开销，测出来的数字偏乐观，而 SLA 正是要用这个数字对外承诺。
///
/// **为什么不用 kDebugMode 之外的开关藏起来**：POC-B 要在 release 包上测
/// （debug 包的 JIT 与断言会让帧耗时严重失真），所以档位入口必须存在于
/// release 构建中。它挂在筛选面板之外的独立浮层，正常使用不会误触。
library;

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import 'listing_repository.dart';

/// 压测点数档位。PRD §6.10.1 规定 POC 数据量为「单屏 1 万点、5 万点两档」。
enum StressLevel {
  /// 关闭压测，用样例数据（105 条）。
  off(0, '关闭'),

  /// PRD §14.6 的单次渲染上限档，也是降级开关触发后的目标值。
  cap500(500, '500 点'),

  tenK(10000, '1 万点'),

  fiftyK(50000, '5 万点');

  const StressLevel(this.pointCount, this.label);

  final int pointCount;
  final String label;
}

final stressLevelProvider = NotifierProvider<StressLevelNotifier, StressLevel>(
  StressLevelNotifier.new,
);

class StressLevelNotifier extends Notifier<StressLevel> {
  @override
  StressLevel build() => StressLevel.off;

  void set(StressLevel level) => state = level;
}

/// 压测数据 ID 起始值。
///
/// 与样例数据（`listing_repository.dart`，从 1 起、量级为数十）刻意留出
/// 足够间隔，避免两批数据同时存在时 ID 相撞。
const int _kStressIdBase = 1000000;

/// 按档位生成压测数据。
///
/// **分布用聚集而非均匀**：POC-A 已证明聚集分布才是聚合算法的最坏情况
/// （说明文档条目 [63]，×5.72 vs 均匀的 ×3.21）。渲染侧同理 —— 点扎堆时
/// 单格内成员多、聚合圈上的数字位数也多，绘制开销比均匀分布高。
/// 用均匀分布测会得到一个偏乐观的 SLA。
///
/// **固定随机种子**：同一档位每次生成同样的点，两次测量的差异才能归因到
/// 代码改动而不是数据变化。
List<Listing> buildStressListings(int count) {
  if (count == 0) return const [];
  final random = math.Random(20260828);

  // 热点数量随点数增长，但增长慢于点数 —— 城市规模变大时，热点会变密
  // 而不是等比例变多。每个热点固定 sqrt 量级的成员，单格深度才会随总量上升，
  // 这正是要压的那一维。
  final int hotspotCount = math.max(1, (math.sqrt(count) / 3).round());
  final List<({double lat, double lng})> hotspots = List.generate(
    hotspotCount,
    (_) => (
      lat: kDefaultCenterLat + (random.nextDouble() - 0.5) * 0.08,
      lng: kDefaultCenterLng + (random.nextDouble() - 0.5) * 0.08,
    ),
  );

  return List.generate(count, (i) {
    final hotspot = hotspots[random.nextInt(hotspots.length)];
    // 0.0045 度 ≈ 500m：热点内扩散半径小于聚合网格对应的地理尺度，
    // 才能真正形成深桶。扩散过大就退化成均匀分布，压不到最坏情况。
    const double spreadDeg = 0.0045;
    return Listing(
      // id 为 int（详细设计 §10.4.3）。压测段从 1000000 起编，与样例段
      // （listing_repository.dart，从 1 起）刻意不重叠，理由见那一处注释。
      id: _kStressIdBase + i,
      title: '压测数据 $i',
      category:
          ListingCategory.values[random.nextInt(ListingCategory.values.length)],
      supplyDemand: random.nextDouble() < 0.65
          ? SupplyDemand.supply
          : SupplyDemand.demand,
      latitude: hotspot.lat + (random.nextDouble() - 0.5) * spreadDeg,
      longitude: hotspot.lng + (random.nextDouble() - 0.5) * spreadDeg,
      // 时间也错开：压测若要覆盖列表页，「最新」排序对 5 万条全相同的时间
      // 会退化成原序，测不出排序本身的开销。
      createdAt: DateTime(
        2026,
        8,
        28,
        12,
      ).subtract(Duration(minutes: random.nextInt(7 * 24 * 60))),
      price: null,
    );
  }, growable: false);
}
