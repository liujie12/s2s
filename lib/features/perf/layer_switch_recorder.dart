/// 图层切换耗时采集（[140]：POC-B 判据 A「图层切换 P95 ≤300ms」的数据来源）。
///
/// **为什么需要本文件**：`core/track/layer_switch_timer.dart` 只提供「四段各自
/// 独立 `Stopwatch`」这一层，本身不持有会话、不做跨层聚合。而一次图层切换横跨
/// 三个互不相邻的位置：
///
/// ```
/// 筛选面板（分类胶囊 onTap，手指离开）        ← 起点
///   ↓ 筛选态变化 → pinsProvider 重取
/// pinsProvider（/map/pins 网络往返）          ← 网络段
///   ↓ 数据到达 → 地图重建
/// map_screen（投影 + 网格聚合 + 建 Marker）   ← 聚合段
///   ↓ 同一帧布局
/// MarkerLayer 首屏绘制完成                    ← 渲染段 + 整段收尾
/// ```
///
/// 三处分别属于 `features/discovery`、`features/map`，谁也不能持有对方的状态，
/// 故把「当前会话 + 已完成样本」收在本文件的单例里，三处只往这里打点。
///
/// **口径以 PRD §6.10 / 详设 §17.2 为准**：
///   - 计时起点 = 手指离开分类 Tab（= 胶囊 `onTap` 触发那一刻）；
///   - 计时终点 = 该分类的 Pin 在地图上完成首屏绘制；
///   - `duration_ms` **独立测**，不是四段相加；四段各自独立，**任何一段都不得
///     由 `duration_ms` 减出**（[LayerSwitchTimer] 已按此实现并有单测锁定）。
///
/// **本文件不做的三件事**（[140] 范围外，已登记缺口）：
///   1. **不上报** `layer_switch` 12 字段（组装 `LayerSwitchProps` 入队走
///      `features/track/`）—— 那还要接 `interaction_id` 透传、`network_type`
///      与 `mem_peak_mb` 平台通道；
///   2. **不测缓存段**：pins 路径当前无本地缓存（`core/cache/pin_cache.dart`
///      无调用方），故 `tCacheMs` 恒为 0（§17.2「未命中/无缓存则为 0」）；
///   3. **不做四段恒等式校验**：`abs(四段和 - duration) ≤1ms` 是**埋点数据质量**
///      校验（§17.2），而本采集的段与段之间存在真实间隙（provider 派发、
///      Riverpod 通知、帧调度），恒等式在此不成立也无意义；待上报任务在
///      管线侧执行。
library;

import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/track/layer_switch_timer.dart';

/// 一次图层切换的收尾方式。
///
/// 与契约 `LayerSwitchProps` 的 `result` / `fail_reason` 是**映射**关系而非同一
/// 枚举：`success` → (`success`, 空)；`cancelled` → (`fail`, `cancelled`)；
/// `failed` → (`fail`, `timeout`/`network`/`server_error`，需在失败点区分）。
/// 本文件只区分「进不进 P95 分母」，更细的失败原因留给上报任务。
enum LayerSwitchOutcome {
  /// 走完：新分类的 Pin 已完成首屏绘制。
  success,

  /// 被用户的后续切换取代（§17.2 `cancelled`）：**不是失败**，是用户改变意图。
  cancelled,

  /// 数据没回来（网络/服务端错误）：本次切换未走完。
  failed,
}

/// 一次图层切换的实测记录。
class LayerSwitchSample {
  /// 构造样本。
  ///
  /// 参数：
  /// - [durationMs]：整段耗时（独立测，非四段之和）；
  /// - [tCacheMs]：缓存段耗时；无缓存时恒 0；
  /// - [tNetMs]：`/map/pins` 往返；压测档位短路/缓存命中为 0；
  /// - [tAggMs]：Dart 侧聚合；
  /// - [tRenderMs]：Pin 首屏绘制；
  /// - [outcome]：收尾方式。
  const LayerSwitchSample({
    required this.durationMs,
    required this.tCacheMs,
    required this.tNetMs,
    required this.tAggMs,
    required this.tRenderMs,
    required this.outcome,
  });

  /// 整段耗时（毫秒）。
  final int durationMs;

  /// 缓存段耗时（毫秒）。
  final int tCacheMs;

