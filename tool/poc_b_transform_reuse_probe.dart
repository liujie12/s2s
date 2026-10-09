/// 实验：拖动中「只改 Transform、不重建 Marker」能否真正省掉绘制。
///
/// **要验证的唯一关键假设**：把 `RepaintBoundary` 夹在 `Transform` 与绘制层之间后，
/// `Transform` 的位移变化**不会**让已栅格化的子树重画。
///
/// **为什么这条假设决定成败**：POC-B 实测 1 万点拖动帧 P95 = 31.2ms；S1 分项已证
/// 单帧 Dart 四段（建点表 / 聚合 / 建Marker / 重建查表）均 O(n) 且占比均衡。故唯一
/// 出路是**减少每帧参与运算的点数**。「拖动中降级渲染」的全部指望就是：`toPixel` 是
/// 仿射的，纯拖动时整层 Marker 的位移对每个点是同一常量（`map_projection.dart:88`
/// `toPixel` 的 y 分量为 (lat−centerLat)×常数），于是用一次 `Transform.translate`
/// 顶替重算。**若 RepaintBoundary 不阻断子树重画，每帧仍要重画 O(markers)，
/// 方案收益大幅缩水，就没必要动 §6.10 的渲染架构。**
///
/// **它不回答什么**：
/// - 真机 GPU 侧栅格复用与合成成本（测试绑定无真实合成器，测不到）；
/// - 真实手势下「重算频率能否压到 <1/20 帧」（取决于滑行速度，须真机）。
/// 故本实验只给**方向性**结论：要么「方案成立、值得往下做」，要么「当场否掉」。
///
/// 运行：
///     flutter test tool/poc_b_transform_reuse_probe.dart
library;

// 本文件是实验脚本而非产品代码，print 是唯一输出手段，故整文件豁免。
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
import 'package:zhaoyazhao/nfr_constants.dart';

/// 视口尺寸（逻辑像素）。与另两个 POC-B 基准同值，便于交叉对照。
const Size _kViewport = Size(390, 780);

/// 缩放：取 app 初始值（与生产「刚打开地图」一致）。
const double _kMetersPerPixel = 12;

/// 模拟拖动的帧数。取值覆盖「一屏多一点」的位移（每帧 8px → 共 232px）。
const int _kFrames = 30;

/// 计数用画笔：每次 paint 记一笔，并画与 MarkerLayer 同量级的图元。
///
/// 用自绘画笔而非直接数 `MarkerLayer` 的私有画笔：本实验问的是 **Flutter 框架
/// 行为**（`RepaintBoundary` 是否阻断子树重画），与具体画笔无关，故只需图元量级
/// 相当即可；而 `_MarkerPainter` 是私有的，测试侧无法计数。
class _CountingPainter extends CustomPainter {
  /// 构造计数画笔。
  ///
  /// 参数：
  /// - [markerCount]：本次要画的 Marker 数（取真实压测链路的产出，保证量级真实）；
  /// - [onPaint]：每次 paint 的计数回调。
  _CountingPainter({required this.markerCount, required this.onPaint});

  /// 本次绘制的 Marker 数。
  final int markerCount;

  /// 每次 paint 的回调。
  final VoidCallback onPaint;

