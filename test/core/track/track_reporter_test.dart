/// 埋点聚批上报器单测（[130]；§7.2 埋点组 / 详细设计 §17.4.1/§17.4.2）。
///
/// 覆盖：批次每次组批换新两键、成功→acknowledge、42906→静默退回不丢、
/// 未登录→hold 不发请求、批次头与事件体 `interaction_id` 互不覆盖、
/// 「首批失败混入新事件重批 → 服务端真正写入」。
library;

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/track/track_event.dart';
import 'package:zhaoyazhao/core/track/track_queue.dart';
import 'package:zhaoyazhao/core/track/track_reporter.dart';

import '../../support/api_envelope.dart';
import '../../support/mock_api_server.dart';
import '../../support/network_chain_harness.dart';

TrackEvent _event(int seq) => TrackEvent(
      event: TrackEventName.layerSwitch,
      ts: DateTime.utc(2026, 9, 29, 10, 0, 0, seq % 1000),
      interactionId: 'event-iid-$seq',
    );

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('track_reporter_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  File file() => File('${tempDir.path}/queue.jsonl');

  TrackReporter buildReporter({
    required Dio dio,
    required TrackQueue queue,
    required Future<String?> Function() readToken,
    String Function()? newUuidV4,
  }) {
    var counter = 0;
    return TrackReporter(
      dio: dio,
      queue: queue,
      readToken: readToken,
      newUuidV4: newUuidV4 ?? () => 'uuid-${counter++}',
    );
  }

  group('buildBatch 幂等保全唯一例外', () {
    test('每次组批都换新幂等键与批次交互 ID', () {
      final queue = TrackQueue(file: file());
      final reporter = buildReporter(
        dio: Dio(),
        queue: queue,
        readToken: () async => 'token',
      );
      final b1 = reporter.buildBatch([_event(1)], 0);
      final b2 = reporter.buildBatch([_event(1)], 0);
      expect(b1.idempotencyKey, isNot(b2.idempotencyKey));
      expect(b1.interactionId, isNot(b2.interactionId));
    });
  });

  group('flush', () {
    test('成功 → 移除事件并清零丢弃计数', () async {
      final harness = NetworkChainHarness();
      await harness.start();
      harness.token = 'token';
      harness.stub('POST', '/api/v1/track/events', (req) async {
        return MockResponse(
          body: ApiEnvelope.success(data: {'accepted': 1}),
        );
      });

      final queue = TrackQueue(file: file());
      final reporter = buildReporter(
        dio: harness.dio,
        queue: queue,
        readToken: () async => harness.token,
      );
      await queue.enqueue(_event(1));

      expect(await reporter.flush(), FlushResult.sent);
      expect(queue.length, 0);
      await harness.dispose();
    });

    test('42906 → requeued 且不移除（静默退回队首）', () async {
      final harness = NetworkChainHarness();
      await harness.start();
      harness.token = 'token';
      harness.stub('POST', '/api/v1/track/events', (req) async {
        return MockResponse(
          status: 429,
          headers: const {'Retry-After': '60'},
          body: ApiEnvelope.failure(42906, '埋点上报过于频繁'),
        );
      });

      final queue = TrackQueue(file: file());
      final reporter = buildReporter(
        dio: harness.dio,
        queue: queue,
        readToken: () async => harness.token,
      );
      await queue.enqueue(_event(1));

      expect(await reporter.flush(), FlushResult.requeued);
      expect(queue.length, 1); // 事件仍在队首
      await harness.dispose();
    });

    test('未登录 → notLoggedIn 且不发请求（hold 补报）', () async {
      final harness = NetworkChainHarness();
      await harness.start();
      harness.token = null; // 未登录
      harness.stub('POST', '/api/v1/track/events', (req) async {
        return MockResponse(body: ApiEnvelope.success());
      });

      final queue = TrackQueue(file: file());
      final reporter = buildReporter(
        dio: harness.dio,
        queue: queue,
        readToken: () async => harness.token,
      );
      await queue.enqueue(_event(1));

      expect(await reporter.flush(), FlushResult.notLoggedIn);
      expect(queue.length, 1);
      expect(harness.server.received, isEmpty); // 从未发出请求
      await harness.dispose();
    });

    test('批次头两键与事件体 interaction_id 互不覆盖', () async {
      final harness = NetworkChainHarness();
      await harness.start();
      harness.token = 'token';
      harness.stub('POST', '/api/v1/track/events', (req) async {
        return MockResponse(body: ApiEnvelope.success(data: {'accepted': 1}));
      });

      final queue = TrackQueue(file: file());
      final reporter = buildReporter(
        dio: harness.dio,
        queue: queue,
        readToken: () async => harness.token,
        newUuidV4: () => 'batch-uuid',
      );
      await queue.enqueue(_event(1)); // interaction_id = event-iid-1

      await reporter.flush();

      final req = harness.server.lastRequest!;
      final batchIdem = req.header('idempotency-key');
      final batchIid = req.header('x-interaction-id');
      final body = req.body as Map;
      final eventIid =
          ((body['events'] as List).single as Map)['interaction_id'];
      expect(batchIdem, 'batch-uuid');
      expect(batchIid, 'batch-uuid');
      expect(eventIid, 'event-iid-1'); // 事件体保留自身交互 ID
      expect(batchIid, isNot(eventIid)); // 批次头 ≠ 事件体，互不覆盖
      await harness.dispose();
    });

    test('首批 42906 失败后混入新事件重批 → 换新键且服务端真正写入', () async {
      final harness = NetworkChainHarness();
      await harness.start();
      harness.token = 'token';
      String? firstKey;
      harness.stub('POST', '/api/v1/track/events', (req) async {
        final key = req.header('idempotency-key')!;
        if (firstKey == null) {
          firstKey = key;
          return MockResponse(
            status: 429,
            headers: const {'Retry-After': '60'},
            body: ApiEnvelope.failure(42906, '埋点上报过于频繁'),
          );
        }
        // 第二批：换新 Key，服务端真正执行写入（不是命中幂等缓存回 code=0）。
        return MockResponse(body: ApiEnvelope.success(data: {'accepted': 2}));
      });

      final queue = TrackQueue(file: file());
      final reporter = buildReporter(
        dio: harness.dio,
        queue: queue,
        readToken: () async => harness.token,
      );
      await queue.enqueue(_event(1));
      expect(await reporter.flush(), FlushResult.requeued);

      // 首批失败后新采集一条，重新组批。
      await queue.enqueue(_event(2));
      expect(await reporter.flush(), FlushResult.sent);

      final second = harness.server.received.last;
      expect(second.header('idempotency-key'), isNot(firstKey)); // 换新键
      final events = (second.body as Map)['events'] as List;
      expect(events.length, 2); // 旧 + 新一起真正写入
      expect(queue.length, 0); // 成功后移除
      await harness.dispose();
    });
  });
}
