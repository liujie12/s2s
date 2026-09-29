/// 埋点事件数据模型（详细设计 §17.1 / §17.2 / §17.4.1；契约
/// `components/schemas/TrackEvent` 与 `LayerSwitchProps`）。
///
/// 本文件只放「纯数据」，无 IO、无网络、无平台依赖 —— 便于单测直接喂值。
/// 四条硬约束在此落地为不可变字段：
///   1. **去重键三列（`interaction_id`/`ts`/`event`）入队即冻结**（§17.4.1）：
///      [TrackEvent] 全字段 `final`，上报器只读取与序列化，禁补全/重取值；
///   2. **`ts` 带毫秒精度**（去重键列 `DATETIME(3)`，§17.4.1）：
///      构造时统一截断到毫秒，序列化固定 3 位小数；
///   3. **事件名与契约枚举逐字一致**（§5.8）：线值绑定在 [TrackEventName] 自身；
///   4. **事件体 `interaction_id` 与批次头 `X-Interaction-Id` 互不覆盖**
///      （§17.4.2）：[TrackBatch] 的 `interactionId` 是批次级「传输动作」，
///      [TrackEvent.interactionId] 是事件级「用户交互」，两字段分列不互顶。
library;

/// 埋点事件名（契约 `TrackEvent.event` 的 5 值枚举，逐字对齐）。
///
/// **为什么线值绑在枚举自身而非靠 `name.toLowerCase()`**：枚举常量名是
/// 驼峰（`layerSwitch`），契约线值是下划线小写（`layer_switch`），两者不可
/// 由字符串变换可靠互推（`demandPushSent` → `demand_push_sent` 尚可，
/// 但一旦出现不规则映射就会静默错位）。线值作为唯一口径源写死在枚举里，
/// 非法值在 [TrackEventName.fromWire] 反序列化期抛错，不返 null 不静默吞。
enum TrackEventName {
  /// 图层切换（props 为 [LayerSwitchProps]，Batch1 四段计时对象）。
  layerSwitch('layer_switch'),

  /// 帖子发布。
  postPublished('post_published'),

  /// 联系事件。
  contactEvent('contact_event'),

  /// 需求推送送达（Batch2）。
  demandPushSent('demand_push_sent'),

  /// 资源详情点击（Batch2）。
  resourceDetailClick('resource_detail_click');

  const TrackEventName(this.wire);

  /// 契约线值（下划线小写，序列化出口）。
  final String wire;

  /// 由契约线值反解枚举（仅在需要解析服务端回传事件名时用）。
  ///
  /// 参数：[wire] 契约线值。
  /// 返回：[TrackEventName] 匹配项。
  /// 抛出：[ArgumentError] 线值不在 5 值白名单内。
  static TrackEventName fromWire(String wire) {
    for (final value in values) {
      if (value.wire == wire) return value;
    }
    throw ArgumentError.value(wire, 'wire', '未知埋点事件名');
  }
}

/// 图层切换结果（契约 `LayerSwitchProps.result`）。
enum LayerSwitchResult {
  /// 交互走完。
  success('success'),

  /// 交互未走完（原因见 [LayerSwitchFailReason]）。
  fail('fail');

  const LayerSwitchResult(this.wire);

  /// 契约线值。
  final String wire;
}

/// 图层切换失败原因（契约 `LayerSwitchProps.fail_reason`，仅 result=fail 时有值）。
enum LayerSwitchFailReason {
  /// 读超时。
  timeout('timeout'),

  /// 网络不可达。
  network('network'),

  /// 服务端错误。
  serverError('server_error'),

  /// 渲染失败。
  renderError('render_error'),

  /// 请求被用户后续交互取消（§15.2 / §17.2：不是失败，是用户改变意图）。
  cancelled('cancelled');

  const LayerSwitchFailReason(this.wire);

  /// 契约线值。
  final String wire;
}

