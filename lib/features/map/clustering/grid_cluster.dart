/// Dart 侧网格聚合（PRD §6.7）。
///
/// 为什么自己实现：`amap_map` 插件不提供原生 MarkerCluster，聚合只能在 Dart 侧做。
/// 这也是 PRD §6.10.1 要求前置 POC 的原因 —— 没有可引用的官方性能规格。
///
/// 本文件刻意**不 import Flutter**：聚合是纯计算，不碰 UI。
/// 好处是 POC-A 能在 Dart VM 里直接跑基准，不受渲染与设备干扰，
/// 也便于写单元测试。
///
/// 注意本文件持有 `ListingCategory` 枚举 —— 该枚举已拆为纯 Dart 本体
/// （`domain/listing_category.dart`）与 Flutter 样式扩展
/// （`domain/listing_category_style.dart`），故这里 import 它**不会**引入
/// Flutter 依赖。拆分动因见详细设计 §10.4.1：此前聚合层拿不到枚举，
/// 只能靠一个 `int` 代传分类，而那个 `int` 与服务端的叶子类目 ID 同型不同义。
library;

import '../../../domain/listing_category.dart';

/// 一个待聚合的原始点。
///
/// 用屏幕像素坐标而非经纬度：聚合阈值按 PRD §6.15 定义在**屏幕像素网格**上，
/// 经纬度到像素的换算由调用方（地图控件）负责，聚合本身不关心投影。
class ClusterPoint {
  /// 业务 ID，用于聚合后回查原始信息。
  ///
  /// **这是本地分桶标识，不是可直接回传服务端的值。** 服务端帖子 ID 是
  /// `int64`（契约 `PostIdPath`），此处用 `String` 只为做 Map 键与去重；
  /// 回传前须转回 `int`（详细设计 §10.4.3）。
  final String id;

  /// 屏幕横坐标（逻辑像素）。
  final double x;

  /// 屏幕纵坐标（逻辑像素）。
  final double y;

  /// 叶子类目 ID（服务端口径，如 `10101`）。仅用于透传与请求参数。
  ///
  /// **不能拿它做 `ListingCategory.values` 的下标** —— 两者取值范围完全不同，
  /// 那样做在 release 下会抛 `RangeError`（详细设计 §10.4.1）。
  /// 求一级大类请用 `topCategoryOf`（查分类树）。
  final int leafCategoryId;

  /// 一级大类（本地渲染口径，决定配色、图标与聚合阈值）。
  ///
  /// 由 [leafCategoryId] 经分类树查表得到，**不做算术推导**。
  /// 可空：本地分类树版本落后于服务端数据时查不到是预期内状态（§16.4），
  /// 此时该点仍参与聚合，只是渲染层用中性配色。
  final ListingCategory? topCategory;

