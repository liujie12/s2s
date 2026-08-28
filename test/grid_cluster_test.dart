// 网格聚合的行为断言。
//
// 为什么要这些测试：POC-A 只证明了「不慢」，不证明「算得对」。
// 聚合算错的表现是地图上 Pin 数量或位置不对，而这类错误在肉眼看图时
// 很容易被当成"数据就是这样"而漏掉，必须靠断言钉住。
//
// 运行：flutter test test/grid_cluster_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/map/clustering/grid_cluster.dart';

void main() {
  group('clusterByGrid', () {
    test('空输入返回空列表，不抛异常', () {
      expect(clusterByGrid([], gridSize: 80), isEmpty);
    });

    test('同格同分类的点聚成一簇，中心取成员平均', () {
      // 三点都落在 [0,80) 格内
      final points = [
        const ClusterPoint(id: 'a', x: 10, y: 10, categoryId: 1),
        const ClusterPoint(id: 'b', x: 20, y: 20, categoryId: 1),
        const ClusterPoint(id: 'c', x: 30, y: 30, categoryId: 1),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      expect(clusters, hasLength(1));
      expect(clusters.single.count, 3);
      // 平均值 (10+20+30)/3 = 20
      expect(clusters.single.x, 20);
      expect(clusters.single.y, 20);
      expect(clusters.single.memberIds, containsAll(['a', 'b', 'c']));
    });

    test('同格但分类不同的点不聚合 —— 分类参与分桶键', () {
      // 位置完全相同，只有分类不同
      final points = [
        const ClusterPoint(id: 'a', x: 10, y: 10, categoryId: 1),
        const ClusterPoint(id: 'b', x: 10, y: 10, categoryId: 2),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      // 若这条变红，说明分类被从分桶键里去掉了 —— 会导致聚合圈无法配色（PRD §6.15）
      expect(clusters, hasLength(2));
      expect(clusters.every((c) => c.isSinglePoint), isTrue);
    });

    test('跨格的点不聚合，且边界点归属由 floor 决定', () {
      // x=79.9 在第 0 格，x=80.0 在第 1 格
      final points = [
        const ClusterPoint(id: 'a', x: 79.9, y: 0, categoryId: 1),
        const ClusterPoint(id: 'b', x: 80.0, y: 0, categoryId: 1),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      // 用 round 而非 floor 会让这两点归到同格，导致缩放时归属抖动
      expect(clusters, hasLength(2));
    });

    test('单点簇标记为 isSinglePoint，供调用方决定画 Pin 还是聚合圈', () {
      final clusters = clusterByGrid([
        const ClusterPoint(id: 'a', x: 5, y: 5, categoryId: 3),
      ], gridSize: 80);

      expect(clusters.single.isSinglePoint, isTrue);
      expect(clusters.single.categoryId, 3);
    });

    test('memberIds 不可变 —— 防调用方误改聚合结果', () {
      final clusters = clusterByGrid([
        const ClusterPoint(id: 'a', x: 5, y: 5, categoryId: 1),
      ], gridSize: 80);

      expect(() => clusters.single.memberIds.add('x'), throwsUnsupportedError);
    });

    test('所有点都被计入，一个不丢', () {
      // 分散在多格，总数守恒是聚合最基本的正确性要求
      final points = List.generate(
        100,
        (i) =>
            ClusterPoint(id: 'p$i', x: i * 7.0, y: i * 11.0, categoryId: i % 5),
      );
      final clusters = clusterByGrid(points, gridSize: 80);
      final total = clusters.fold<int>(0, (sum, c) => sum + c.count);

      expect(total, 100);
    });
  });
}