/// 网络类型（契约 `LayerSwitchProps.network_type`）。
///
/// 取不到时上报 [unknown]，**不猜 `wifi`**（§5.8）—— 连上 WiFi 不等于能出
/// 公网，把 WiFi 当连通性判据会在弱网下得出错误结论。
enum TrackNetworkType {
  wifi('wifi'),
  fiveG('5g'),
  fourG('4g'),
  threeG('3g'),
  twoG('2g'),
  none('none'),
  unknown('unknown');

  const TrackNetworkType(this.wire);

  /// 契约线值。
  final String wire;
}

/// `layer_switch` 事件的 12 属性（可观测性 §4.1.1 唯一权威定义）。
///
/// **四段耗时纪律（§17.2，最容易实现错的一处）**：`t_cache_ms` / `t_net_ms` /
/// `t_agg_ms` / `t_render_ms` 四段各自独立打点，**禁止由 `duration_ms` 减出**；
/// `duration_ms` 也独立测，不是四段相加。恒等式
/// `四段和 == duration_ms`（容差 ±1ms）仅作交叉校验，超差的事件由服务端从
/// P95 分母剔除并告警（§17.2），不是本模型要「修平」的东西。
class LayerSwitchProps {
  /// 构造图层切换属性。
  ///
  /// 参数：
  ///   [durationMs] 总耗时（独立测，非四段相加）；
  ///   [tCacheMs]   缓存判定段耗时（独立计时；未开始记 0）；
  ///   [tNetMs]     网络往返段耗时（缓存命中为 0）；
  ///   [tAggMs]     Dart 侧聚合段耗时（服务端预聚合为 0）；
  ///   [tRenderMs]  渲染段耗时（独立计时，禁减法）；
  ///   [result]     交互结果（只表是否走完，不含耗时判定）；
  ///   [cacheHit]   是否命中本地 Pin 缓存（命中时 request_id 不存在）；
  ///   [failReason] result=fail 时的原因；success 时为空；
  ///   [errCode]    失败时的服务端业务 code；网络层失败时为空；
  ///   [fps]        本次交互期间平均帧率（复用 frame_metrics）；
  ///   [memPeakMb]  峰值内存（MB）；Android 平台通道采集，iOS 上报空；
  ///   [networkType] 采集时刻网络类型；取不到报 unknown。
  const LayerSwitchProps({
    required this.durationMs,
    required this.tCacheMs,
    required this.tNetMs,
    required this.tAggMs,
    required this.tRenderMs,
    required this.result,
    required this.cacheHit,
    this.failReason,
    this.errCode,
    this.fps,
    this.memPeakMb,
    this.networkType,
  });

  /// 总耗时（毫秒）。
  final int durationMs;

  /// 第一段：本地缓存判定耗时（毫秒）。
  final int tCacheMs;

  /// 第二段：`/map/pins` 网络往返耗时（毫秒）；缓存命中为 0。
  final int tNetMs;

  /// 第三段：Dart 侧聚合耗时（毫秒）；服务端预聚合为 0。
  final int tAggMs;

  /// 第四段：Pin 首屏绘制耗时（毫秒）。
  final int tRenderMs;

  /// 交互结果。
  final LayerSwitchResult result;

  /// 是否命中本地缓存。
  final bool cacheHit;

  /// 失败原因（仅 result=fail）。
  final LayerSwitchFailReason? failReason;

  /// 失败时的业务 code（可空）。
  final int? errCode;

  /// 平均帧率（可空）。
  final double? fps;

  /// 峰值内存（MB，可空；iOS 恒空）。
  final double? memPeakMb;

  /// 网络类型（可空；取不到报 unknown）。
  final TrackNetworkType? networkType;

