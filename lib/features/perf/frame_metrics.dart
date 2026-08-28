/// 帧耗时埋点（PRD §6.10.1 POC-B 定标级 + 兜底方案第 1 条）。
///
/// **为什么是产品代码而不是一次性脚本**：PRD:1371/1383 要求 POC-B 的采集与
/// 上线后的性能日志埋点「为同一套代码，不重复实现」。写成脚本则上线时要重写
/// 一遍，而重写出来的版本与 POC 测的不是同一个东西，实测数字也就失去了参照。
///
/// **为什么不需要把手机连在开发机上**：`addTimingsCallback` 由引擎在每帧
/// 光栅化完成后回调，数据完全在应用内产生。于是任何能装 APK 的安卓设备都能
/// 自行出数（PRD:1371），不必在被测机上搭 Flutter 环境。
///
/// **口径对齐 PRD §14.6**：帧渲染判据是 ≤16ms（60fps），统计量取 P95 而非
/// 平均值 —— 平均值会把偶发的长帧摊平，而用户感知到的卡顿恰恰来自长帧。
library;

import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// 单帧耗时的判据线（毫秒）。PRD §14.6：帧渲染 ≤16ms（60fps）。
const double kFrameBudgetMs = 16.0;

/// 帧耗时采样器。
///
/// 采集的是 `FrameTiming.totalSpan` —— 从帧被调度到光栅化结束的总时长。
/// 不用 `buildDuration` 单项：用户感知的卡顿是整帧的，只看 build 会漏掉
/// 光栅化侧的开销，而本项目的 Marker 恰恰是画布绘制、开销主要落在光栅化。
class FrameMetrics {
  FrameMetrics({this.capacity = 2000});

  /// 保留的最近样本数。
  ///
  /// 有上限而非无限累积：POC 会连续跑几分钟，无上限则内存随时间线性增长，
  /// 而内存峰值本身是 POC-B 的观测项之一（PRD:1383），被采集器自己污染就没法测了。
  /// 2000 帧在 60fps 下约 33 秒，足够覆盖一次交互序列。
  final int capacity;

  final Queue<double> _samples = Queue<double>();

  /// 累计观测帧数（不受 [capacity] 限制，用于说明样本的代表性）。
  int _totalFrames = 0;

  /// 累计超预算帧数（同上，全程计数）。
  int _totalJankFrames = 0;

  bool _listening = false;

  /// 开始采集。重复调用无副作用。
  void start() {
    if (_listening) return;
    _listening = true;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  /// 停止采集。已采集的样本保留，可继续读取统计量。
  void stop() {
    if (!_listening) return;
    _listening = false;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
  }

  /// 清空样本与累计计数，用于切换压测档位后重新计时。
  ///
  /// 换档不清零会让新档位的数据被上一档的样本稀释 —— 而两档的结论正是
  /// POC 要对比的东西。
  void reset() {
    _samples.clear();
    _totalFrames = 0;
    _totalJankFrames = 0;
  }

  /// 引擎回调：一次可能带回多帧的数据，故须遍历。
  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      addSampleMs(t.totalSpan.inMicroseconds / 1000.0);
    }
  }

  /// 记录一个帧耗时样本。
  ///
  /// 公开而非私有，是为了让统计逻辑能被单测直接喂数据。走 `FrameTiming` 构造
  /// 假样本需要拼六个时间戳，测试会变成在验证「我拼对了没有」而不是分位算得对不对。
  @visibleForTesting
  void addSampleMs(double ms) {
    _totalFrames++;
    if (ms > kFrameBudgetMs) _totalJankFrames++;
    _samples.addLast(ms);
    if (_samples.length > capacity) _samples.removeFirst();
  }

  int get totalFrames => _totalFrames;
  int get totalJankFrames => _totalJankFrames;
  int get sampleCount => _samples.length;

  /// 超预算帧占比（0–1）。无样本时返回 0。
  double get jankRatio =>
      _totalFrames == 0 ? 0 : _totalJankFrames / _totalFrames;

  /// 指定分位的帧耗时（毫秒）。[percentile] 取 0–100。
  ///
  /// 用「排序后按下标取值」的最近秩法，不做插值：POC 要的是量级判断，
  /// 插值带来的零点几毫秒差异改变不了「达标 / 不达标」的结论，却会让
  /// 不同工具算出的数字对不上、徒增解释成本。
  double percentileMs(double percentile) {
    if (_samples.isEmpty) return 0;
    final sorted = _samples.toList()..sort();
    // 最近秩法 ceil(p/100 × N) - 1。用 ceil 而非 round：round 会让 P50 在
    // 偶数样本下取到中位数偏高的那一个（100 样本时 49.5 → 50，即第 51 个值），
    // 与「P50 是中位数」的直觉不符，读数时容易被当成实现出错。
    final int rank = (percentile / 100 * sorted.length).ceil();
    return sorted[rank.clamp(1, sorted.length) - 1];
  }

  double get p50Ms => percentileMs(50);
  double get p95Ms => percentileMs(95);
  double get p99Ms => percentileMs(99);

  double get maxMs =>
      _samples.isEmpty ? 0 : _samples.reduce((a, b) => a > b ? a : b);

  /// 帧耗时直方图，用于在应用内直接看清分布（PRD:1371）。
  ///
  /// 只报 P95 不够：同样是 P95=20ms，「整体偏慢」与「绝大多数 8ms、偶发 200ms」
  /// 是两个完全不同的问题，处置方向也不同，而直方图一眼能分开。
  ///
  /// 分桶按 16ms 预算的倍数切，边界落在判据上，读数时不需要换算。
  Map<String, int> histogram() {
    const List<double> bounds = [8, 16, 32, 50, 100];
    final Map<String, int> buckets = {
      '≤8ms': 0,
      '8–16ms': 0,
      '16–32ms': 0,
      '32–50ms': 0,
      '50–100ms': 0,
      '>100ms': 0,
    };
    final List<String> labels = buckets.keys.toList();
    for (final ms in _samples) {
      int i = 0;
      while (i < bounds.length && ms > bounds[i]) {
        i++;
      }
      buckets[labels[i]] = buckets[labels[i]]! + 1;
    }
    return buckets;
  }

  /// 导出为 JSON 文本（PRD:1371 要求结果可落盘）。
  ///
  /// 带 [label] 与 [pointCount] 是因为：一份脱离了「哪台机器、多少点」的
  /// P95 数字无法回填 SLA —— 而 POC-B 的产出正是要回填 SLA。
  String toJson({required String label, required int pointCount}) {
    return const JsonEncoder.withIndent('  ').convert({
      'label': label,
      'pointCount': pointCount,
      'frameBudgetMs': kFrameBudgetMs,
      'totalFrames': _totalFrames,
      'jankFrames': _totalJankFrames,
      'jankRatio': double.parse(jankRatio.toStringAsFixed(4)),
      'sampleCount': sampleCount,
      'p50Ms': double.parse(p50Ms.toStringAsFixed(2)),
      'p95Ms': double.parse(p95Ms.toStringAsFixed(2)),
      'p99Ms': double.parse(p99Ms.toStringAsFixed(2)),
      'maxMs': double.parse(maxMs.toStringAsFixed(2)),
      'histogram': histogram(),
    });
  }
}
