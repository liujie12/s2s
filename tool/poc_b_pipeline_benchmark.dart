/// POC-B 分项分解基准（先分解再优化）。
///
/// **它回答什么**：真机 POC-B 只给出一个端到端数字（5 万点帧 P95 = 208.3ms），
/// 不知道钱花在哪一环。本基准用**生产同款函数**把单帧的 Dart 工作拆成六段计时，
/// 供「该优化哪一环」作判据 —— 依据是说明文档「原则 74：性能优化前先测各环节
/// 占比，否则很可能优化到不占比重的那一环」（POC-A 正是靠这条推翻了「聚合是
/// 瓶颈」的直觉）。
///
/// **它不回答什么**：
/// - **真机绝对耗时**：测试绑定跑在开发机 Dart VM（JIT），与手机 release（AOT）
///   差异大，本文件的毫秒数**不得写入 SLA**；
/// - **GPU / 光栅化耗时**：帧耗时的另一大头在光栅化，测试绑定测不到（说明文档
///   条目 [65] 已定：本项目 Marker 走画布绘制，大头在光栅化）。
///
/// 运行：
///     flutter test tool/poc_b_pipeline_benchmark.dart
///
/// 判据：看「Dart 小计」六段里谁占比最大 —— 占比小的环节即便改成零也救不了
/// 端到端帧耗时，不该先动它。
library;

// 本文件是基准脚本而非产品代码，print 是唯一输出手段，故整文件豁免。
// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/map_dto.dart';
import 'package:zhaoyazhao/features/discovery/stress_data.dart';
import 'package:zhaoyazhao/features/location/location_center.dart';
import 'package:zhaoyazhao/features/map/clustering/grid_cluster.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';
import 'package:zhaoyazhao/features/map/map_projection.dart';
import 'package:zhaoyazhao/features/map/marker_layer.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

/// 视口尺寸（逻辑像素）。与 `poc_b_paint_benchmark.dart` 同值，便于两处对照。
const Size _kViewport = Size(390, 780);

/// 缩放：一像素代表多少米。取 app 初始值（`map_screen.dart` 的 12）——
/// 使压测点的分布尺度与「用户刚打开地图」时一致。
const double _kMetersPerPixel = 12;

/// 每段计时的重复次数，取均值。>1 用于摊掉首次分配与 JIT 预热。
const int _kReps = 5;

/// 防止死代码消除的累加槽：把每段结果汇入它并在末尾打印一次。
///
/// 不这么做的话，`纯投影` 那段（结果被丢弃）可能被 VM 整体优化掉，
/// 测出来会是一个漂亮但不存在的「0ms」。
double _sink = 0;

/// 构造投影参数（中心与压测点同一处，使点落在视口内）。
///
/// 返回：[MapProjection]。
MapProjection _projection() => const MapProjection(
  centerLat: kDefaultCenterLat,
  centerLng: kDefaultCenterLng,
  metersPerPixel: _kMetersPerPixel,
  viewportSize: (width: 390, height: 780),
);

/// 生产口径第一段：投影 + 建 `ClusterPoint` 表。
///
/// 与 `map_screen.dart` 的 `_buildMarkersFor` 逐句对应（含 `topCategoryOf` 查表
/// 与 `id.toString()`），**不是复制的近似实现** —— 复制的实现一旦与生产漂移，
/// 量出来的占比就指向错误的环节。
///
/// 参数：[pins] 压测图钉；[projection] 投影参数。
/// 返回：`ClusterPoint` 列表（供后续聚合与建 Marker 使用）。
List<ClusterPoint> _buildPoints(List<MapPinDto> pins, MapProjection projection) {
  return pins
      .map((p) {
        final px = projection.toPixel(p.lat, p.lng);
        return ClusterPoint(
          id: p.id.toString(),
          x: px.x,
          y: px.y,
          leafCategoryId: p.leafCategoryId,
          topCategory: topCategoryOf(p.leafCategoryId),
        );
      })
      .toList(growable: false);
}

