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

  /// 一级大类，渲染层据此取配色。
  ///
  /// 圆心字形属二级（见 [SinglePointMarker.leafCategoryId]）；聚合圈只有配色与数字，
  /// 不需要二级信息。
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
    this.leafCategoryId,
  });

  /// 本地帖子标识。回传服务端前须转 `int`（详细设计 §10.4.3）。
  final String listingId;

  /// 叶子类目 ID（服务端口径，如 `10101`），由 [ClusterPoint.leafCategoryId] 透传。
  ///
  /// 渲染层据此取所属**二级**的字形（PRD §6.4.2 二级图标映射表）。
  /// 只影响绘制、不参与聚合，故不必提升为必填：直接构造 Marker 的测试与
  /// 降级路径可留空，渲染层会退回一级字形。
  final int? leafCategoryId;
}

/// 叠点堆 Marker：多条信息落在**几乎同一处**时只画一枚 Pin + 数量角标。
///
/// 与 [ClusterMarker] 的区别是尺度与语义：聚合圈代表「这一片很密」，点它是
/// 放大地图；叠点堆代表「这里重合了几条」，点它是**展开清单挑一条**。
/// 两者互斥 —— 进入叠点堆的点不再参与网格聚合，见 [buildMarkersWithOverlap]。
///
/// 为什么必须存在：重合的点若各画一枚 Pin，[MarkerLayer.hitTestMarker] 的
/// 倒序命中只会返回最上面那枚，下面的在屏幕上等同于不存在。
class StackMarker extends MapMarker {
  const StackMarker({
    required super.x,
    required super.y,
    required super.topCategory,
    required this.representativeId,
    required this.memberIds,
    required this.accentCategories,
    this.leafCategoryId,
  });

  /// 主层那条信息的本地标识（决定 Pin 的供需态与圆心字形）。
  ///
  /// 由调用方按「完整度最高优先」排出，故它与清单首行是同一条 —— 图面与
  /// 清单能对得上，用户不会觉得「点进去是另一条」。
  final String representativeId;

  /// 组内全部成员 ID（含 [representativeId]），顺序即清单展示顺序。
  final List<String> memberIds;

  /// 与 [memberIds] 一一对应的分类色来源，用于画叠影（第 0 项即主层）。
  ///
  /// 存整组而非只存两层，是因为「最多几层」属图面规格，应由渲染层按
  /// `NfrOverlap.stackGhostMax` 截断；本层不替它做这个决定。
  final List<ListingCategory?> accentCategories;

  /// 主层那条的叶子类目 ID（渲染层据此取二级字形）。
  final int? leafCategoryId;

  /// 组内条数（= [memberIds] 长度）。
  int get count => memberIds.length;

  /// 是否包含某条信息（选中态判定用）。
  ///
  /// 参数：[listingId] 待查的本地标识。
  /// 返回：该 ID 是否在本组内。
  bool contains(String listingId) => memberIds.contains(listingId);
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
          // 二级字形要靠叶子 ID 才能取到：不在这里透传，渲染层就只剩一级大类，
          // 同族 3–5 个二级在地图上又会长得一模一样（PRD §6.4.2）。
          leafCategoryId: p.leafCategoryId,
        ),
      );
    }
  }

  return markers;
}

/// 完整的分组流水线：**先叠点分组，再网格聚合**，最后产出可渲染的 Marker 列表。
///
/// 为什么顺序不能反：网格聚合的分桶键含一级大类，同一坐标的两条不同类目
/// 永远进不了同一桶（见 `grid_cluster.dart#clusterByGrid`），若先聚合再补叠点，
/// 这类重合点已经被拆散、拿不回来了。反过来先按位置分组则没有信息损失 ——
/// 分组只看坐标，类目只在画叠影时用到。
///
/// 与 [buildMarkers] 的关系：单点/聚合圈两条路径的行为完全一致，
/// 本函数只是在其前面插了一道叠点分组，故未达叠点条件的点仍走原逻辑。
///
/// 参数：
/// - [points]：聚合前的原始点集；
/// - [thresholdOf]：某大类的聚合阈值（口径同 [buildMarkers]）；
/// - [gridSize]：网格聚合边长（逻辑像素），转引调用方的常量真源；
/// - [stackTolerance]：叠点判定距离（逻辑像素），见 `NfrOverlap.stackTolerancePx`；
/// - [completenessOf]：信息 ID → 完整度档（0/1/2，越大越完整），用于排主层。
///
/// 返回：[MapMarker] 列表，顺序为「聚合圈 / 单点 / 叠点堆」—— 与绘制顺序一致，
///   这样 [MarkerLayer.hitTestMarker] 的倒序命中才能先命中压在最后画的叠点堆。
List<MapMarker> buildMarkersWithOverlap(
  List<ClusterPoint> points, {
  required int Function(ListingCategory? topCategory) thresholdOf,
  required double gridSize,
  required double stackTolerance,
  required int Function(String id) completenessOf,
}) {
  final List<List<ClusterPoint>> groups = groupOverlappingPoints(
    points,
    tolerance: stackTolerance,
  );

  final List<StackMarker> stacks = [];
  final List<ClusterPoint> rest = [];

  for (final group in groups) {
    if (group.length < 2) {
      rest.add(group.single);
      continue;
    }
    // 主层＝完整度最高的那条；同档按 ID 升序，保证同一批数据每次渲染顺序一致
    // （否则清单首行会在两次拖动之间跳动）。
    final List<ClusterPoint> members = [...group]
      ..sort((a, b) {
        final int byLevel = completenessOf(b.id).compareTo(completenessOf(a.id));
        return byLevel != 0 ? byLevel : a.id.compareTo(b.id);
      });
    final ClusterPoint rep = members.first;
    stacks.add(
      StackMarker(
        // 用主层坐标而非组中心：中心会漂移，且组内最大只差 18px，
        // 主层坐标至少是「真实存在的那条信息所在处」。
        x: rep.x,
        y: rep.y,
        topCategory: rep.topCategory,
        representativeId: rep.id,
        memberIds: List<String>.unmodifiable(members.map((m) => m.id)),
        accentCategories: List<ListingCategory?>.unmodifiable(
          members.map((m) => m.topCategory),
        ),
        leafCategoryId: rep.leafCategoryId,
      ),
    );
  }

  final List<Cluster> clusters = clusterByGrid(rest, gridSize: gridSize);
  return [
    ...buildMarkers(rest, clusters, thresholdOf: thresholdOf),
    ...stacks,
  ];
}
