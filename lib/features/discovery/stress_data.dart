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

import 'map_dto.dart';

/// 压测点数档位。PRD §6.10.1 规定 POC 数据量为「单屏 1 万点、5 万点两档」。
enum StressLevel {
  /// 关闭压测，走真实后端数据（`pinsProvider` 调 `/map/pins`）。
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

/// 压测图钉 ID 起始值。
///
/// 刻意取大值（1000000），与真实帖子 ID 段（种子脚本 9001–9030、真实增长从
/// 小值起）留出足够间隔，避免压测图钉与真实数据 ID 相撞。
const int _kStressIdBase = 1000000;

/// 压测图钉的叶子类目 ID（§2.4 三级树中的真实叶子）。
///
/// 混排五个大类：若地图未来按类目着色/分类聚合，五类都要被画到，只用一类
/// 会掩盖「分类相关」的绘制开销。取值：工作 10202 / 房屋 20103 / 车辆 30101 /
/// 生活 40102 / 服务 50101。
const List<int> _kStressLeafCategoryIds = <int>[10202, 20103, 30101, 40102, 50101];

/// 按档位生成压测图钉（地图渲染的实际数据模型 [MapPinDto]）。
///
/// **分布用聚集而非均匀**：POC-A 已证明聚集分布才是聚合算法的最坏情况
/// （说明文档条目 [63]，×5.72 vs 均匀的 ×3.21）。渲染侧同理 —— 点扎堆时
/// 单格内成员多、聚合圈上的数字位数也多，绘制开销比均匀分布高。
/// 用均匀分布测会得到一个偏乐观的 SLA。
///
/// **固定随机种子**：同一档位每次生成同样的点，两次测量的差异才能归因到
/// 代码改动而不是数据变化。
///
/// **中心必须由调用方传入当前请求视口中心**（2026-10-09 修 H-1）：压测点若写死
/// 某个城市，而设备不在那座城，屏上就一条都看不到 —— 真机表现为角标「视野外
/// 还有 N 条」，测出来的只是「Pin 全在屏外」的管线成本，**漏掉真实上屏的绘制 /
/// 光栅开销**，结论会系统性偏乐观（详见说明文档 H-1 条与 PRD §6.10.1 的口径限制）。
///
/// 参数：
/// - [count]：点数；传 0 返回空表（对应「关闭」档不走本函数）；
/// - [centerLat] / [centerLng]：热点分布中心（GCJ-02），取**当前请求视口中心**。
///
/// 返回：[MapPinDto] 列表。POC-B 走 `pinsProvider` 短路注入（[139]），注入点
/// 消费的就是地图渲染同款模型，不再经旧 mock 链 `allListingsProvider`。
List<MapPinDto> buildStressPins(
  int count, {
  required double centerLat,
  required double centerLng,
}) {
  if (count == 0) return const [];
  final random = math.Random(20260828);

  // 热点数量随点数增长，但增长慢于点数 —— 城市规模变大时，热点会变密
  // 而不是等比例变多。每个热点固定 sqrt 量级的成员，单格深度才会随总量上升，
  // 这正是要压的那一维。
  final int hotspotCount = math.max(1, (math.sqrt(count) / 3).round());
  final List<({double lat, double lng})> hotspots = List.generate(
    hotspotCount,
    (_) => (
      lat: centerLat + (random.nextDouble() - 0.5) * 0.08,
      lng: centerLng + (random.nextDouble() - 0.5) * 0.08,
    ),
  );

  return List.generate(count, (i) {
    final hotspot = hotspots[random.nextInt(hotspots.length)];
    // 0.0045 度 ≈ 500m：热点内扩散半径小于聚合网格对应的地理尺度，
    // 才能真正形成深桶。扩散过大就退化成均匀分布，压不到最坏情况。
    const double spreadDeg = 0.0045;
    return MapPinDto(
      id: _kStressIdBase + i,
      lng: hotspot.lng + (random.nextDouble() - 0.5) * spreadDeg,
      lat: hotspot.lat + (random.nextDouble() - 0.5) * spreadDeg,
      leafCategoryId:
          _kStressLeafCategoryIds[i % _kStressLeafCategoryIds.length],
      // 供需混排（0=resource / 1=demand）：图标/着色的两条分支都要被画到。
      typeCode: i.isEven ? 0 : 1,
      // 完整度三档混排（0/1/2）：若未来按完整度着色，三档都要被画到。
      completenessLevel: i % 3,
    );
  }, growable: false);
}