  @override
  void paint(Canvas canvas, Size size) {
    onPaint();
    final Paint fill = Paint()..color = const Color(0xFF1E88E5);
    for (int i = 0; i < markerCount; i++) {
      canvas.drawCircle(
        Offset((i * 7) % size.width, (i * 13) % size.height),
        i.isEven ? 12 : 5,
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CountingPainter oldDelegate) =>
      oldDelegate.markerCount != markerCount;
}

/// 组装一帧的绘制树。
///
/// 参数：
/// - [layer]：绘制层（每帧新建 widget 实例，模拟真实 `build()` 行为）；
/// - [offset]：本帧的平移量；
/// - [boundary]：是否在 Transform 与绘制层之间夹 `RepaintBoundary`。
///
/// 返回：可直接 `pumpWidget` 的 widget。
Widget _frame(Widget layer, Offset offset, {required bool boundary}) {
  final Widget painted = boundary ? RepaintBoundary(child: layer) : layer;
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ClipRect(
      child: Transform.translate(
        offset: offset,
        child: SizedBox(width: _kViewport.width, height: _kViewport.height, child: painted),
      ),
    ),
  );
}

/// 按生产口径算一遍 Marker（投影 → 聚合 → 建 Marker）。
///
/// 与 `map_screen.dart` 的 `_buildMarkersFor` 同款函数，用于取「真实的 Marker 数」
/// 与「现状口径下每帧重建的成本」。
///
/// 参数：[pins] 压测图钉；[projection] 投影参数。
/// 返回：Marker 列表。
List<MapMarker> _buildMarkers(List<MapPinDto> pins, MapProjection projection) {
  final points = List<ClusterPoint>.generate(pins.length, (i) {
    final p = pins[i];
    final px = projection.toPixel(p.lat, p.lng);
    return ClusterPoint(
      id: p.id.toString(),
      x: px.x,
      y: px.y,
      leafCategoryId: p.leafCategoryId,
      topCategory: topCategoryOf(p.leafCategoryId),
    );
  }, growable: false);
  final clusters = clusterByGrid(points, gridSize: NfrPerf.clusterGridSizePx);
  return buildMarkers(
    points,
    clusters,
    thresholdOf: (topCategory) =>
        topCategory?.clusterThreshold ?? ListingCategory.work.clusterThreshold,
  );
}

void main() {
  testWidgets('拖动中 Transform 能否免除重建与重画', (tester) async {
    tester.view.physicalSize = _kViewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const MapProjection projection = MapProjection(
      centerLat: kDefaultCenterLat,
      centerLng: kDefaultCenterLng,
      metersPerPixel: _kMetersPerPixel,
      viewportSize: (width: 390, height: 780),
    );

    print('');
    print('=== 实验：Transform 平移 vs 每帧重建（$_kFrames 帧，每帧 8px）===');
    print('');

    for (final count in [10000, 50000]) {
      final pins = buildStressPins(count);
      final markerCount = _buildMarkers(pins, projection).length;

      // 场景①：现状口径 —— 每帧重建 Marker，且无 RepaintBoundary。
      int paintsNow = 0;
      final swNow = Stopwatch()..start();
      for (int i = 0; i < _kFrames; i++) {
        _buildMarkers(pins, projection); // 每帧的 O(n) 重建
        await tester.pumpWidget(
          _frame(
            CustomPaint(
              painter: _CountingPainter(
                markerCount: markerCount,
                onPaint: () => paintsNow++,
              ),
              size: _kViewport,
            ),
            Offset(i * 8.0, i * 4.0),
            boundary: false,
          ),
        );
      }
      swNow.stop();

      // 场景②：方案口径 —— 复用同一层、只改 Transform，且夹 RepaintBoundary。
      int paintsPlan = 0;
      final swPlan = Stopwatch()..start();
      for (int i = 0; i < _kFrames; i++) {
        await tester.pumpWidget(
          _frame(
            CustomPaint(
              painter: _CountingPainter(
                markerCount: markerCount,
                onPaint: () => paintsPlan++,
              ),
              size: _kViewport,
            ),
            Offset(i * 8.0, i * 4.0),
            boundary: true,
          ),
        );
      }
      swPlan.stop();

      String perFrame(Stopwatch sw) =>
          (sw.elapsedMicroseconds / 1000 / _kFrames).toStringAsFixed(2);

      print('点数 $count（Marker $markerCount）');
      print('  ① 现状（每帧重建 + 无 RepaintBoundary）：'
          'paint 调用 $paintsNow 次 / $_kFrames 帧，'
          '每帧 ${perFrame(swNow)}ms');
      print('  ② 方案（复用 Marker + RepaintBoundary + 只改 Transform）：'
          'paint 调用 $paintsPlan 次 / $_kFrames 帧，'
          '每帧 ${perFrame(swPlan)}ms');
      print('  判定：${paintsPlan <= 2 ? '✅ 子树重画被阻断，假设成立' : '❌ 仍在重画，假设不成立'}');
      print('');
    }

    print('读法：');
    print('  - 只看「paint 调用次数」这一行：②若为 1（首帧）即证明 RepaintBoundary');
    print('    在 Transform 变化时复用了已栅格化的层；');
    print('  - ① 的每帧毫秒即 S1 的「Dart 四段」之和，是拖动中当前的每帧成本；');
    print('  - ② 的每帧毫秒应接近 0（只剩合成，而无重建无重画）；');
    print('  - 本实验无真实合成器，故②的真机收益仍须实测才可写入结论。');
    print('');
  });
}
