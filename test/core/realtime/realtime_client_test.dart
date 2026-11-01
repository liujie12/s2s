import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/realtime/realtime_client.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

/// 实时通道纯函数测试：地址推导、事件解析、退避计算。
///
/// 连接本身依赖真实 WebSocket，单测只覆盖「算错就会静默失效」的三处：
/// 地址拼错连不上、事件解析错收不到、退避算错会打爆服务端。
void main() {
  group('realtimeUriFor', () {
    test('生产 https 基址推导为 wss 根路径', () {
      expect(
        realtimeUriFor('https://s2s.build110.com').toString(),
        'wss://s2s.build110.com${NfrRealtime.endpointPath}',
      );
    });

    test('本地 http 基址推导为 ws，并保留路径前缀', () {
      expect(
        realtimeUriFor('http://127.0.0.1:8080/api/v1/').toString(),
        'ws://127.0.0.1:8080/api/v1${NfrRealtime.endpointPath}',
      );
    });

    test('缺少主机时抛 FormatException', () {
      expect(() => realtimeUriFor(''), throwsFormatException);
    });
  });

  group('realtimeMessageEventOf', () {
    test('新消息事件解析出会话与序号', () {
      final event = realtimeMessageEventOf(<String, Object?>{
        'type': 'message.new',
        'conversationId': 9,
        'seq': 12,
      });

      expect(event, isNotNull);
      expect(event!.conversationId, 9);
      expect(event.seq, 12);
    });

    test('未知类型或字段缺失返回 null', () {
      expect(
        realtimeMessageEventOf(<String, Object?>{'type': 'other'}),
        isNull,
      );
      expect(
        realtimeMessageEventOf(<String, Object?>{
          'type': 'message.new',
          'conversationId': 9,
        }),
        isNull,
      );
      expect(realtimeMessageEventOf('not-a-map'), isNull);
    });
  });

  group('realtimeReconnectDelay', () {
    test('首次退避落在基数 ±20% 内', () {
      final delay = realtimeReconnectDelay(0, Random(7));
      final base = NfrRealtime.reconnectBaseDelay.inMilliseconds;
      final jitter = (base * NfrRealtime.reconnectJitterRatio).round();

      expect(delay.inMilliseconds, greaterThanOrEqualTo(base - jitter));
      expect(delay.inMilliseconds, lessThanOrEqualTo(base + jitter));
    });

    test('指数增长后封顶，不会超过上限', () {
      final delay = realtimeReconnectDelay(30, Random(7));

      expect(
        delay.inMilliseconds,
        lessThanOrEqualTo(NfrRealtime.reconnectMaxDelay.inMilliseconds),
      );
    });

    test('极大次数不溢出且仍为正时长', () {
      final delay = realtimeReconnectDelay(1000, Random(7));

      expect(delay.inMilliseconds, greaterThan(0));
      expect(
        delay.inMilliseconds,
        lessThanOrEqualTo(NfrRealtime.reconnectMaxDelay.inMilliseconds),
      );
    });
  });
}