  /// 序列化为契约 `props` 对象（snake_case，手写映射不引 json_serializable）。
  ///
  /// 可空字段仅在有值时写入键（不写 null 键），与契约 `required` 子集
  /// （`duration_ms`/四段/`result`/`cache_hit`）严格对齐。
  ///
  /// 返回：[Map<String, Object?>] 12 字段的 JSON 对象（未填充的可空字段省略）。
  Map<String, Object?> toJson() => <String, Object?>{
        'duration_ms': durationMs,
        't_cache_ms': tCacheMs,
        't_net_ms': tNetMs,
        't_agg_ms': tAggMs,
        't_render_ms': tRenderMs,
        'result': result.wire,
        'cache_hit': cacheHit,
        if (failReason != null) 'fail_reason': failReason!.wire,
        if (errCode != null) 'err_code': errCode,
        if (fps != null) 'fps': fps,
        if (memPeakMb != null) 'mem_peak_mb': memPeakMb,
        if (networkType != null) 'network_type': networkType!.wire,
      };
}

/// 单条埋点事件（契约 `TrackEvent`）。
///
/// 全字段 `final`、不可变 —— 「入队即冻结」在类型层面强制（§17.4.1）：
/// 上报器拿到实例后只能读，改不了去重键三列。
class TrackEvent {
  /// 构造埋点事件。
  ///
  /// 参数：
  ///   [event]         事件名（线值见 [TrackEventName.wire]）；
  ///   [ts]            客户端采集时刻（**不是上报时刻**）；构造时截断到毫秒，
  ///                   因去重键列是 `DATETIME(3)`，只到秒会误丢同秒内多次同名事件；
  ///   [interactionId] 该事件所属用户交互的 `X-Interaction-Id`（采集时写入，
  ///                   与批次头互不覆盖）；
  ///   [requestId]     服务端请求标识；缓存命中时为 null 属预期；
  ///   [props]         事件属性对象（layer_switch 用 [LayerSwitchProps.toJson]）。
  TrackEvent({
    required this.event,
    required DateTime ts,
    required this.interactionId,
    this.requestId,
    this.props,
  }) : ts = _truncateToMs(ts);

  /// 事件名。
  final TrackEventName event;

  /// 采集时刻（毫秒精度，去重键成员）。
  final DateTime ts;

  /// 事件所属交互标识（去重键成员，与批次头互不覆盖）。
  final String interactionId;

  /// 服务端请求标识（可空）。
  final String? requestId;

  /// 事件属性对象（可空；已序列化的 JSON 对象）。
  final Map<String, Object?>? props;

  /// 由 JSON 对象重建（本地队列落盘回读用，非服务端响应解析）。
  ///
  /// 与服务端响应不同，本路径的数据是自己写入的本地 JSON Lines，故不去走
  /// `contract_json.dart` 的 [ApiException.parse]（那是契约违约语义）；此处
  /// 单行损坏属本地文件异常，抛 [FormatException]，由 [TrackQueue] 的加载器
  /// 逐行捕获跳过，不让一条坏行拖垮冷启动。
  ///
  /// `ts` 经构造器统一截断回毫秒精度（§17.4.1），确保去重键成员与写入前逐字一致。
  ///
  /// 参数：[json] 已解码的 JSON 对象（`event`/`ts`/`interaction_id` 必填）。
  /// 返回：[TrackEvent] 重建实例。
  /// 抛出：[FormatException] 字段缺失或类型不符时。
  factory TrackEvent.fromJson(Map<String, Object?> json) {
    final eventWire = json['event'];
    if (eventWire is! String) {
      throw const FormatException('TrackEvent.event 缺失或非 String');
    }
    final event = TrackEventName.fromWire(eventWire);
    final tsRaw = json['ts'];
    if (tsRaw is! String) {
      throw const FormatException('TrackEvent.ts 缺失或非 String');
    }
    final ts = DateTime.tryParse(tsRaw);
    if (ts == null) {
      throw FormatException('TrackEvent.ts 非 ISO-8601: $tsRaw');
    }
    final interactionId = json['interaction_id'];
    if (interactionId is! String) {
      throw const FormatException('TrackEvent.interaction_id 缺失或非 String');
    }
    final requestId = json['request_id'];
    final props = json['props'];
    return TrackEvent(
      event: event,
      ts: ts,
      interactionId: interactionId,
      requestId: requestId is String ? requestId : null,
      props: props is Map ? props.cast<String, Object?>() : null,
    );
  }

