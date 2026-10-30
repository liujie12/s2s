/// 重叠标点（叠点堆）：分组、Marker 生成与命中判定。
///
/// 为什么必须锁：
/// ① 现状下「同一处两条」会画成两枚完全重合的 Pin，而命中是倒序遍历，
///    只点得到最上面那条 —— 这条退化**不报错**，只在真机上表现为「点不动」；
/// ② 网格聚合的分桶键含一级大类，同点不同类**永远**不聚合，改用叠点分组
///    才修得掉；若有人把分组挪到聚合之后，这一组用例会立刻变红。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/grid_cluster.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';
import 'package:zhaoyazhao/features/map/marker_layer.dart';

/// 造一个点。
///
/// 参数：[id] 本地标识；[x]/[y] 屏幕坐标；[category] 一级大类；[leaf] 叶子类目。
ClusterPoint _p(
  String id,
  double x,
  double y, {
  ListingCategory category = ListingCategory.work,
  int leaf = 10101,
}) => ClusterPoint(
  id: id,
  x: x,
  y: y,
  leafCategoryId: leaf,
  topCategory: category,
);

/// 调 [buildMarkersWithOverlap]，阈值与网格边长取与地图页一致的量级。
///
/// 参数：[points] 点集；[completeness] 完整度查表（缺省全 0）。
List<MapMarker> _build(
  List<ClusterPoint> points, {
  Map<String, int> completeness = const {},
}) => buildMarkersWithOverlap(
  points,
  thresholdOf: (topCategory) =>
      topCategory?.clusterThreshold ?? ListingCategory.work.clusterThreshold,
  gridSize: 60,
  stackTolerance: 18,
  completenessOf: (id) => completeness[id] ?? 0,
);

void main() {
  group('groupOverlappingPoints', () {
    test('容差内归为一组，容差外各自成组', () {
      final groups = groupOverlappingPoints(
        [_p('a', 100, 100), _p('b', 110, 110), _p('c', 200, 200)],
        tolerance: 18,
      );
      expect(groups.length, 2);
      expect(groups.first.map((p) => p.id), ['a', 'b']);
      expect(groups.last.single.id, 'c');
    });

    test('只看位置、不看类目 —— 同点不同类也必须同组', () {
      final groups = groupOverlappingPoints(
        [
          _p('work', 100, 100, category: ListingCategory.work),
          _p(
            'house',
            100,
            100,
            category: ListingCategory.house,
            leaf: 20101,
          ),
        ],
        tolerance: 18,
      );
      expect(groups.length, 1, reason: '按类目拆桶会让这类重合点永远点不到');
      expect(groups.single.length, 2);
    });

    test('空输入返回空列表', () {
      expect(groupOverlappingPoints(const [], tolerance: 18), isEmpty);
    });
  });

  group('buildMarkersWithOverlap', () {
    test('两条同类同点（未达阈值）收成一枚叠点堆，而不是两枚重合 Pin', () {
      final markers = _build([
        _p('1', 100, 100, leaf: 10101),
        _p('2', 100, 100, leaf: 10202),
      ]);
      expect(markers.length, 1);
      final stack = markers.single as StackMarker;
      expect(stack.count, 2);
      expect(stack.memberIds.toSet(), {'1', '2'});
    });

    test('两条不同类目同点同样收成一枚叠点堆', () {
      final markers = _build([
        _p('1', 100, 100, category: ListingCategory.work),
        _p('2', 100, 100, category: ListingCategory.house, leaf: 20101),
      ]);
      expect(markers.whereType<StackMarker>().length, 1);
      expect(markers.length, 1);
    });

    test('主层取完整度最高的那条，完整度相同时按 ID 升序', () {
      final markers = _build(
        [
          _p('2', 100, 100),
          _p('1', 104, 104),
        ],
        completeness: {'1': 0, '2': 2},
      );
      final stack = markers.single as StackMarker;
      expect(stack.representativeId, '2', reason: '完整度 2 应压过完整度 0');
      expect(stack.memberIds.first, '2', reason: '清单首行须与地图主层同一条');
    });

    test('未重合的点仍按原规则聚合，叠点堆不吞掉聚合圈', () {
      // 服务类阈值 8：8 个点全落进同一个 60px 网格（300–360），但彼此相距 22px
      // —— 大于叠点容差 18，故不该被叠点分组吃掉，仍应聚成 1 个聚合圈。
      const List<List<double>> positions = [
        [300, 300],
        [322, 300],
        [344, 300],
        [300, 322],
        [322, 322],
        [344, 322],
        [300, 344],
        [322, 344],
      ];
      final far = List.generate(
        positions.length,
        (i) => _p(
          's$i',
          positions[i][0],
          positions[i][1],
          category: ListingCategory.service,
          leaf: 50101,
        ),
      );
      final markers = _build(far);
      expect(markers.whereType<StackMarker>(), isEmpty);
      expect(markers.whereType<ClusterMarker>().length, 1);
    });

    test('叠点堆排在列表末尾（绘制在上层，倒序命中先命中它）', () {
      final markers = _build([
        _p('a', 100, 100),
        _p('b', 100, 100),
        _p('c', 400, 400),
      ]);
      expect(markers.last, isA<StackMarker>());
    });
  });

  group('MarkerLayer 命中叠点堆', () {
    StackMarker stack() => _build([
      _p('1', 100, 100),
      _p('2', 100, 100),
    ]).single as StackMarker;

    test('圆心与叠影一侧都能命中', () {
      final marker = stack();
      final layer = MarkerLayer(
        markers: [marker],
        supplyDemandById: const {'1': SupplyDemand.supply, '2': SupplyDemand.supply},
      );
      expect(layer.hitTestMarker(const Offset(100, 100)), same(marker));
      // 叠影最多偏移 8px，命中区按最远一层外扩，点叠影也要算命中。
      expect(layer.hitTestMarker(const Offset(108, 108)), same(marker));
    });

    test('远离时未命中', () {
      final marker = stack();
      final layer = MarkerLayer(
        markers: [marker],
        supplyDemandById: const {'1': SupplyDemand.supply, '2': SupplyDemand.supply},
      );
      expect(layer.hitTestMarker(const Offset(100, 160)), isNull);
    });
  });
}
