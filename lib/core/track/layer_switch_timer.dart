/// 图层切换四段独立计时器（详细设计 §17.2）。
///
/// **为什么单建一个类而非把五个 `Stopwatch` 散在页面里**：§17.2 的硬纪律是
/// 「四段各自独立 `Stopwatch`，严禁由 `duration_ms` 减出任何一段」，把计时
/// 收进一个类型，让「有没有减法」变成一眼可判、可单测直测（喂值断言
/// 四段和 == duration、且逐段来自各自 stopwatch），页面侧不再有自创计时的空间。
///
/// 五个计时器职责：
///   - `duration`：整段交互（手指离开分类 Tab → Pin 首屏绘制完成），**独立测**；
///   - `cache` / `net` / `agg` / `render`：四段各自独立，**未开始的段记 0**；
///   - 恒等式 `四段和 == duration`（容差 ±1ms）只作交叉校验，不由本类「修平」。
///
/// **取消场景**（§17.2）：请求被后续交互取代（`result=cancelled`）时，
/// [finish] 会停掉仍在跑的段，各段报「取消时刻的已耗时」，未开始的段仍记 0。
library;

/// 图层切换四段独立计时器。
class LayerSwitchTimer {
  final Stopwatch _duration = Stopwatch();
  final Stopwatch _cache = Stopwatch();
  final Stopwatch _net = Stopwatch();
  final Stopwatch _agg = Stopwatch();
  final Stopwatch _render = Stopwatch();

  bool _cacheStarted = false;
  bool _netStarted = false;
  bool _aggStarted = false;
  bool _renderStarted = false;

  /// 开始整段计时（手指离开分类 Tab 的那一刻）。
  void start() {
    _duration.start();
  }

  /// 进入「本地缓存判定」段。
  void beginCache() {
    _cacheStarted = true;
    _cache.start();
  }

  /// 结束「本地缓存判定」段。
  void endCache() => _cache.stop();

  /// 进入「`/map/pins` 网络往返」段。
  void beginNet() {
    _netStarted = true;
    _net.start();
  }

  /// 结束网络段。
  void endNet() => _net.stop();

  /// 进入「Dart 侧聚合」段。
  void beginAgg() {
    _aggStarted = true;
    _agg.start();
  }

  /// 结束聚合段。
  void endAgg() => _agg.stop();

  /// 进入「Pin 首屏绘制」段。
  void beginRender() {
    _renderStarted = true;
    _render.start();
  }

  /// 结束渲染段。
  void endRender() => _render.stop();

  /// 结束整段计时，并停掉仍在跑的段（取消场景下冻结各段为「已耗时」）。
  ///
  /// 幂等：重复调用无副作用（`Stopwatch.stop` 对已停实例是 no-op）。
  void finish() {
    _duration.stop();
    if (_cache.isRunning) _cache.stop();
    if (_net.isRunning) _net.stop();
    if (_agg.isRunning) _agg.stop();
    if (_render.isRunning) _render.stop();
  }

  /// 整段耗时（毫秒，独立测，非四段相加）。
  int get durationMs => _duration.elapsedMilliseconds;

  /// 第一段：本地缓存判定耗时（毫秒）；未开始记 0。
  int get tCacheMs => _cacheStarted ? _cache.elapsedMilliseconds : 0;

  /// 第二段：网络往返耗时（毫秒）；未开始（如缓存命中）记 0。
  int get tNetMs => _netStarted ? _net.elapsedMilliseconds : 0;

  /// 本次会话是否量过缓存段（`beginCache` 被调用过）。
  ///
  /// 供 [`LayerSwitchRecorder`] 判定「本次切换是否走过本地缓存查找」——
  /// 压测档（短路注入）不查缓存，故不与真实档混算缓存命中率（[146]）。
  bool get cacheMeasured => _cacheStarted;

  /// 本次会话是否量过网络段（`beginNet` 被调用过）。
  ///
  /// 全程命中缓存时不走网络，本值为 false —— 它与 [cacheMeasured] 合起来
  /// 即「整段命中」的判据（命中过缓存且没发网络请求）。
  bool get netMeasured => _netStarted;

  /// 第三段：聚合耗时（毫秒）；未开始（服务端预聚合）记 0。
  int get tAggMs => _aggStarted ? _agg.elapsedMilliseconds : 0;

  /// 第四段：渲染耗时（毫秒）；未开始记 0。
  int get tRenderMs => _renderStarted ? _render.elapsedMilliseconds : 0;
}
