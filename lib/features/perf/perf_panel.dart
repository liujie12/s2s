/// POC-B 应用内指标面板（PRD §6.10.1 / :1371）。
///
/// **为什么指标要显示在应用里而不是打日志**：PRD:1371 的设计前提是「任何能装
/// APK 的安卓设备都能自行出数，无需在该设备上搭 Flutter 环境」。打日志则必须
/// 连 `adb logcat`，那台低端测试机就又被绑回开发机旁边了。
///
/// **面板自身的开销要可忽略**：它每秒只刷新一次（而非每帧），否则测量工具本身
/// 会成为掉帧来源 —— 测出来的就不是地图的性能，而是「地图 + 一个每帧重建的面板」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import '../discovery/stress_data.dart';
import 'frame_metrics.dart';

/// 全局帧采样器。
///
/// 单例而非随页面创建：`addTimingsCallback` 是全局的，随页面注册会在页面
/// 重建时重复注册；且切换压测档位时若采样器跟着重建，reset 的语义会与
/// 「换档清零」混淆，分不清数据是被主动清的还是丢的。
final frameMetricsProvider = Provider<FrameMetrics>((ref) {
  final metrics = FrameMetrics();
  ref.onDispose(metrics.stop);
  return metrics;
});

/// 性能面板。折叠时是一个小胶囊，展开后显示分位数与直方图。
class PerfPanel extends ConsumerStatefulWidget {
  const PerfPanel({super.key});

  @override
  ConsumerState<PerfPanel> createState() => _PerfPanelState();
}

class _PerfPanelState extends ConsumerState<PerfPanel> {
  bool _expanded = false;

