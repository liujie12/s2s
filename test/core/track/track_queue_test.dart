/// 埋点持久化队列单测（[130]；§7.2 埋点组 / 详细设计 §17.4）。
///
/// 覆盖：追加落盘 + 冷启动回读、容量上限丢最旧 + `dropped_count`、
/// `peek` 不移除、`acknowledge` 按实例身份移除（溢出-在途并发不错删）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/track/track_event.dart';
import 'package:zhaoyazhao/core/track/track_queue.dart';

TrackEvent _event(int seq) => TrackEvent(
      event: TrackEventName.layerSwitch,
      ts: DateTime.utc(2026, 9, 29, 10, 0, 0, seq % 1000),
      interactionId: 'iid-$seq',
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('track_queue_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File file() => File('${tempDir.path}/queue.jsonl');

  test('enqueue 追加落盘，冷启动回读恢复', () async {
    final queue = TrackQueue(file: file());
    await queue.enqueue(_event(1));
    await queue.enqueue(_event(2));

    final reloaded = await TrackQueue.open(file());
    expect(reloaded.length, 2);
    expect(reloaded.peek(1).single.interactionId, 'iid-1');
  });

  test('容量上限丢最旧 + dropped_count 计数', () async {
    final queue = TrackQueue(file: file(), capacity: 3);
    await queue.enqueue(_event(1));
    await queue.enqueue(_event(2));
    await queue.enqueue(_event(3));
    await queue.enqueue(_event(4)); // 溢出：丢 iid-1
    expect(queue.length, 3);
    expect(queue.droppedCount, 1);
    expect(queue.peek(1).single.interactionId, 'iid-2');
  });

  test('peek 不移除（失败退回队首由「不移除」天然满足）', () async {
    final queue = TrackQueue(file: file());
    await queue.enqueue(_event(1));
    final peeked = queue.peek(1);
    expect(peeked.single.interactionId, 'iid-1');
    expect(queue.length, 1); // 仍在队首
  });

  test('acknowledge 按实例身份移除指定事件', () async {
    final queue = TrackQueue(file: file());
    await queue.enqueue(_event(1));
    await queue.enqueue(_event(2));
    final batch = queue.peek(1); // [iid-1]
    await queue.acknowledge(batch);
    expect(queue.length, 1);
    expect(queue.peek(1).single.interactionId, 'iid-2');
  });

  test('acknowledge 后重写文件，冷启动读到剩余事件', () async {
    final queue = TrackQueue(file: file());
    await queue.enqueue(_event(1));
    await queue.enqueue(_event(2));
    await queue.acknowledge(queue.peek(1));

    final reloaded = await TrackQueue.open(file());
    expect(reloaded.length, 1);
    expect(reloaded.peek(1).single.interactionId, 'iid-2');
  });

  test('溢出后 acknowledge 重写文件消去被丢旧行', () async {
    final queue = TrackQueue(file: file(), capacity: 2);
    await queue.enqueue(_event(1));
    await queue.enqueue(_event(2));
    await queue.enqueue(_event(3)); // 溢出丢 iid-1
    await queue.acknowledge(queue.peek(1)); // 上报 iid-2

    final reloaded = await TrackQueue.open(file());
    expect(reloaded.length, 1);
    expect(reloaded.peek(1).single.interactionId, 'iid-3');
  });

  test('坏行跳过不拖垮加载', () async {
    await file().writeAsString('{"broken": true}\n'
        '${jsonEncode(_event(1).toJson())}\n');
    final queue = await TrackQueue.open(file());
    expect(queue.length, 1);
    expect(queue.peek(1).single.interactionId, 'iid-1');
  });

  test('droppedCount 只读后 reset 仅在 takeDroppedCount', () async {
    final queue = TrackQueue(file: file(), capacity: 1);
    await queue.enqueue(_event(1));
    await queue.enqueue(_event(2)); // 溢出
    expect(queue.droppedCount, 1);
    expect(queue.droppedCount, 1); // 只读不重置
    expect(queue.takeDroppedCount(), 1);
    expect(queue.droppedCount, 0);
  });
}
