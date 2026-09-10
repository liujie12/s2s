// 网格聚合的行为断言。
//
// 为什么要这些测试：POC-A 只证明了「不慢」，不证明「算得对」。
// 聚合算错的表现是地图上 Pin 数量或位置不对，而这类错误在肉眼看图时
// 很容易被当成"数据就是这样"而漏掉，必须靠断言钉住。
//
// 运行：flutter test test/grid_cluster_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/grid_cluster.dart';

void main() {
  group('clusterByGrid', () {
    test('空输入返回空列表，不抛异常', () {
      expect(clusterByGrid([], gridSize: 80), isEmpty);
    });

    test('同格同分类的点聚成一簇，中心取成员平均', () {
      // 三点都落在 [0,80) 格内
      final points = [
        const ClusterPoint(
          id: 'a',
          x: 10,
          y: 10,
          leafCategoryId: 10101,
          topCategory: ListingCategory.work,
        ),
        const ClusterPoint(
          id: 'b',
          x: 20,
          y: 20,
          leafCategoryId: 10202,
          topCategory: ListingCategory.work,
        ),
        const ClusterPoint(
          id: 'c',
          x: 30,
          y: 30,
          leafCategoryId: 10303,
          topCategory: ListingCategory.work,
        ),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      expect(clusters, hasLength(1));
      expect(clusters.single.count, 3);
      // 平均值 (10+20+30)/3 = 20
      expect(clusters.single.x, 20);
      expect(clusters.single.y, 20);
      expect(clusters.single.memberIds, containsAll(['a', 'b', 'c']));
    });

    test('叶子类目不同但同属一个大类时仍聚合 —— 分桶用大类不用叶子', () {
      // 这条是 §10.4.1 那个 P0 的行为守卫：分桶键若误用叶子类目 ID，
      // 桶数会从 5 个大类膨胀到数十个叶子，聚合静默失效（不崩、只是变味）。
      final points = [
        const ClusterPoint(
          id: 'a',
          x: 10,
          y: 10,
          leafCategoryId: 20101,
          topCategory: ListingCategory.house,
        ),
        const ClusterPoint(
          id: 'b',
          x: 10,
          y: 10,
          leafCategoryId: 20205,
          topCategory: ListingCategory.house,
        ),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      expect(clusters, hasLength(1));
      expect(clusters.single.count, 2);
    });

    test('同格但大类不同的点不聚合 —— 大类参与分桶键', () {
      // 位置完全相同，只有大类不同
      final points = [
        const ClusterPoint(
          id: 'a',
          x: 10,
          y: 10,
          leafCategoryId: 10101,
          topCategory: ListingCategory.work,
        ),
        const ClusterPoint(
          id: 'b',
          x: 10,
          y: 10,
          leafCategoryId: 20101,
          topCategory: ListingCategory.house,
        ),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      // 若这条变红，说明分类被从分桶键里去掉了 —— 会导致聚合圈无法配色（PRD §6.15）
      expect(clusters, hasLength(2));
      expect(clusters.every((c) => c.isSinglePoint), isTrue);
    });

    test('大类为 null 的点自成一桶，不与任何真实大类混聚', () {
      // 分类树版本落后于服务端数据时 topCategoryOf 返回 null（§16.4 属预期内）。
      // 这些点必须单独成桶：混进某个真实大类会让聚合圈的配色与计数都失真。
      final points = [
        const ClusterPoint(
          id: 'a',
          x: 10,
          y: 10,
          leafCategoryId: 99999,
          topCategory: null,
        ),
        const ClusterPoint(
          id: 'b',
          x: 10,
          y: 10,
          leafCategoryId: 88888,
          topCategory: null,
        ),
        const ClusterPoint(
          id: 'c',
          x: 10,
          y: 10,
          leafCategoryId: 10101,
          topCategory: ListingCategory.work,
        ),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      // 两个 null 点聚成一簇，work 点单独一簇
      expect(clusters, hasLength(2));
      final unknownCluster = clusters.firstWhere((c) => c.topCategory == null);
      expect(unknownCluster.count, 2);
    });

    test('跨格的点不聚合，且边界点归属由 floor 决定', () {
      // x=79.9 在第 0 格，x=80.0 在第 1 格
      final points = [
        const ClusterPoint(
          id: 'a',
          x: 79.9,
          y: 0,
          leafCategoryId: 10101,
          topCategory: ListingCategory.work,
        ),
        const ClusterPoint(
          id: 'b',
          x: 80.0,
          y: 0,
          leafCategoryId: 10101,
          topCategory: ListingCategory.work,
        ),
      ];
      final clusters = clusterByGrid(points, gridSize: 80);

      // 用 round 而非 floor 会让这两点归到同格，导致缩放时归属抖动
      expect(clusters, hasLength(2));
    });

    test('单点簇标记为 isSinglePoint，供调用方决定画 Pin 还是聚合圈', () {
      final clusters = clusterByGrid([
        const ClusterPoint(
          id: 'a',
          x: 5,
          y: 5,
          leafCategoryId: 30101,
          topCategory: ListingCategory.vehicle,
        ),
      ], gridSize: 80);

      expect(clusters.single.isSinglePoint, isTrue);
      expect(clusters.single.topCategory, ListingCategory.vehicle);
    });

    test('memberIds 不可变 —— 防调用方误改聚合结果', () {
      final clusters = clusterByGrid([
        const ClusterPoint(
          id: 'a',
          x: 5,
          y: 5,
          leafCategoryId: 10101,
          topCategory: ListingCategory.work,
        ),
      ], gridSize: 80);

      expect(() => clusters.single.memberIds.add('x'), throwsUnsupportedError);
    });

    test('所有点都被计入，一个不丢', () {
      // 分散在多格，总数守恒是聚合最基本的正确性要求
      final points = List.generate(
        100,
        (i) => ClusterPoint(
          id: 'p$i',
          x: i * 7.0,
          y: i * 11.0,
          leafCategoryId: 0,
          topCategory: ListingCategory.values[i % ListingCategory.values.length],
        ),
      );
      final clusters = clusterByGrid(points, gridSize: 80);
      final total = clusters.fold<int>(0, (sum, c) => sum + c.count);

      expect(total, 100);
    });
  });
}