  /// 面板每秒刷新一次，用「上次刷新时间」节流而不是起 Timer：
  /// Timer 在页面不可见时仍会触发 setState，白白产生帧，污染的正是要测的数。
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    // 采集从页面挂载即开始，不等用户点开面板 —— 冷启动后的头几十帧
    // 恰是最容易掉帧的一段，等点开再采就把它漏掉了。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(frameMetricsProvider).start();
      _scheduleRefresh();
    });
  }

  /// 每帧检查一次是否到了刷新点。到点才 setState，故实际重建约每秒一次。
  void _scheduleRefresh() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final now = DateTime.now();
      if (now.difference(_lastRefresh).inMilliseconds >= 1000) {
        _lastRefresh = now;
        setState(() {});
      }
      _scheduleRefresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    final metrics = ref.read(frameMetricsProvider);
    final level = ref.watch(stressLevelProvider);

    return Material(
      color: Colors.transparent,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: _expanded ? 232 : 96,
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          // 深色半透明：面板压在地图上，白底卡会与降级底图抢边界。
          color: Color(AppColors.textPrimary).withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(metrics),
            if (_expanded) ...[
              const SizedBox(height: AppSpacing.sm),
              _buildStats(metrics),
              const SizedBox(height: AppSpacing.sm),
              _buildHistogram(metrics),
              const SizedBox(height: AppSpacing.sm),
              _buildLevelSwitch(level, metrics),
              const SizedBox(height: AppSpacing.xs),
              _buildExportRow(metrics, level),
            ],
          ],
        ),
      ),
    );
  }

  /// 折叠态也显示 P95：这是判据本身（≤16ms），不该藏在展开层里。
  Widget _buildHeader(FrameMetrics metrics) {
    final double p95 = metrics.p95Ms;
    final bool pass = p95 <= kFrameBudgetMs && metrics.sampleCount > 0;
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pass ? Icons.check_circle : Icons.speed,
            size: 14,
            color: pass ? const Color(0xFF4ADE80) : const Color(0xFFFBBF24),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            'P95 ${p95.toStringAsFixed(1)}ms',
            style: _labelStyle(bold: true),
          ),
          const Spacer(),
          Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 14,
            color: Color(AppColors.surface),
          ),
        ],
      ),
    );
  }

  Widget _buildStats(FrameMetrics metrics) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _statLine('P50', '${metrics.p50Ms.toStringAsFixed(1)}ms'),
        _statLine('P99', '${metrics.p99Ms.toStringAsFixed(1)}ms'),
        _statLine('Max', '${metrics.maxMs.toStringAsFixed(1)}ms'),
        _statLine(
          '超 16ms',
          '${(metrics.jankRatio * 100).toStringAsFixed(1)}%'
              ' (${metrics.totalJankFrames}/${metrics.totalFrames})',
        ),
      ],
    );
  }

  /// 直方图用横条而非数字表：分布形态一眼可辨，而 POC 最需要区分的
  /// 「整体偏慢」与「偶发长帧」正是形态差异。
  Widget _buildHistogram(FrameMetrics metrics) {
    final hist = metrics.histogram();
    final int maxCount = hist.values.isEmpty
        ? 0
        : hist.values.reduce((a, b) => a > b ? a : b);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: hist.entries.map((e) {
        final double ratio = maxCount == 0 ? 0 : e.value / maxCount;
        return Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Row(
            children: [
              SizedBox(
                width: 58,
                child: Text(e.key, style: _labelStyle(size: 9)),
              ),
              Expanded(
                child: Container(
                  height: 6,
                  alignment: Alignment.centerLeft,
                  color: const Color(0x33FFFFFF),
                  child: FractionallySizedBox(
                    widthFactor: ratio,
                    child: Container(
                      // 超预算的桶用警示色：读图时不必再去对照分桶边界。
                      color: e.key.startsWith('≤') || e.key.startsWith('8–')
                          ? const Color(0xFF4ADE80)
                          : const Color(0xFFFBBF24),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 34,
                child: Text(
                  '${e.value}',
                  textAlign: TextAlign.right,
                  style: _labelStyle(size: 9),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  /// 切档位同时清零采样：不清零则新档位的数据被上一档稀释，
  /// 而两档对比正是 POC 的产出。
  Widget _buildLevelSwitch(StressLevel current, FrameMetrics metrics) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: StressLevel.values.map((level) {
        final bool selected = level == current;
        return GestureDetector(
          onTap: () {
            ref.read(stressLevelProvider.notifier).set(level);
            metrics.reset();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: selected
                  ? Color(AppColors.primary)
                  : const Color(0x33FFFFFF),
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            child: Text(level.label, style: _labelStyle(size: 10)),
          ),
        );
      }).toList(),
    );
  }

  /// 导出走剪贴板而非写文件：写外部存储在 Android 10+ 需要分区存储适配，
  /// 而 POC 只是要把一段 JSON 弄出来，剪贴板贴到微信/便签即可，零权限。
  Widget _buildExportRow(FrameMetrics metrics, StressLevel level) {
    return GestureDetector(
      onTap: () async {
        final json = metrics.toJson(
          label: level.label,
          pointCount: level == StressLevel.off ? 105 : level.pointCount,
        );
        await Clipboard.setData(ClipboardData(text: json));
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已复制 JSON 到剪贴板')));
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.copy, size: 12, color: Color(AppColors.surface)),
          const SizedBox(width: AppSpacing.xs),
          Text('复制 JSON', style: _labelStyle(size: 10)),
        ],
      ),
    );
  }

  Widget _statLine(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 1),
      child: Row(
        children: [
          SizedBox(width: 58, child: Text(label, style: _labelStyle(size: 10))),
          Text(value, style: _labelStyle(size: 10)),
        ],
      ),
    );
  }

  TextStyle _labelStyle({double size = 11, bool bold = false}) {
    return TextStyle(
      color: Color(AppColors.surface),
      fontSize: size,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      // 等宽：数字每秒跳动，非等宽字体会让整行左右抖动，读数很难受。
      fontFeatures: const [FontFeature.tabularFigures()],
    );
  }
}
