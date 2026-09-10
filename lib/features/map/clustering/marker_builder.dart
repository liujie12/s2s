/// 把网格聚合结果转成可渲染的 Marker 列表（PRD §6.15 阈值 + §6.4.2 尺寸三档）。
///
/// 为什么单独一层而不并进 `clusterByGrid`：聚合算法是纯 O(n) 计算、无 Flutter 依赖，
/// 要能在 Dart VM 里跑 POC-A 基准；而阈值与尺寸是产品规格，会随 PRD 改。
/// 混在一起会让每次调阈值都要重跑一遍性能基准去确认没拖慢算法。
///
/// 本文件同样不 import Flutter —— 尺寸是数字，配色由渲染层按 [MapMarker.topCategory] 自取。
library;

import '../../../domain/listing_category.dart';
import 'grid_cluster.dart';

/// 一个待渲染的地图标记。
sealed class MapMarker {
  const MapMarker({
    required this.x,
    required this.y,
    required this.topCategory,
  });

  /// 屏幕横坐标（逻辑像素，Marker 中心）。
  final double x;

  /// 屏幕纵坐标（逻辑像素，Marker 中心）。
  final double y;

  /// 一级大类，渲染层据此取配色与图标。
  ///
  /// 可空：本地分类树版本落后时查不到大类是预期内状态（§16.4），
  /// 渲染层应改用中性配色（`neutralCategoryColor`）而**不是丢弃该 Marker**。
  final ListingCategory? topCategory;
}

/// 单点 Marker，对应一条具体信息。
class SinglePointMarker extends MapMarker {
  const SinglePointMarker({
    required super.x,
    required super.y,
    required super.topCategory,
    required this.listingId,
  });

  /// 本地帖子标识。回传服务端前须转 `int`（详细设计 §10.4.3）。
  final String listingId;
}

/// 聚合 Marker，代表多条信息。
class ClusterMarker extends MapMarker {
  const ClusterMarker({
    required super.x,
    required super.y,
    required super.topCategory,
    required this.count,
    required this.memberIds,
  });

  /// 簇内条数。
  final int count;

  /// 簇内成员 ID，点击展开列表时用（PRD §6.9）。
  final List<String> memberIds;

  /// 尺寸三档（PRD §6.4.2）。
  ///
  /// 2–9 档刻意比单点 40 **小**：小簇若与单点等大甚至更大，会抢过单点的注意力，
  /// 而「几个挨在一起」本身不是需要优先关注的信息。
  double get diameter => switch (count) {
    < 10 => 32,
    < 100 => 40,
    _ => 48,
  };
}

/// 单点 Marker 的直径（PRD §6.4.2：正常 40×40）。
const double kSinglePointMarkerDiameter = 40;

/// 选中态 Marker 的直径（PRD §6.4.2：选中 48×48）。
const double kSelectedMarkerDiameter = 48;

/// 按分类阈值决定每个网格簇是聚合还是散开。
///
/// [points] 是聚合前的原始点集，[clusters] 是 [clusterByGrid] 对它的聚合结果。
/// 两者都要传，是因为**未达阈值的簇要拆回单点，而单点必须画在原坐标上**——
/// [Cluster] 只保留了成员 ID 与中心平均值，原坐标只能从 [points] 查回。
/// 若图省事用簇中心当单点位置，同格两条信息会精确重叠，第二个 Pin 永远点不到。
///
/// [thresholdOf] 给出某大类的聚合阈值。仍保持注入而不直接读
/// `ListingCategory.clusterThreshold`，原因已从「避免 Flutter 依赖」变为：
/// **大类可空时该用什么阈值是产品规则，不是算法细节**。把这个决定留在调用方，
/// 本层就不必对「分类树没查到」这件事表态。
///
/// 规则：簇内条数 **达到或超过**该分类阈值才聚合；否则拆回单点。
/// 「达到即聚」而非「超过才聚」—— PRD §6.15 写的是「工作 3 条聚」，即 3 条就聚。
///
/// 复杂度 O(n)：一次建索引 + 一次遍历簇。返回顺序不保证稳定。
List<MapMarker> buildMarkers(
  List<ClusterPoint> points,
  List<Cluster> clusters, {
  required int Function(ListingCategory? topCategory) thresholdOf,
}) {
  final Map<String, ClusterPoint> pointById = {for (final p in points) p.id: p};
  final List<MapMarker> markers = [];

  for (final cluster in clusters) {
    if (cluster.count >= thresholdOf(cluster.topCategory)) {
      markers.add(
        ClusterMarker(
          x: cluster.x,
          y: cluster.y,
          topCategory: cluster.topCategory,
          count: cluster.count,
          memberIds: cluster.memberIds,
        ),
      );
      continue;
    }

    // 未达阈值：拆回单点，各自回到原坐标。
    for (final id in cluster.memberIds) {
      final p = pointById[id];
      // 查不到只可能是调用方传了不配套的 points 与 clusters，属编程错误。
      // 静默跳过会让 Pin 莫名少几个，比直接报错难查得多。
      assert(p != null, 'clusters 中的 $id 不在 points 内，两个入参不配套');
      if (p == null) continue;
      markers.add(
        SinglePointMarker(
          x: p.x,
          y: p.y,
          topCategory: p.topCategory,
          listingId: id,
        ),
      );
    }
  }

  return markers;
}
