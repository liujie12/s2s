// POC-A 算法级基准（PRD §6.10.1）。
//
// 回答的问题：Dart 侧网格聚合有没有**数量级**缺陷（如 O(n²) 导致卡死）。
// 不回答：P95 是多少 —— 那是 POC-B 的事，必须在真机上测（见 PRD §6.10.1）。
//
// 为什么是纯 Dart 而非 Flutter 测试：聚合是纯计算，用 Dart VM 直接跑可以排除
// 渲染管线与 widget 生命周期的干扰，测到的就是算法本身的耗时。
//
// 运行：
//     dart run tool/poc_a_cluster_benchmark.dart
//
// 判据（PRD §6.10.1 POC-A 通过线）：
//   1. 5 万点不卡死；
//   2. 耗时随点数**近似线性** —— 点数 ×5，耗时不应 ×25。
//      本脚本直接输出实测比值，不靠人眼看绝对毫秒数。

// 本文件是命令行基准脚本而非产品代码，print 是唯一的输出手段，故整文件豁免。
// ignore_for_file: avoid_print

import 'dart:math';

import 'package:zhaoyazhao/features/map/clustering/grid_cluster.dart';

/// 生成均匀随机分布的测试点。
///
/// 为什么用固定 seed：基准要可复现，随机分布每次不同会让比值波动无法归因。
///
/// 参数：
/// - [count]：点数。
/// - [canvasSize]：画布边长（逻辑像素），点在 [0, canvasSize) 内均匀分布。
///
/// 返回：长度为 [count] 的点集，分类在 5 类中轮转（对应 PRD §1 的 5 个分类色）。
List<ClusterPoint> _generateUniformPoints(int count, double canvasSize) {
  final rng = Random(42);
  return List.generate(
    count,
    (i) => ClusterPoint(
      id: 'p$i',
      x: rng.nextDouble() * canvasSize,
      y: rng.nextDouble() * canvasSize,
      categoryId: i % 5,
    ),
    growable: false,
  );
}

/// 生成聚集分布的测试点（模拟真实城市 —— 点扎堆在若干热点周围）。
///
/// 为什么要这一档：均匀分布是算法的**最好情况**，每格点数少、桶多而浅。
/// 真实数据扎堆时单桶会很深，若实现里藏着桶内两两比对，只有这一档才暴露。
///
/// 参数：
/// - [count]：点数。
/// - [canvasSize]：画布边长。
/// - [hotspotCount]：热点个数，点围绕热点做高斯分布。
List<ClusterPoint> _generateClusteredPoints(
  int count,
  double canvasSize, {
  int hotspotCount = 20,
}) {
  final rng = Random(42);
  final hotspots = List.generate(
    hotspotCount,
    (_) => [rng.nextDouble() * canvasSize, rng.nextDouble() * canvasSize],
  );
  // 热点半径取画布的 2%，让扎堆足够密
  final double sigma = canvasSize * 0.02;

  return List.generate(count, (i) {
    final h = hotspots[i % hotspotCount];
    // Box-Muller 变换生成高斯分布
    final u1 = rng.nextDouble().clamp(1e-9, 1.0);
    final u2 = rng.nextDouble();
    final mag = sigma * sqrt(-2 * log(u1));
    return ClusterPoint(
      id: 'p$i',
      x: (h[0] + mag * cos(2 * pi * u2)).clamp(0.0, canvasSize),
      y: (h[1] + mag * sin(2 * pi * u2)).clamp(0.0, canvasSize),
      categoryId: i % 5,
    );
  }, growable: false);
}

/// 跑一组聚合并返回耗时中位数（毫秒）。
///
/// 用中位数而非平均值：JIT 预热与 GC 会造成个别轮次的长尾，
/// 平均值会被长尾拖偏，中位数更能代表稳定态耗时。
///
/// 参数：
/// - [points]：测试点集。
/// - [gridSize]：网格边长。
/// - [rounds]：测量轮数，取中位数。
///
/// 返回：`[中位耗时ms, 簇数]`。簇数一并返回，用于确认聚合真的发生了
/// （若簇数 == 点数说明 gridSize 太小，等于没聚合，那耗时就没有参考价值）。
List<num> _measure(
  List<ClusterPoint> points, {
  required double gridSize,
  int rounds = 7,
}) {
  // 预热 2 轮，让 JIT 编译完成后再计时
  for (var i = 0; i < 2; i++) {
    clusterByGrid(points, gridSize: gridSize);
  }

  final samples = <double>[];
  int clusterCount = 0;
  for (var i = 0; i < rounds; i++) {
    final sw = Stopwatch()..start();
    final result = clusterByGrid(points, gridSize: gridSize);
    sw.stop();
    samples.add(sw.elapsedMicroseconds / 1000.0);
    clusterCount = result.length;
  }
  samples.sort();
  return [samples[samples.length ~/ 2], clusterCount];
}

void main() {
  // 画布 1080×1080 逻辑像素，网格 80px —— 取值依据 PRD §6.15 聚合阈值量级
  const double canvasSize = 1080;
  const double gridSize = 80;

  // PRD §6.10.1 规定的两档数据量
  const scales = [10000, 50000];

  print('POC-A 算法级基准 · Dart 侧网格聚合');
  print('画布 ${canvasSize.toInt()}px · 网格 ${gridSize.toInt()}px · 中位数 / 7 轮');
  print('');

  final results = <String, Map<int, double>>{};

  for (final dist in ['均匀分布', '聚集分布(20热点)']) {
    print('── $dist ──');
    results[dist] = {};
    for (final n in scales) {
      final points = dist == '均匀分布'
          ? _generateUniformPoints(n, canvasSize)
          : _generateClusteredPoints(n, canvasSize);
      final r = _measure(points, gridSize: gridSize);
      final ms = r[0] as double;
      final clusters = r[1] as int;
      results[dist]![n] = ms;
      print('  ${n.toString().padLeft(5)} 点 → '
          '${ms.toStringAsFixed(2).padLeft(8)} ms · '
          '${clusters.toString().padLeft(5)} 簇');
    }
    print('');
  }

  // 判据：点数 ×5，耗时应约 ×5（线性）；若接近 ×25 则是平方复杂度
  print('── 线性度判据（PRD §6.10.1 POC-A 通过线）──');
  bool allLinear = true;
  for (final dist in results.keys) {
    final t1 = results[dist]![10000]!;
    final t5 = results[dist]![50000]!;
    final ratio = t5 / t1;
    // 阈值 10：理想线性为 5，放宽到 10 容纳哈希扩容与 GC 抖动；
    // 平方复杂度会到 25 附近，两者区分度足够，不会误判
    final ok = ratio < 10;
    if (!ok) allLinear = false;
    print('  $dist：点数 ×5 → 耗时 ×${ratio.toStringAsFixed(2)}  '
        '${ok ? "线性 PASS" : "疑似超线性 FAIL"}');
  }

  print('');
  print(allLinear
      ? 'POC-A 结论：未发现数量级缺陷，算法可继续（D2 = 留）。'
        '\n注意：本结论不含 SLA 数字，P95 须由 POC-B 在安卓真机实测（PRD §6.10.1）。'
      : 'POC-A 结论：存在超线性退化，须改用空间索引后重跑（PRD §6.10.1 不通过处置）。');
}
