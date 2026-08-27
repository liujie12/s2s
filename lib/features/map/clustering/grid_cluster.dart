/// Dart 侧网格聚合（PRD §6.7）。
///
/// 为什么自己实现：`amap_map` 插件不提供原生 MarkerCluster，聚合只能在 Dart 侧做。
/// 这也是 PRD §6.10.1 要求前置 POC 的原因 —— 没有可引用的官方性能规格。
///
/// 本文件刻意**不 import Flutter**：聚合是纯计算，不碰 UI。
/// 好处是 POC-A 能在 Dart VM 里直接跑基准，不受渲染与设备干扰，
/// 也便于写单元测试。
library;

/// 一个待聚合的原始点。
///
/// 用屏幕像素坐标而非经纬度：聚合阈值按 PRD §6.15 定义在**屏幕像素网格**上，
/// 经纬度到像素的换算由调用方（地图控件）负责，聚合本身不关心投影。
class ClusterPoint {
  /// 业务 ID，用于聚合后回查原始信息。
  final String id;

  /// 屏幕横坐标（逻辑像素）。
  final double x;

  /// 屏幕纵坐标（逻辑像素）。
  final double y;

  /// 分类 ID（PRD §6.15 要求分类差异化聚合阈值，故须随点携带）。
  final int categoryId;

  const ClusterPoint({
    required this.id,
    required this.x,
    required this.y,
    required this.categoryId,
  });
}

/// 聚合结果的一个簇。单点也是一个簇（count == 1），由调用方决定画 Pin 还是画聚合圈。
class Cluster {
  /// 簇中心横坐标 —— 成员算术平均，不是网格中心。
  ///
  /// 用平均值而非网格中心，是为了避免点明显偏在格子一角时聚合圈画到空白处。
  final double x;

  /// 簇中心纵坐标（成员算术平均）。
  final double y;

  /// 簇内点数。
  final int count;

  /// 分类 ID。同一簇内分类必然相同 —— 分桶键含分类，见 [clusterByGrid]。
  final int categoryId;

  /// 簇内成员 ID。
  ///
  /// 保留全量而非只留代表点：点击聚合圈要能展开列表（PRD §6.9）。
  /// 代价是内存随点数线性增长，5 万点档位需在 POC-A 中观察内存峰值。
  final List<String> memberIds;

  const Cluster({
    required this.x,
    required this.y,
    required this.count,
    required this.categoryId,
    required this.memberIds,
  });

  /// 是否为单点（未与他人聚合）。调用方据此决定渲染分类 Pin 还是聚合圈。
  bool get isSinglePoint => count == 1;
}

/// 按屏幕像素网格聚合点集。
///
/// 算法：把画布切成边长 [gridSize] 的方格，落在同格且同分类的点归为一簇。
/// 复杂度 **O(n)** —— 每个点只做一次哈希桶写入，无两两比对。
/// 这是 POC-A 要验证的核心命题：不能退化成 O(n²)。
///
/// 为什么分类参与分桶：PRD §6.15 要求分类差异化聚合，且不同分类的 Pin 颜色不同，
/// 混聚会导致聚合圈无法配色。代价是同格多分类时簇数上升，属预期行为。
///
/// 参数：
/// - [points]：待聚合点集，允许为空。
/// - [gridSize]：网格边长（逻辑像素），必须 > 0。越大聚合越狠、簇越少。
///
/// 返回：簇列表，顺序不保证稳定（取决于哈希遍历顺序），调用方若需稳定顺序须自行排序。
List<Cluster> clusterByGrid(
  List<ClusterPoint> points, {
  required double gridSize,
}) {
  assert(gridSize > 0, 'gridSize 必须为正数，收到 $gridSize');

  if (points.isEmpty) return const [];

  // 分桶键用 "格号X:格号Y:分类" 拼成字符串。
  // 为什么不用 Point 对象做 key：Dart 的 Map 对自定义类型要求正确实现
  // hashCode/== ，字符串键在 5 万量级下实测足够快且不易写错。
  // 若 POC-A 显示字符串拼接成为瓶颈，再换成位运算打包的 int 键。
  final Map<String, _Bucket> buckets = {};

  for (final p in points) {
    // floor 而非 round：round 会让边界点跳到相邻格，导致同一点在不同缩放下归属抖动。
    final int gx = (p.x / gridSize).floor();
    final int gy = (p.y / gridSize).floor();
    final String key = '$gx:$gy:${p.categoryId}';

    final bucket = buckets[key];
    if (bucket == null) {
      buckets[key] = _Bucket(categoryId: p.categoryId)..add(p);
    } else {
      bucket.add(p);
    }
  }

  return buckets.values.map((b) => b.toCluster()).toList(growable: false);
}

/// 聚合过程中的可变累加器。
///
/// 单独一个类而非用元组：累加过程要改状态，而 [Cluster] 是不可变的。
/// 分开后 [Cluster] 可以全 final，调用方拿到的结果不会被意外改写。
class _Bucket {
  final int categoryId;

  /// 坐标累加和，最后除以 count 得平均值。
  /// 边累加边求平均会引入浮点误差累积，故存和。
  double _sumX = 0;
  double _sumY = 0;
  final List<String> _ids = [];

  _Bucket({required this.categoryId});

  void add(ClusterPoint p) {
    _sumX += p.x;
    _sumY += p.y;
    _ids.add(p.id);
  }

  Cluster toCluster() {
    final int n = _ids.length;
    return Cluster(
      x: _sumX / n,
      y: _sumY / n,
      count: n,
      categoryId: categoryId,
      memberIds: List.unmodifiable(_ids),
    );
  }
}