/// 优化后口径：建点表用「已缓存的 id 串与叶子→大类表」，不逐帧转串/查表。
///
/// 对应 `map_screen.dart` 的 `_PinsDerived` 记忆化（S2 改动）。与 [_buildPoints]
/// 的唯一差别就是这两个入参来源 —— 故两张表的差值即该记忆化的收益。
///
/// 参数：
///   [pins] 压测图钉；[projection] 投影参数；
///   [ids] 与 pins 同序的 id 串（预计算）；[topByLeaf] 叶子→大类表（预计算）。
/// 返回：`ClusterPoint` 列表。
List<ClusterPoint> _buildPointsCached(
  List<MapPinDto> pins,
  MapProjection projection,
  List<String> ids,
  Map<int, ListingCategory?> topByLeaf,
) {
  return List<ClusterPoint>.generate(pins.length, (i) {
    final p = pins[i];
    final px = projection.toPixel(p.lat, p.lng);
    return ClusterPoint(
      id: ids[i],
      x: px.x,
      y: px.y,
      leafCategoryId: p.leafCategoryId,
      topCategory: topByLeaf[p.leafCategoryId],
    );
  }, growable: false);
}

/// 生产口径最后一段：重建 `id → 供需` 查表（`map_screen.dart` 每帧重建一次）。
///
/// 参数：[pins] 压测图钉。
/// 返回：`Map<String, SupplyDemand>`。
Map<String, SupplyDemand> _buildSupplyMap(List<MapPinDto> pins) {
  return {
    for (final p in pins)
      p.id.toString(): supplyDemandFromCompact(p.typeCode),
  };
}

/// 计时一段（重复 [_kReps] 次取均值）。
///
/// 参数：[body] 被计时的无参闭包。
/// 返回：平均耗时（毫秒）。
double _timeIt(void Function() body) {
  // 先空跑一次预热（JIT + 首次分配），不计入。
  body();
  final sw = Stopwatch()..start();
  for (int i = 0; i < _kReps; i++) {
    body();
  }
  sw.stop();
  return sw.elapsedMicroseconds / 1000 / _kReps;
}

/// 测「空 Marker 列表」下同一棵 widget 树的重建开销（基线）。
///
/// **为什么必须减掉它**：`pumpWidget` 每次都重建 MaterialApp/Scaffold/MarkerLayer
/// 整棵树，这部分与 Marker 数量无关。不扣基线时，若 Marker 数少，固定开销会盖过
/// 绘制本身 —— 实测 500 点行（128 个 Marker）报 12.4ms，而 2000 点行（235 个
/// Marker）只报 7.0ms，**非单调**即为此故，直接读会得出荒谬结论。
///
/// 参数：[tester] 测试句柄。
/// 返回：空列表下的平均耗时（毫秒）。
Future<double> _paintBaseline(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: MarkerLayer(markers: [], supplyDemandById: {})),
    ),
  );
  const int repaints = 5;
  final sw = Stopwatch()..start();
  for (int i = 0; i < repaints; i++) {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: MarkerLayer(markers: [], supplyDemandById: {})),
      ),
    );
  }
  sw.stop();
  return sw.elapsedMicroseconds / 1000 / repaints;
}

/// 测一组 Marker 的绘制耗时（已含整树重建，调用方须减 [_paintBaseline]）。
///
/// 参数：[tester] 测试句柄；[markers] 待绘 Marker；[supply] 供需查表。
/// 返回：平均耗时（毫秒，未扣基线）。
Future<double> _paintRaw(
  WidgetTester tester,
  List<MapMarker> markers,
  Map<String, SupplyDemand> supply,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MarkerLayer(markers: markers, supplyDemandById: supply),
      ),
    ),
  );
  const int repaints = 5;
  final sw = Stopwatch()..start();
  for (int i = 0; i < repaints; i++) {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkerLayer(
            markers: List<MapMarker>.of(markers),
            supplyDemandById: supply,
          ),
        ),
      ),
    );
  }
  sw.stop();
  return sw.elapsedMicroseconds / 1000 / repaints;
}

