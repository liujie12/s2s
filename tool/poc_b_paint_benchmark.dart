/// POC-B 前置：Marker 绘制开销基准（PRD §6.10.1）。
///
/// **它回答什么**：真机到位前，先在开发机上测出 `MarkerLayer` 一帧的 CPU 开销
/// 随点数如何增长。POC-A 已证明聚合算法只占 300ms 预算的 1.6%（条目 [63]），
/// 瓶颈在渲染侧 —— 但「渲染侧」当时还没实现，究竟慢在哪无从谈起。现在实现了，
/// 这一步就是把「渲染侧」再拆开一层。
///
/// **它不回答什么**：P95 与帧率。那需要真实 GPU 管线与目标机型，是 POC-B 本身
/// 的事。本基准跑在测试绑定里，只测 build/layout/paint 的 CPU 部分。
/// **开发机上的绝对毫秒数不得写入 SLA** —— 低端安卓的 CPU 单核性能通常只有
/// 开发机的三到五分之一，直接引用会得出一个偏乐观的承诺。
///
/// 运行：
///     flutter test tool/poc_b_paint_benchmark.dart
///
/// 判据：耗时随点数**近似线性**。若出现超线性，说明绘制路径里藏着按点数
/// 平方增长的操作，那必须在真机测数之前修掉 —— 否则真机测出的数字反映的是
/// 这个缺陷，而不是方案本身的性能。
library;

// 本文件是基准脚本而非产品代码，print 是唯一输出手段，故整文件豁免。
// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';
import 'package:zhaoyazhao/features/map/marker_layer.dart';

/// 造 [count] 个 Marker，混合单点与聚合。
///
/// 混合而非全单点：两者绘制路径不同（聚合圆画数字，单点画图标 + 可能的角标），
/// 只测一种会漏掉另一种的开销。比例按真实地图的观感取三成聚合。
({List<MapMarker> markers, Map<String, SupplyDemand> supplyDemand})
_buildMarkers(int count) {
  final List<MapMarker> markers = [];
  final Map<String, SupplyDemand> supplyDemand = {};
  for (int i = 0; i < count; i++) {
    // 铺满一个 390×780 的视口。取模而非随机：基准要可复现。
    final double x = (i * 37 % 390).toDouble();
    final double y = (i * 53 % 780).toDouble();
    final int categoryId = i % ListingCategory.values.length;
    if (i % 10 < 3) {
      markers.add(
        ClusterMarker(
          x: x,
          y: y,
          count: 2 + (i % 300),
          categoryId: categoryId,
          memberIds: const [],
        ),
      );
    } else {
      final String id = 'p$i';
      markers.add(
        SinglePointMarker(x: x, y: y, categoryId: categoryId, listingId: id),
      );
      // 三成需求：需求态多画一个 ? 角标，是更贵的那条路径。
      supplyDemand[id] = i % 10 < 6 ? SupplyDemand.supply : SupplyDemand.demand;
    }
  }
  return (markers: markers, supplyDemand: supplyDemand);
}

void main() {
  testWidgets('MarkerLayer 绘制开销随点数的增长曲线', (tester) async {
    tester.view.physicalSize = const Size(390, 780);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    print('');
    print('=== POC-B 前置：Marker 绘制开销基准 ===');
    print('（开发机 CPU 侧耗时，不可直接用作 SLA）');
    print('');
    print('点数\t首帧(ms)\t重绘均值(ms)\t每点(µs)');

    double? baselinePerPoint;

    for (final count in [500, 2000, 10000, 50000]) {
      final data = _buildMarkers(count);

      final sw = Stopwatch()..start();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MarkerLayer(
              markers: data.markers,
              supplyDemandById: data.supplyDemand,
            ),
          ),
        ),
      );
      sw.stop();
      final double firstMs = sw.elapsedMicroseconds / 1000;

      // 重绘：换一个新的 markers 列表实例触发 shouldRepaint，
      // 测的是稳态下每帧要付的钱 —— 拖动地图时正是这条路径。
      const int repaints = 5;
      final swRepaint = Stopwatch()..start();
      for (int i = 0; i < repaints; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MarkerLayer(
                markers: List<MapMarker>.of(data.markers),
                supplyDemandById: data.supplyDemand,
              ),
            ),
          ),
        );
      }
      swRepaint.stop();
      final double repaintMs = swRepaint.elapsedMicroseconds / 1000 / repaints;

      final double perPointUs = repaintMs * 1000 / count;
      baselinePerPoint ??= perPointUs;

      print(
        '$count\t${firstMs.toStringAsFixed(1)}\t\t'
        '${repaintMs.toStringAsFixed(1)}\t\t'
        '${perPointUs.toStringAsFixed(2)}',
      );
    }

    print('');
    print('读法：「每点 µs」若随点数基本持平 → 线性，绘制方案可用；');
    print('      若随点数明显上升 → 超线性，绘制路径里有按点数平方增长的操作。');
    print('');
  });
}
