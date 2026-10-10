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
import '../../nfr_constants.dart';
import '../discovery/stress_data.dart';
import 'frame_metrics.dart';
import 'layer_switch_recorder.dart';

/// 达标色（绿）：帧 P95 ≤16ms 与图层切换 P95 ≤300ms 共用。
const Color _kPassColor = Color(0xFF4ADE80);

/// 未达标 / 无数据色（琥珀）。
const Color _kWarnColor = Color(0xFFFBBF24);

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

  /// 档位行是否已解锁。默认 false：见 [_onHeaderTap] 的理由。
  bool _stressUnlocked = false;

  /// 标题累计连点次数（用于解锁档位行）。
  int _headerTaps = 0;

  /// 连点标题解锁档位行所需的次数。
  ///
  /// 取 Android「开发者选项」同款惯例（连点版本号 7 次）：既不会被误触撞到，
  /// 又是个有据可循的约定，不需要自创一套隐藏手势。
  static const int _kStressUnlockTaps = 7;

  /// 标题点击：展开 / 收起，并累计连点次数以解锁档位行。
  ///
  /// **为什么档位行要加锁**：档位切换会把地图换上 1 万 / 5 万条**假数据**。内测包里
  /// 若一点即生效，用户误触后看到的是「地图上凭空多出一堆点」，而这种假象不会报错、
  /// 只会被当成真实缺陷上报（表现为「数据错了」，而非「我误触了压测开关」）。
  /// 故档位行默认不渲染，须连点标题解锁；埋点与面板本身仍常驻（PRD:1371 要求
  /// 与上线埋点为同一套代码，不得为交付而删）。
  void _onHeaderTap() {
    setState(() {
      _expanded = !_expanded;
      if (!_stressUnlocked && ++_headerTaps >= _kStressUnlockTaps) {
        _stressUnlocked = true;
      }
    });
  }

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
    final switches = ref.read(layerSwitchRecorderProvider);
    final level = ref.watch(stressLevelProvider);

    return Material(
      color: Colors.transparent,
      // 折叠态不锁宽度，由内容撑开（过渡交给 AnimatedSize）。
      //
      // 【为什么不把 96 调大】胶囊内容是「图标 + P95 读数 + 展开箭头」，读数宽度随
      // 数值变化（"P95 9.9ms" 与 "P95 145.7ms" 相差约 10px），字体度量又随设备与
      // 系统字体变。锁死宽度必然在某个读数上溢出 —— 2026-09-29 真机实测折叠态溢出
      // 5.3px（读数 "P95 45.7ms" 时固定项 85.3px > 可用 80px = 96 − 2×8）。把 96
      // 调大只是把溢出推给下一个更长的读数，故改为内容驱动。
      //
      // 也不能给 AnimatedContainer 直接置 width: null：其隐式 Tween 在「定值 → null」
      // 过渡时会把 end 置空并插值到 0，胶囊会先缩到不可见再复原，故改用 AnimatedSize。
      child: AnimatedSize(
        duration: const Duration(milliseconds: 160),
        // 面板锚在右下角，故以右下为缩放锚点，展开/收起时视觉不跳动。
        alignment: Alignment.bottomRight,
        child: Container(
          width: _expanded ? 232 : null,
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
                // 图层切换读数（[140]）：轴② 判据 A 的唯一应用内出口。
                _buildLayerSwitch(switches, level),
                const SizedBox(height: AppSpacing.sm),
                // 档位行默认不渲染（防用户误触换上假数据）：见 _onHeaderTap。
                if (_stressUnlocked) ...[
                  _buildLevelSwitch(level, metrics, switches),
                  const SizedBox(height: AppSpacing.xs),
                ],
                _buildExportRow(metrics, level),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 折叠态也显示 P95：这是判据本身（≤16ms），不该藏在展开层里。
  Widget _buildHeader(FrameMetrics metrics) {
    final double p95 = metrics.p95Ms;
    final bool pass = p95 <= kFrameBudgetMs && metrics.sampleCount > 0;
    return GestureDetector(
      onTap: _onHeaderTap,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            pass ? Icons.check_circle : Icons.speed,
            size: 14,
            color: pass ? _kPassColor : _kWarnColor,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            'P95 ${p95.toStringAsFixed(1)}ms',
            style: _labelStyle(bold: true),
          ),
          // Spacer 只在展开态用：那时宽度被锁在 232px，有富余空间可把箭头推到右边缘。
          // 折叠态由内容撑开，Spacer 会去占满「可用最大宽」（Positioned 给的是整屏宽），
          // 把胶囊拉成横跨屏幕的横幅，故折叠态只留一个固定间距。
          if (_expanded) const Spacer() else const SizedBox(width: AppSpacing.xs),
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
        // UI / 光栅分解：定位瓶颈用 —— 整帧高而「光栅」高说明贵在光栅化/合成，
        // 此时优化 Dart 侧无效；反之才是 Dart 侧的问题。
        _statLine('UI P50', '${metrics.buildP50Ms.toStringAsFixed(1)}ms'),
        _statLine('光栅 P50', '${metrics.rasterP50Ms.toStringAsFixed(1)}ms'),
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
                          ? _kPassColor
                          : _kWarnColor,
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
  /// 而两档对比正是 POC 的产出。帧与图层切换两套样本一起清 —— 两者都是
  /// 「同一档位下的读数」，混档会让两档的对照失效。
  Widget _buildLevelSwitch(
    StressLevel current,
    FrameMetrics metrics,
    LayerSwitchRecorder switches,
  ) {
    return Wrap(
      spacing: AppSpacing.xs,
      runSpacing: AppSpacing.xs,
      children: StressLevel.values.map((level) {
        final bool selected = level == current;
        return GestureDetector(
          onTap: () {
            ref.read(stressLevelProvider.notifier).set(level);
            metrics.reset();
            switches.reset();
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

  /// 一行「状态图标 + 标签 + 粗体读数」。
  ///
  /// 参数：
  /// - [pass]：是否达标（决定图标与颜色）；
  /// - [label]：左列标签；
  /// - [value]：读数（粗体）。
  ///
  /// 返回：[Widget] 一行的部件。
  Widget _metricRow({
    required bool pass,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(
          pass ? Icons.check_circle : Icons.swap_horiz,
          size: 12,
          color: pass ? _kPassColor : _kWarnColor,
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(label, style: _labelStyle(size: 10)),
        const SizedBox(width: AppSpacing.xs),
        Text(value, style: _labelStyle(size: 10, bold: true)),
      ],
    );
  }

  /// 图层切换读数（[140]）。
  ///
  /// **判据在前、SLA 与分解在后**：
  /// - `轴② 占比` 是**台阶判定依据**（`duration_ms ≤300 且 success` 的会话占比，
  ///   阶段目标 ≥`NorthStar.layerLoadTargetByPhase`）—— 这是北极星那条线；
  /// - `切换 P95` 是**工程 SLA**（≤`NfrPerf.layerSwitchP95Ms`），两者 2026-09-02
  ///   已定案拆开，不可用其一推另一（P95 达标要求 ≥95% 会话达标，比占比严得多）；
  /// - `缓/网/聚/绘` 是四段分解（诊断用：这四段的优化手段完全不同）；
  /// - `切换样本` 的 成/取/败 必须可见 —— 否则「占比很漂亮」可能只是样本被排除光了。
  ///
  /// 参数：
  /// - [switches]：图层切换记录器；
  /// - [level]：当前压测档位 —— 非「关闭」档时须标注「轴② 无区分度」
  ///   （压测档走 `pinsProvider` 短路注入、网络段恒 0，占比恒 ≈100%，
  ///   2026-10-09 裁定 B′）。
  Widget _buildLayerSwitch(LayerSwitchRecorder switches, StressLevel level) {
    final bool hasData = switches.successCount > 0;
    final double p95 = switches.p95Ms;
    // 轴② 阶段目标取**当前批次档**。本键随 §0.2.2 台阶推进而更换，故从真源
    // map 取值、不写死 0.6；批次推进时这里与产品目标一起改。
    final double axis2Target = NorthStar.layerLoadTargetByPhase['batch1']!;
    final double axis2 = switches.layerLoadSuccessRatio;
    final bool axis2Pass = hasData && axis2 >= axis2Target;
    final bool p95Pass = hasData && p95 <= NfrPerf.layerSwitchP95Ms;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('图层切换', style: _labelStyle(size: 9)),
        _metricRow(
          pass: axis2Pass,
          label: '轴② 占比',
          value: hasData
              ? '${(axis2 * 100).toStringAsFixed(0)}% '
                  '(${switches.layerLoadSuccessCount}/${switches.successCount})'
              : '—',
        ),
        // 压测档（500 点 / 1 万 / 5 万）走短路注入、网络段恒 0，故占比恒 ≈100%：
        // 该读数**不具区分度**，不能当闸门（2026-10-09 裁定 B′）。保留读数但
        // 必须在面板上标注，否则后人会把 100% 误读成「该档达标」。
        if (level != StressLevel.off)
          Padding(
            padding: const EdgeInsets.only(left: AppSpacing.md, bottom: 1),
            child: Text(
              '压测档 · 网络段=0，轴②无区分度',
              style: _labelStyle(
                size: 9,
              ).copyWith(color: Color(AppColors.surface).withValues(alpha: 0.6)),
            ),
          ),
        _metricRow(
          pass: p95Pass,
          label: '切换 P95',
          value: hasData ? '${p95.toStringAsFixed(1)}ms' : '—',
        ),
        // 「缓存」段自 [146] 起已接线（pins 路径接了本地 Pin 缓存）。⚠ 缓存查找是
        // 内存命中，整数 ms 下常读作 0；故「缓存是否在起作用」以 命中/查过 计数出数，
        // 不靠 ms 读数区分。查过=0 说明本档未查缓存（压测档短路注入），记「—」。
        _statLine(
          '缓/网/聚/绘',
          hasData
              ? '${switches.cacheP95Ms.toStringAsFixed(0)}/'
                  '${switches.netP95Ms.toStringAsFixed(0)}/'
                  '${switches.aggP95Ms.toStringAsFixed(0)}/'
                  '${switches.renderP95Ms.toStringAsFixed(0)} ms'
              : '—',
        ),
        _statLine(
          '缓存命中',
          switches.cacheConsultedCount == 0
              ? '—'
              : '${switches.cacheHitCount}/${switches.cacheConsultedCount}',
        ),
        _statLine(
          '切换样本',
          '${switches.successCount} 成/'
          '${switches.cancelledCount} 取/'
          '${switches.failedCount} 败',
        ),
      ],
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