  /// 网络段耗时（毫秒）。
  final int tNetMs;

  /// 聚合段耗时（毫秒）。
  final int tAggMs;

  /// 渲染段耗时（毫秒）。
  final int tRenderMs;

  /// 收尾方式。
  final LayerSwitchOutcome outcome;
}

/// 图层切换耗时会话记录器。
///
/// 生命周期：`start()` 开新会话 → 各层按需打点 → `finish()` 收尾落样本。
/// 任意一步在没有活跃会话时都是**无操作**，故调用方无需自己判断「这次数据
/// 变化是不是由图层切换引起的」（拖动导致的视口重取就不会被计入）。
class LayerSwitchRecorder {
  /// 构造记录器。
  ///
  /// 参数：[capacity] 保留的最近样本数。有上限而非无限累积：POC 会连续切换
  /// 几百次，无上限则内存随时间线性增长，而内存峰值本身是 POC-B 的观测项
  /// （PRD §6.10.1），不该被采集器自己污染。
  LayerSwitchRecorder({this.capacity = 200});

  /// 保留的最近样本数。
  final int capacity;

  final Queue<LayerSwitchSample> _samples = Queue<LayerSwitchSample>();

  LayerSwitchTimer? _timer;

  /// 会话序号（自增，只用于「收尾回调是否属于当前会话」的校验）。
  int _seq = 0;

  int? _activeId;

  /// 本会话是否已量过聚合段（拖动中每帧都会重算，只有第一次属于本次切换）。
  bool _aggMeasured = false;

  /// 本会话是否已开始量渲染段（防同一会话重复调度收尾）。
  bool _renderScheduled = false;

  /// 是否有正在进行的会话。
  bool get hasActiveSession => _timer != null;

  /// 当前会话 id；无会话时为 null。
  ///
  /// 供渲染收尾回调在跨帧后校验：若期间用户又切了分类，该 id 已不是当前会话，
  /// 收尾必须作废 —— 否则会把上一次的耗时记到新会话头上。
  int? get activeSessionId => _activeId;

  /// 开一次新会话（分类胶囊被点击 = 手指离开分类 Tab 的那一刻）。
  ///
  /// 若上一会话仍未收尾，说明用户快速连续切换，**前者被取代**：按 §17.2 记为
  /// [`LayerSwitchOutcome.cancelled`]（计入样本计数、但不进 P95 分母）。
  void start() {
    if (_timer != null) _close(LayerSwitchOutcome.cancelled);
    _activeId = ++_seq;
    _timer = LayerSwitchTimer()..start();
    _aggMeasured = false;
    _renderScheduled = false;
  }

  /// 进入网络段（`/map/pins` 往返）。无活跃会话时无操作。
  void beginNet() => _timer?.beginNet();

  /// 结束网络段。无活跃会话时无操作。
  void endNet() => _timer?.endNet();

  /// 进入聚合段。**同一会话只生效一次**（拖动中每帧重算不算本次切换）。
  void beginAgg() {
    if (_timer == null || _aggMeasured) return;
    _timer!.beginAgg();
  }

  /// 结束聚合段。未开始或已量过时无操作。
  void endAgg() {
    if (_timer == null || _aggMeasured) return;
    _timer!.endAgg();
    _aggMeasured = true;
  }

  /// 进入渲染段（新数据首次上屏那一帧的 build）。同一会话只生效一次。
  void markRenderStart() {
    if (_timer == null || _renderScheduled) return;
    _timer!.beginRender();
    _renderScheduled = true;
  }

  /// 收尾：结束仍在跑的段，并把本次会话落成样本。
  ///
  /// **仅当 [sessionId] 仍是当前会话时生效**（否则说明该收尾属于已被取代的旧
  /// 会话，必须丢弃）。
  ///
  /// 参数：
  /// - [sessionId]：调度收尾时读到的会话 id（见 [activeSessionId]）；
  /// - [outcome]：收尾方式。
  void finish({
    required int sessionId,
    required LayerSwitchOutcome outcome,
  }) {
    if (_activeId != sessionId) return;
    if (_renderScheduled) _timer?.endRender();
    _close(outcome);
  }

