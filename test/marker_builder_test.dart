/// marker_builder 的阈值与尺寸判定测试（PRD §6.15 / §6.4.2）。
///
/// 为什么这层要单独测：`clusterByGrid` 只管「哪些点在同一格」，它不知道阈值。
/// 「几条才算聚合」是产品规格，改动频率远高于算法，且改错的表现很隐蔽 ——
/// 工作类阈值若误写成 4，城区地图看起来仍然正常，只是比该聚的时候少聚了一档。
///
/// 运行：flutter test test/marker_builder_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/grid_cluster.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';

/// 造 [count] 个落在同一网格内的点。
///
/// 坐标全部落在 0..10 之间，配合 gridSize=100 保证同格。
List<ClusterPoint> _samePointsInOneCell(int count, ListingCategory category) {
  return List.generate(
    count,
    (i) => ClusterPoint(
      id: '${category.name}-$i',
      // 刻意让每个点 x 不同：验证拆回单点时用的是原坐标而非簇中心。
      x: i.toDouble(),
      y: 0,
      categoryId: category.id,
    ),
  );
}

List<MapMarker> _build(List<ClusterPoint> points) {
  final clusters = clusterByGrid(points, gridSize: 100);
  return buildMarkers(
    points,
    clusters,
    thresholdOf: (id) => listingCategoryFromId(id).clusterThreshold,
  );
}

void main() {
  group('buildMarkers 阈值判定', () {
    test('工作类阈值 3：2 条不聚，散成 2 个单点', () {
      final markers = _build(_samePointsInOneCell(2, ListingCategory.work));
      expect(markers.length, 2);
      expect(markers.every((m) => m is SinglePointMarker), isTrue);
    });

    test('工作类阈值 3：恰好 3 条即聚 —— 「3 条聚」是达到即聚，不是超过才聚', () {
      final markers = _build(_samePointsInOneCell(3, ListingCategory.work));
      expect(markers.length, 1);
      expect(markers.single, isA<ClusterMarker>());
      expect((markers.single as ClusterMarker).count, 3);
    });

    test('房屋类阈值 5：4 条不聚 —— 同样条数在工作类已聚，验证阈值确实按分类取', () {
      final markers = _build(_samePointsInOneCell(4, ListingCategory.house));
      expect(markers.length, 4);
      expect(markers.every((m) => m is SinglePointMarker), isTrue);
    });

    test('服务类阈值 8：7 条不聚、8 条聚', () {
      expect(
        _build(_samePointsInOneCell(7, ListingCategory.service)).length,
        7,
      );
      final clustered = _build(
        _samePointsInOneCell(8, ListingCategory.service),
      );
      expect(clustered.length, 1);
      expect(clustered.single, isA<ClusterMarker>());
    });
  });

  group('未达阈值拆回单点', () {
    test('单点回到各自原坐标，不是簇中心 —— 否则同格的点会重叠、点不到第二个', () {
      final points = _samePointsInOneCell(2, ListingCategory.work);
      final markers = _build(points).cast<SinglePointMarker>();

      final xs = markers.map((m) => m.x).toList()..sort();
      expect(xs, [0.0, 1.0]);
      // 簇中心是 0.5，若实现取了中心，两个点会都是 0.5。
      expect(xs.toSet().length, 2);
    });

    test('listingId 与原始点一一对应，不丢不重', () {
      final points = _samePointsInOneCell(2, ListingCategory.work);
      final ids = _build(
        points,
      ).cast<SinglePointMarker>().map((m) => m.listingId);
      expect(ids.toSet(), points.map((p) => p.id).toSet());
    });
  });

  group('聚合 Marker 尺寸三档（PRD §6.4.2）', () {
    ClusterMarker clusterOf(int count) {
      // 用服务类（阈值 8）造大簇，避免小数量在工作类就散开。
      final markers = _build(
        _samePointsInOneCell(count, ListingCategory.service),
      );
      return markers.single as ClusterMarker;
    }

    test('2–9 条 = 32px，比单点 40px 小', () {
      expect(clusterOf(9).diameter, 32);
      expect(clusterOf(9).diameter, lessThan(kSinglePointMarkerDiameter));
    });

    test('10–99 条 = 40px，与单点等大', () {
      expect(clusterOf(10).diameter, 40);
      expect(clusterOf(99).diameter, 40);
    });

    test('100+ 条 = 48px，与选中态同大', () {
      expect(clusterOf(100).diameter, kSelectedMarkerDiameter);
    });
  });

  test('分类不同的点即使同格也不互聚 —— 混聚会让聚合圈无法配色', () {
    final points = [
      ..._samePointsInOneCell(3, ListingCategory.work),
      ..._samePointsInOneCell(3, ListingCategory.house),
    ];
    final markers = _build(points);

    // 工作 3 条达阈值聚成 1 个；房屋 3 条未达阈值 5，散成 3 个单点。
    expect(markers.whereType<ClusterMarker>().length, 1);
    expect(markers.whereType<SinglePointMarker>().length, 3);
  });

  test('空输入返回空列表', () {
    expect(_build(const []), isEmpty);
  });
}