  const ClusterPoint({
    required this.id,
    required this.x,
    required this.y,
    required this.leafCategoryId,
    required this.topCategory,
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

  /// 一级大类。同一簇内大类必然相同 —— 分桶键含大类，见 [clusterByGrid]。
  ///
  /// 这里是**一级大类**而非叶子类目：聚合按 5 个大类分桶（PRD §6.15 的阈值
  /// 就是按大类定义的）。若改按叶子类目分桶，桶数会从 5 涨到数十，
  /// 每桶点数骤降、聚合直接失效 —— 地图上该聚成一个圈的地方会散成一片点。
  /// 这个退化**不报错**，只表现为「效果不对」，是最难归因的一类缺陷
  /// （详细设计 §10.4.1）。
  ///
  /// 可空：分类树查不到时为 null，同为 null 的点会聚在一起（渲染为中性色）。
  final ListingCategory? topCategory;

  /// 簇内成员 ID。
  ///
  /// 保留全量而非只留代表点：点击聚合圈要能展开列表（PRD §6.9）。
  /// 代价是内存随点数线性增长，5 万点档位需在 POC-A 中观察内存峰值。
  final List<String> memberIds;

  const Cluster({
    required this.x,
    required this.y,
    required this.count,
    required this.topCategory,
    required this.memberIds,
  });

  /// 是否为单点（未与他人聚合）。调用方据此决定渲染分类 Pin 还是聚合圈。
  bool get isSinglePoint => count == 1;
}

/// 按屏幕像素网格聚合点集。
///
/// 算法：把画布切成边长 [gridSize] 的方格，落在同格且同**一级大类**的点归为一簇。
/// 复杂度 **O(n)** —— 每个点只做一次哈希桶写入，无两两比对。
/// 这是 POC-A 要验证的核心命题：不能退化成 O(n²)。
///
/// 为什么分类参与分桶：PRD §6.15 要求分类差异化聚合，且不同分类的 Pin 颜色不同，
/// 混聚会导致聚合圈无法配色。代价是同格多分类时簇数上升，属预期行为。
///
/// **分桶用一级大类，不用叶子类目**（理由见 [Cluster.topCategory]）。
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

  // 分桶键用 "格号X:格号Y:大类" 拼成字符串。
  // 为什么不用 Point 对象做 key：Dart 的 Map 对自定义类型要求正确实现
  // hashCode/== ，字符串键在 5 万量级下实测足够快且不易写错。
  // 若 POC-A 显示字符串拼接成为瓶颈，再换成位运算打包的 int 键。
  final Map<String, _Bucket> buckets = {};

  for (final p in points) {
    // floor 而非 round：round 会让边界点跳到相邻格，导致同一点在不同缩放下归属抖动。
    final int gx = (p.x / gridSize).floor();
    final int gy = (p.y / gridSize).floor();
    // 大类可空，用 name 而非 index 拼键：index 变动不会有编译错，name 变动会。
    // null 拼成字面量 'unknown'，让「树查不到」的点自成一桶，不与任何真实大类混聚。
    final String key = '$gx:$gy:${p.topCategory?.name ?? 'unknown'}';

    final bucket = buckets[key];
    if (bucket == null) {
      buckets[key] = _Bucket(topCategory: p.topCategory)..add(p);
    } else {
      bucket.add(p);
    }
  }

  return buckets.values.map((b) => b.toCluster()).toList(growable: false);
}

/// 按「屏幕距离几乎重合」把点分成若干组（PRD §6.4.2 叠点堆的前置分组）。
///
/// **为什么不能只靠 [clusterByGrid]**：网格聚合的分桶键里带了一级大类，
/// 同一坐标的「工作」与「房屋」永远进不了同一桶，于是两条完全重合的 Pin
/// 在图上只能点到最上面那条；且大类阈值（如工作 3）决定了「2 条同类同点」
/// 也不聚 —— 这条退化不报错，只表现为「点不到」。
/// 故叠点分组**只看位置、不看类目**，且必须先于网格聚合执行。
///
/// 算法：以 [tolerance] 为格边长做空间哈希，每个点只查所在格与相邻 8 格，
/// 与**组首点**比距离；在容差内即入组，否则自成新组。复杂度 O(n)，
/// 与 [clusterByGrid] 同量级，可继续跑 POC 基准。
///
/// 用「组首点」而非组中心做比较：组中心随成员增加而漂移，会让「先来的点」
/// 在后续点到来时被重新判成不合规，出现同一组内两点相距超过容差 ——
/// 而图面上它们仍画在同一个位置，属看不出来的静默不一致。
///
/// 参数：
/// - [points]：待分组的点集，允许为空；
/// - [tolerance]：判定为同一处的屏幕距离（逻辑像素），必须 > 0。
///
/// 返回：组列表。**包含单点组**（长度 1），由调用方决定哪些组画成叠点堆；
///   组顺序按「组首点首次出现顺序」稳定，组内成员保持入参顺序。
List<List<ClusterPoint>> groupOverlappingPoints(
  List<ClusterPoint> points, {
  required double tolerance,
}) {
  assert(tolerance > 0, 'tolerance 必须为正数，收到 $tolerance');

  if (points.isEmpty) return const [];

  final List<List<ClusterPoint>> groups = [];
  final List<ClusterPoint> seeds = [];
  // 格键 → 组下标列表。用字符串键的理由同 [clusterByGrid]。
  final Map<String, List<int>> cells = {};
  final double toleranceSq = tolerance * tolerance;

  for (final p in points) {
    final int gx = (p.x / tolerance).floor();
    final int gy = (p.y / tolerance).floor();
    int? hitGroup;
    // 只查 3×3 邻格：容差半径不超过一格边长，隔一格的组不可能命中。
    for (int dx = -1; dx <= 1 && hitGroup == null; dx++) {
      for (int dy = -1; dy <= 1; dy++) {
        final List<int>? bucket = cells['${gx + dx}:${gy + dy}'];
        if (bucket == null) continue;
        for (final int gi in bucket) {
          final ClusterPoint seed = seeds[gi];
          final double ddx = p.x - seed.x;
          final double ddy = p.y - seed.y;
          if (ddx * ddx + ddy * ddy <= toleranceSq) {
            hitGroup = gi;
            break;
          }
        }
        if (hitGroup != null) break;
      }
    }

    if (hitGroup != null) {
      groups[hitGroup].add(p);
      continue;
    }
    final int gi = groups.length;
    groups.add(<ClusterPoint>[p]);
    seeds.add(p);
    (cells['$gx:$gy'] ??= <int>[]).add(gi);
  }

  return groups;
}

/// 聚合过程中的可变累加器。
///
/// 单独一个类而非用元组：累加过程要改状态，而 [Cluster] 是不可变的。
/// 分开后 [Cluster] 可以全 final，调用方拿到的结果不会被意外改写。
class _Bucket {
  final ListingCategory? topCategory;

  /// 坐标累加和，最后除以 count 得平均值。
  /// 边累加边求平均会引入浮点误差累积，故存和。
  double _sumX = 0;
  double _sumY = 0;
  final List<String> _ids = [];

  _Bucket({required this.topCategory});

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
      topCategory: topCategory,
      memberIds: List.unmodifiable(_ids),
    );
  }
}