void main() {
  testWidgets('POC-B 单帧 Dart 管线分项占比', (tester) async {
    tester.view.physicalSize = _kViewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final projection = _projection();

    // 绘制基线（空 Marker 列表）只需测一次：它是整树重建的固定成本。
    final double paintBaseline = await _paintBaseline(tester);

    print('');
    print('=== POC-B 分项分解（开发机 CPU 侧，绝对毫秒数不得写入 SLA）===');
    print('视口 ${_kViewport.width.toInt()}x${_kViewport.height.toInt()}'
        '  缩放 ${_kMetersPerPixel}m/px  网格 ${NfrPerf.clusterGridSizePx}px'
        '  每段重复 $_kReps 次取均值（另含 1 次预热）');
    print('');
    print('点数\t纯投影\t建点表\t缓存建点表\t聚合\t建Marker\t重建查表'
        '\tDart小计\t优化后Dart\t降幅\t绘制\tMarker数');

    for (final count in [500, 2000, 10000, 50000]) {
      final pins = buildStressPins(
        count,
        centerLat: kDefaultCenterLat,
        centerLng: kDefaultCenterLng,
      );

      // 纯投影（诊断段，结果丢弃）。
      final double tProject = _timeIt(() {
        double acc = 0;
        for (final p in pins) {
          acc += projection.toPixel(p.lat, p.lng).x;
        }
        _sink += acc;
      });

      // 后续各段需要 points / clusters 作为输入，先在生产口径下算一份。
      final points = _buildPoints(pins, projection);
      final clusters = clusterByGrid(points, gridSize: NfrPerf.clusterGridSizePx);

      final double tPoints = _timeIt(() => _sink += _buildPoints(pins, projection).length);
      final double tCluster = _timeIt(
        () => _sink += clusterByGrid(points, gridSize: NfrPerf.clusterGridSizePx).length,
      );
      final double tMarkers = _timeIt(
        () => _sink += buildMarkers(
          points,
          clusters,
          thresholdOf: (topCategory) =>
              topCategory?.clusterThreshold ?? ListingCategory.work.clusterThreshold,
        ).length,
      );
      final double tSupply = _timeIt(() => _sink += _buildSupplyMap(pins).length);

      // 优化后口径（S2 的 _PinsDerived 记忆化）：id 串与「叶子→大类」表一次性
      // 预计算后走缓存命中；供需查表不再每帧重建（收益单独在下面算式里体现）。
      final cachedIds = List<String>.generate(pins.length, (i) => pins[i].id.toString());
      final cachedTop = <int, ListingCategory?>{};
      for (final p in pins) {
        if (!cachedTop.containsKey(p.leafCategoryId)) {
          cachedTop[p.leafCategoryId] = topCategoryOf(p.leafCategoryId);
        }
      }
      final double tPointsCached = _timeIt(
        () => _sink += _buildPointsCached(pins, projection, cachedIds, cachedTop).length,
      );

      final markers = buildMarkers(
        points,
        clusters,
        thresholdOf: (topCategory) =>
            topCategory?.clusterThreshold ?? ListingCategory.work.clusterThreshold,
      );
      final supply = _buildSupplyMap(pins);

      // 绘制：与 poc_b_paint_benchmark 同法（换新 list 实例触发 shouldRepaint），
      // 但须扣掉整树重建的固定开销，否则 Marker 少时读数是 Widget 成本而非绘制成本。
      final double tPaint = await _paintRaw(tester, markers, supply) - paintBaseline;

      final double dartSum = tPoints + tCluster + tMarkers + tSupply;
      final double optDart = tPointsCached + tCluster + tMarkers;
      final double dropPct =
          dartSum == 0 ? 0 : (dartSum - optDart) / dartSum * 100;

      String f(double v) => v.toStringAsFixed(1);
      print(
        '$count\t${f(tProject)}\t${f(tPoints)}\t\t${f(tPointsCached)}'
        '\t\t${f(tCluster)}\t${f(tMarkers)}\t\t${f(tSupply)}'
        '\t\t${f(dartSum)}\t\t${f(optDart)}\t\t${dropPct.toStringAsFixed(0)}%'
        '\t${f(tPaint)}\t${markers.length}',
      );
    }

    print('');
    print('读法：');
    print('  1. 「Dart小计」四段（建点表 / 聚合 / 建Marker / 重建查表）占比均衡，'
        '没有单一瓶颈 —— 微优化一段最多吃掉四分之一；');
    print('  2. 「建点表 − 纯投影」= ClusterPoint 分配 + topCategoryOf 查表 + id 转串；'
        '「缓存建点表」列是 S2 记忆化（_PinsDerived）后的口径；');
    print('  3. 「降幅」= 记忆化对单帧 Dart 开销的削减比例'
        '（省掉每帧重建查表 + 逐帧转串/查表）；');
    print('  4. 「绘制」列噪声大（2000 点行曾出负值），只在大点数下可读，'
        '不要据此推 SLA；绘制另有专门基准 tool/poc_b_paint_benchmark.dart；');
    print('  5. 本表是开发机 JIT 数据，手机 release AOT 的占比可能不同，'
        '只能用来看「相对谁大谁小」。');
    print('');
    print('(sink=${_sink.toStringAsFixed(0)}，仅用于防止死代码消除)');
    print('');
  });
}