  /// 清空样本并放弃进行中的会话（切换压测档位时调用）。
  ///
  /// 放弃而非收尾：档位变了，进行中那一笔的耗时属于旧档位，混进新档位的样本集
  /// 正是「两档对比」要避免的污染。
  void reset() {
    _samples.clear();
    _timer = null;
    _activeId = null;
    _aggMeasured = false;
    _renderScheduled = false;
  }

  /// 样本总数（含 success / cancelled / failed）。
  int get sampleCount => _samples.length;

  /// success 样本数（P95 的分母）。
  int get successCount => _countOf(LayerSwitchOutcome.success);

  /// cancelled 样本数（被后续切换取代，不计入 P95 分母）。
  int get cancelledCount => _countOf(LayerSwitchOutcome.cancelled);

  /// failed 样本数（数据没回来，不计入 P95 分母）。
  int get failedCount => _countOf(LayerSwitchOutcome.failed);

  /// 整段耗时的 P95（毫秒），**只统计 success 会话**。
  ///
  /// 判据 A 的分母口径（可观测性 §6.1）：`cancelled` 是用户改变意图、`failed`
  /// 是交互没走完，两者都不进 P95 分母。无样本时返回 0。
  double get p95Ms => _p95(_success.map((s) => s.durationMs).toList());

  /// 缓存段 P95（毫秒）。无缓存实现时恒为 0。
  double get cacheP95Ms => _p95(_success.map((s) => s.tCacheMs).toList());

  /// 网络段 P95（毫秒）。
  double get netP95Ms => _p95(_success.map((s) => s.tNetMs).toList());

  /// 聚合段 P95（毫秒）。
  double get aggP95Ms => _p95(_success.map((s) => s.tAggMs).toList());

  /// 渲染段 P95（毫秒）。
  double get renderP95Ms => _p95(_success.map((s) => s.tRenderMs).toList());

  /// success 样本序列。
  Iterable<LayerSwitchSample> get _success =>
      _samples.where((s) => s.outcome == LayerSwitchOutcome.success);

  /// 统计某一收尾方式的样本数。
  ///
  /// 参数：[outcome] 收尾方式。
  /// 返回：该方式的样本条数。
  int _countOf(LayerSwitchOutcome outcome) =>
      _samples.where((s) => s.outcome == outcome).length;

  /// 落一条样本，并按 [capacity] 淘汰最旧。
  ///
  /// 参数：[sample] 已完成的一次切换。
  void _push(LayerSwitchSample sample) {
    _samples.addLast(sample);
    if (_samples.length > capacity) _samples.removeFirst();
  }

  /// 结束当前会话并落样本（幂等：无会话时无操作）。
  ///
  /// 参数：[outcome] 收尾方式。
  void _close(LayerSwitchOutcome outcome) {
    final timer = _timer;
    if (timer != null) {
      // 停掉仍在跑的段（取消场景冻结为「取消时刻的已耗时」，见 LayerSwitchTimer）。
      timer.finish();
      _push(
        LayerSwitchSample(
          durationMs: timer.durationMs,
          tCacheMs: timer.tCacheMs,
          tNetMs: timer.tNetMs,
          tAggMs: timer.tAggMs,
          tRenderMs: timer.tRenderMs,
          outcome: outcome,
        ),
      );
    }
    _timer = null;
    _activeId = null;
    _aggMeasured = false;
    _renderScheduled = false;
  }

  /// 最近秩法 P95（与 `FrameMetrics` 同一口径，保证两个面板读数的算法一致）。
  ///
  /// 用 ceil 而非 round、不做插值：POC 要的是量级判断，算法一致比精度重要 ——
  /// 不同工具算出对不上的数字会徒增解释成本。
  ///
  /// 参数：[values] 样本（毫秒）。
  /// 返回：P95 值；空样本返回 0。
  static double _p95(List<int> values) {
    if (values.isEmpty) return 0;
    values.sort();
    final int rank = (0.95 * values.length).ceil();
    return values[rank.clamp(1, values.length) - 1].toDouble();
  }
}

/// 图层切换耗时记录器（全局单例）。
///
/// **必须单例**：一次切换横跨筛选面板 / 数据 Provider / 地图三层，任何一层自建
/// 实例都拿不到同一次会话。同理不能 `autoDispose` —— 随监听者销毁会把进行中的
/// 会话丢掉。
final layerSwitchRecorderProvider = Provider<LayerSwitchRecorder>(
  (ref) => LayerSwitchRecorder(),
);
