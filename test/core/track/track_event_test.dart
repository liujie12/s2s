/// 埋点事件模型单测（[130]；§7.2 埋点组 / 详细设计 §17.1/§17.4.1）。
///
/// 覆盖：`ts` 毫秒精度与去重键冻结、事件名线值逐字一致、
/// `LayerSwitchProps` 12 字段序列化、批次体与头分列（互不覆盖）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/track/track_event.dart';

void main() {
  group('formatIso8601Ms', () {
    test('固定 3 位毫秒（DATETIME(3) 去重键要求）', () {
      final t = DateTime.utc(2026, 9, 29, 10, 0, 0, 123);
      expect(formatIso8601Ms(t), '2026-09-29T10:00:00.123Z');
    });

    test('整毫秒时刻仍带 3 位（不用 toIso8601String 会省略）', () {
      final t = DateTime.utc(2026, 9, 29, 10, 0, 0);
      expect(formatIso8601Ms(t), '2026-09-29T10:00:00.000Z');
    });

    test('本地时刻序列化时转 UTC（Z 后缀）', () {
      final t = DateTime(2026, 9, 29, 10, 0, 0, 0, 123);
      // 本地时区无关：转 UTC 后是 10:00 减本地偏移；只断言结尾 Z 与 3 位毫秒。
      final out = formatIso8601Ms(t);
      expect(out.endsWith('Z'), isTrue);
      expect(RegExp(r'\.\d{3}Z$').hasMatch(out), isTrue);
    });
  });

  group('TrackEvent 去重键三列冻结', () {
    test('ts 构造时截断到毫秒（微秒位清零）', () {
      final withMicros = DateTime.utc(2026, 9, 29, 10, 0, 0, 123, 456);
      final event = TrackEvent(
        event: TrackEventName.layerSwitch,
        ts: withMicros,
        interactionId: 'iid-1',
      );
      expect(event.ts.microsecond, 0);
      expect(event.ts.millisecond, 123);
    });

    test('重复 toJson 产出逐字相同的去重键（event/ts/interaction_id）', () {
      final event = TrackEvent(
        event: TrackEventName.layerSwitch,
        ts: DateTime.utc(2026, 9, 29, 10, 0, 0, 123),
        interactionId: 'iid-frozen',
      );
      final a = event.toJson();
      final b = event.toJson();
      expect(a['event'], b['event']);
      expect(a['ts'], b['ts']);
      expect(a['interaction_id'], b['interaction_id']);
    });

    test('序列化字段为 snake_case 契约形态', () {
      final event = TrackEvent(
        event: TrackEventName.postPublished,
        ts: DateTime.utc(2026, 9, 29, 10, 0, 0, 123),
        interactionId: 'iid-1',
        requestId: 'req-1',
        props: const <String, Object?>{'k': 'v'},
      );
      final json = event.toJson();
      expect(json['event'], 'post_published');
      expect(json['ts'], '2026-09-29T10:00:00.123Z');
      expect(json['interaction_id'], 'iid-1');
      expect(json['request_id'], 'req-1');
      expect(json['props'], const <String, Object?>{'k': 'v'});
    });

    test('request_id/props 缺失时键省略（不写 null 键）', () {
      final event = TrackEvent(
        event: TrackEventName.contactEvent,
        ts: DateTime.utc(2026, 9, 29, 10, 0, 0, 0),
        interactionId: 'iid-1',
      );
      final json = event.toJson();
      expect(json.containsKey('request_id'), isFalse);
      expect(json.containsKey('props'), isFalse);
    });

    test('fromJson 回读后去重键三列逐字一致（落盘往返）', () {
      final original = TrackEvent(
        event: TrackEventName.layerSwitch,
        ts: DateTime.utc(2026, 9, 29, 10, 0, 0, 123),
        interactionId: 'iid-roundtrip',
        props: const <String, Object?>{'duration_ms': 300},
      );
      final restored = TrackEvent.fromJson(original.toJson());
      expect(restored.event, original.event);
      expect(restored.ts, original.ts);
      expect(restored.interactionId, original.interactionId);
      expect(restored.toJson()['ts'], original.toJson()['ts']);
    });
  });

  group('TrackEventName 线值', () {
    test('五值线值与契约枚举逐字一致', () {
      expect(TrackEventName.layerSwitch.wire, 'layer_switch');
      expect(TrackEventName.postPublished.wire, 'post_published');
      expect(TrackEventName.contactEvent.wire, 'contact_event');
      expect(TrackEventName.demandPushSent.wire, 'demand_push_sent');
      expect(TrackEventName.resourceDetailClick.wire, 'resource_detail_click');
    });

    test('fromWire 反解未知线值抛错不静默', () {
      expect(
        () => TrackEventName.fromWire('no_such_event'),
        throwsArgumentError,
      );
    });
  });

  group('LayerSwitchProps', () {
    test('必填字段全量序列化（snake_case）', () {
      const props = LayerSwitchProps(
        durationMs: 300,
        tCacheMs: 10,
        tNetMs: 150,
        tAggMs: 20,
        tRenderMs: 120,
        result: LayerSwitchResult.success,
        cacheHit: false,
      );
      final json = props.toJson();
      expect(json['duration_ms'], 300);
      expect(json['t_cache_ms'], 10);
      expect(json['t_net_ms'], 150);
      expect(json['t_agg_ms'], 20);
      expect(json['t_render_ms'], 120);
      expect(json['result'], 'success');
      expect(json['cache_hit'], false);
    });

    test('可空字段缺省时键省略', () {
      const props = LayerSwitchProps(
        durationMs: 1,
        tCacheMs: 0,
        tNetMs: 0,
        tAggMs: 0,
        tRenderMs: 1,
        result: LayerSwitchResult.success,
        cacheHit: true,
      );
      final json = props.toJson();
      expect(json.containsKey('fail_reason'), isFalse);
      expect(json.containsKey('err_code'), isFalse);
      expect(json.containsKey('fps'), isFalse);
      expect(json.containsKey('mem_peak_mb'), isFalse);
      expect(json.containsKey('network_type'), isFalse);
    });

    test('可空字段有值时序列化（含 network_type 线值）', () {
      const props = LayerSwitchProps(
        durationMs: 500,
        tCacheMs: 0,
        tNetMs: 0,
        tAggMs: 0,
        tRenderMs: 500,
        result: LayerSwitchResult.fail,
        failReason: LayerSwitchFailReason.cancelled,
        errCode: 0,
        cacheHit: false,
        fps: 58.5,
        memPeakMb: 128.25,
        networkType: TrackNetworkType.unknown,
      );
      final json = props.toJson();
      expect(json['fail_reason'], 'cancelled');
      expect(json['err_code'], 0);
      expect(json['fps'], 58.5);
      expect(json['mem_peak_mb'], 128.25);
      expect(json['network_type'], 'unknown');
    });
  });

  group('TrackBatch', () {
    test('请求体只含 events + dropped_count，不含批次头两键', () {
      final event = TrackEvent(
        event: TrackEventName.layerSwitch,
        ts: DateTime.utc(2026, 9, 29, 10, 0, 0, 0),
        interactionId: 'iid-event',
      );
      final batch = TrackBatch(
        idempotencyKey: 'batch-key',
        interactionId: 'batch-iid',
        events: [event],
        droppedCount: 3,
      );
      final json = batch.toJson();
      expect(json.containsKey('idempotency_key'), isFalse);
      expect(json.containsKey('interaction_id'), isFalse);
      expect(json['dropped_count'], 3);
      final events = json['events'] as List<Object?>;
      expect((events.single as Map)['interaction_id'], 'iid-event');
    });
  });
}