  /// 序列化为契约 `events[]` 元素（snake_case）。
  ///
  /// `ts` 固定 3 位小数毫秒（§17.4.1）；`request_id`/`props` 仅在有值时写键。
  ///
  /// 返回：[Map<String, Object?>] 契约字段对象。
  Map<String, Object?> toJson() => <String, Object?>{
        'event': event.wire,
        'ts': formatIso8601Ms(ts),
        'interaction_id': interactionId,
        if (requestId != null) 'request_id': requestId,
        if (props != null) 'props': props,
      };
}

/// 一个上报批次（§17.4.1 / §17.4.2）。
///
/// [idempotencyKey] 与 [interactionId] 是**批次级**传输标识，不进请求体、
/// 走 HTTP 头 —— [TrackReporter.buildBatch] 每次组批都换新（幂等保全的唯一
/// 例外），语义是「一次传输动作」而非「一笔业务意图」。
class TrackBatch {
  /// 构造上报批次。
  ///
  /// 参数：
  ///   [idempotencyKey] 本批幂等键（每次组批新生成）；
  ///   [interactionId]  本批 `X-Interaction-Id`（每次组批新生成，传输动作语义）；
  ///   [events]         本批事件（条数上限 [NfrApi.trackBatchMaxEvents]）；
  ///   [droppedCount]   自上次成功上报以来因容量溢出丢弃的条数。
  const TrackBatch({
    required this.idempotencyKey,
    required this.interactionId,
    required this.events,
    required this.droppedCount,
  });

  /// 本批幂等键。
  final String idempotencyKey;

  /// 本批 `X-Interaction-Id`（批次级传输标识）。
  final String interactionId;

  /// 本批事件。
  final List<TrackEvent> events;

  /// 队列溢出丢弃计数（随本批上报，放信封元数据，不占事件条目）。
  final int droppedCount;

  /// 序列化为 `POST /track/events` 请求体（snake_case）。
  ///
  /// 幂等键与批次交互 ID 走 HTTP 头、不进体（§17.4.2）；体只含 `events` 与
  /// `dropped_count`。
  ///
  /// 返回：[Map<String, Object?>] 请求体对象。
  Map<String, Object?> toJson() => <String, Object?>{
        'events': <Object?>[for (final e in events) e.toJson()],
        'dropped_count': droppedCount,
      };
}

/// 把时刻截断到毫秒精度（去重键列 `DATETIME(3)` 要求，§17.4.1）。
///
/// Dart 的 `DateTime` 微秒精度若原样序列化，服务端 `DATETIME(3)` 会截掉
/// 微秒位，重传时同微秒值被二次截断可能产生不一致；统一在采集侧截到毫秒，
/// 让「采集时刻」这一去重键成员在重传时逐字稳定。
///
/// 参数：[time] 待截断时刻。
/// 返回：[DateTime] 毫秒精度（UTC）。
DateTime _truncateToMs(DateTime time) =>
    DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch, isUtc: true);

/// 序列化时刻为 ISO-8601 带固定 3 位毫秒（契约 `ts` 要求，§17.4.1）。
///
/// **为什么手写而非用 `toIso8601String()`**：后者在微秒为 0 时省略毫秒
/// （`2026-09-29T10:00:00Z` 而非 `...00.000Z`），且微秒非 0 时会带 6 位
/// 小数 —— 两种形态都会让 `DATETIME(3)` 解析结果漂移。固定 3 位让重传的
/// `ts` 逐字稳定。
///
/// 参数：[time] 毫秒精度时刻（UTC）。
/// 返回：[String] 形如 `2026-09-29T10:00:00.000Z`。
String formatIso8601Ms(DateTime time) {
  final t = time.toUtc();
  String pad(int v, int width) => v.toString().padLeft(width, '0');
  return '${t.year.toString().padLeft(4, '0')}-${pad(t.month, 2)}-${pad(t.day, 2)}'
      'T${pad(t.hour, 2)}:${pad(t.minute, 2)}:${pad(t.second, 2)}'
      '.${pad(t.millisecond, 3)}Z';
}
