/// 埋点本地持久化队列（详细设计 §17.4；可观测 §4.6）。
///
/// **为什么落盘而非只存内存**（§17.4「介质」）：被杀死/崩溃/强退时未上报
/// 事件必须还在，否则「登录后补报」「离线积压恢复联网回灌」两条路径等于从未
/// 存在。故采用**追加写文件（JSON Lines）**：追加 O(1)，出队/成功上报后从头
/// 截断，避开 `shared_preferences` 的「全量重写 O(n²)」写放大（§10.2.1）。
///
/// **内存列表是唯一权威态，文件只是耐久层**：`enqueue` 追加一行（O(1)），
/// 溢出「丢最旧」只改内存（`dropped_count+1`）；文件里那条被丢的旧行在下次
/// `acknowledge` 触发整体重写时自然消去。这样热路径（逐条入队）恒 O(1)，
/// 只有「成功上报」这个低频动作才 O(n) 重写。
///
/// **去重键三列冻结**（§17.4.1）：[TrackEvent] 全字段不可变，本队列只存引用、
/// 不做任何字段加工；重传时 `interaction_id`/`ts`/`event` 逐字不变。
library;

import 'dart:convert';
import 'dart:io';

import '../../nfr_constants.dart';
import 'track_event.dart';

/// 埋点本地持久化队列。
class TrackQueue {
  /// 构造队列（不加载文件；生产经 [TrackQueue.open] 恢复持久化事件）。
  ///
  /// 参数：
  ///   [file]     队列文件（JSON Lines，每行一条事件）；
  ///   [capacity] 容量上限（默认引 [NfrTrack.trackQueueCapacity]，不复制字面量）。
  TrackQueue({required File file, this.capacity = NfrTrack.trackQueueCapacity})
      : _file = file;

  /// 队列文件。
  final File _file;

  /// 容量上限（超出丢最旧）。
  final int capacity;

  /// 内存权威态（FIFO：头是最旧待上报、尾是最新入队）。
  final List<TrackEvent> _events = <TrackEvent>[];

  /// 自上次成功上报以来因容量溢出丢弃的条数（随下批上报，放批次信封元数据）。
  int _droppedCount = 0;

  /// 打开队列并从文件恢复（冷启动/崩溃后回读未上报事件）。
  ///
  /// 参数：
  ///   [file]     队列文件；
  ///   [capacity] 容量上限。
  /// 返回：[Future<TrackQueue>] 已加载的队列；文件不存在时为空队列。
  static Future<TrackQueue> open(
    File file, {
    int capacity = NfrTrack.trackQueueCapacity,
  }) async {
    final queue = TrackQueue(file: file, capacity: capacity);
    await queue._load();
    return queue;
  }

  /// 队列内待上报事件数。
  int get length => _events.length;

  /// 是否为空。
  bool get isEmpty => _events.isEmpty;

  /// 入队一条事件并追加落盘。
  ///
  /// 溢出时丢最旧（内存 `removeAt(0)`）并 `dropped_count+1`；被丢的旧行残留在
  /// 文件头，待下次 [acknowledge] 重写时消去（见文件头「内存是唯一权威态」）。
  ///
  /// 参数：[event] 待入队事件（去重键三列已冻结，本方法不改动）。
  /// 返回：[Future<void>] 追加写完成后返回。
  Future<void> enqueue(TrackEvent event) async {
    _events.add(event);
    await _appendLine(jsonEncode(event.toJson()));
    if (_events.length > capacity) {
      _events.removeAt(0);
      _droppedCount++;
    }
  }

  /// 窥视队首至多 [count] 条事件（**不移除**）。
  ///
  /// 上报器据此组批；成功后才调 [acknowledge] 移除，失败则不调、事件仍留在
  /// 队首（「失败退回队首」由「不移除」天然满足，无需反向重插）。
  ///
  /// 参数：[count] 最多取几条（调用方按 [NfrApi.trackBatchMaxEvents] 传）。
  /// 返回：[List<TrackEvent>] 队首快照（与队列内部同一批实例引用）。
  List<TrackEvent> peek(int count) =>
      _events.take(count).toList(growable: false);

  /// 上报成功后移除 [batch] 中的事件并重写文件（从头截断）。
  ///
  /// 按**实例身份**匹配而非按位置：若上报在途期间发生溢出，批内被丢的旧事件
  /// 已不在队列中（`removeWhere` 自然跳过），不会误删「溢出时新补入、尚未上报」
  /// 的队尾事件 —— 位置式 `removeRange(0, n)` 在溢出-在途并发下会错删。
  ///
  /// 参数：[batch] 已成功上报的事件（来自 [peek] 的同一批实例）。
  /// 返回：[Future<void>] 重写完成后返回。
  Future<void> acknowledge(List<TrackEvent> batch) async {
    if (batch.isEmpty) return;
    final done = batch.toSet();
    _events.removeWhere(done.contains);
    await _rewrite();
  }

  /// 当前溢出丢弃计数（**只读**，不重置；组批时随批次信封上报）。
  ///
  /// 重置走 [takeDroppedCount]，仅在「含该计数的批次成功上报」后调用，
  /// 保证失败批次不会把未上报的丢弃计数凭空清零。
  int get droppedCount => _droppedCount;

  /// 取出并清零溢出丢弃计数（成功上报后调用）。
  ///
  /// 返回：[int] 自上次上报以来的丢弃条数。
  int takeDroppedCount() {
    final count = _droppedCount;
    _droppedCount = 0;
    return count;
  }

  /// 从文件加载全部事件到内存，并裁剪超容部分。
  ///
  /// 单行损坏（如写入中途断电的半行）抛 [FormatException]，逐行捕获跳过，
  /// 不让一条坏行拖垮冷启动 —— 埋点数据宁可少一条坏行，不可让 App 起不来。
  Future<void> _load() async {
    if (!await _file.exists()) return;
    final lines = await _file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is Map) {
          _events.add(TrackEvent.fromJson(decoded.cast<String, Object?>()));
        }
      } on Object {
        // 坏行跳过（含 FormatException/类型错/未知事件名），见方法注释。
      }
    }
    // 回读的文件可能因「溢出后未及重写」带超容行，此处按同一口径丢最旧并计数。
    while (_events.length > capacity) {
      _events.removeAt(0);
      _droppedCount++;
    }
  }

  /// 追加一行到文件尾（O(1) 热路径）。
  Future<void> _appendLine(String line) async {
    await _file.writeAsString('$line\n', mode: FileMode.append);
  }

  /// 用内存权威态整体重写文件（成功上报后从头截断的唯一落点）。
  Future<void> _rewrite() async {
    if (_events.isEmpty) {
      await _file.writeAsString('');
      return;
    }
    final content =
        _events.map((e) => jsonEncode(e.toJson())).join('\n');
    await _file.writeAsString('$content\n');
  }
}
