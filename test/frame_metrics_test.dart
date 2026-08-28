/// 帧耗时统计的断言（PRD §6.10.1 POC-B）。
///
/// 为什么这套统计值得测：POC-B 的产出是**要写进 SLA 对外承诺的数字**。
/// 分位算错的表现是「P95 看起来达标」—— 没有任何异常现象提示它错了，
/// 而错误的达标结论会一路带到上线。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/perf/frame_metrics.dart';

void main() {
  group('分位数', () {
    test('P95 取的是高位而非平均 —— 平均值会把偶发长帧摊平，掩盖真实卡顿', () {
      final m = FrameMetrics();
      // 99 帧 8ms + 1 帧 500ms：平均约 13ms「达标」，但用户确实卡了一下。
      for (int i = 0; i < 99; i++) {
        m.addSampleMs(8);
      }
      m.addSampleMs(500);

      expect(m.p50Ms, 8);
      expect(m.maxMs, 500);
      // P95 与 P99 都在 8ms：100 个样本里那一帧只占 1%，分位数按定义就该
      // 把它排除在外。**这正是只报分位数不够的证据** —— 必须同时看 Max 与
      // 直方图，否则「P99 达标」会盖住一次 500ms 的真实卡顿。
      expect(m.p95Ms, 8);
      expect(m.p99Ms, 8);
      expect(m.histogram()['>100ms'], 1, reason: '长帧只有直方图与 Max 能看见');
    });

    test('单调递增样本上，分位下标算对（最近秩法，不插值）', () {
      final m = FrameMetrics();
      for (int i = 1; i <= 100; i++) {
        m.addSampleMs(i.toDouble());
      }

      // (95/100) × 99 = 94.05 → round 94 → 第 95 个值 = 95
      expect(m.p95Ms, 95);
      expect(m.p50Ms, 50);
      expect(m.maxMs, 100);
    });

    test('无样本时分位返回 0 而不抛异常 —— 面板在首帧前就会读它', () {
      final m = FrameMetrics();
      expect(m.p95Ms, 0);
      expect(m.maxMs, 0);
      expect(m.jankRatio, 0);
    });
  });

  group('超预算统计', () {
    test('判据是「严格大于 16ms」，恰好 16ms 不算掉帧', () {
      final m = FrameMetrics();
      m.addSampleMs(16);
      m.addSampleMs(16.1);

      expect(m.totalFrames, 2);
      expect(m.totalJankFrames, 1);
      expect(m.jankRatio, 0.5);
    });

    test('累计计数不受环形缓冲上限影响 —— 否则长时间压测的掉帧率会失真', () {
      final m = FrameMetrics(capacity: 10);
      for (int i = 0; i < 100; i++) {
        m.addSampleMs(100); // 全部超预算
      }

      // 样本只留最近 10 个，但累计计数必须是 100，
      // 否则「跑了 5 分钟，掉帧率 x%」这个结论只反映了最后几秒。
      expect(m.sampleCount, 10);
      expect(m.totalFrames, 100);
      expect(m.totalJankFrames, 100);
      expect(m.jankRatio, 1.0);
    });
  });

  group('直方图', () {
    test('分桶边界落在 16ms 判据上，且总数等于样本数（无点被漏分或重复计）', () {
      final m = FrameMetrics();
      for (final ms in [4.0, 8.0, 8.1, 16.0, 16.1, 32.0, 40.0, 60.0, 200.0]) {
        m.addSampleMs(ms);
      }

      final h = m.histogram();
      // 边界值归**下**桶（8.0 进 ≤8ms，16.0 进 8–16ms），与 jank 判据
      // 「>16 才算掉帧」同向。两处口径若不一致，直方图与掉帧率会对不上，
      // 而这种对不上极难解释，只会让人怀疑整份数据。
      expect(h['≤8ms'], 2, reason: '4.0 / 8.0');
      expect(h['8–16ms'], 2, reason: '8.1 / 16.0');
      expect(h['16–32ms'], 2, reason: '16.1 / 32.0');
      expect(h['32–50ms'], 1, reason: '40.0');
      expect(h['50–100ms'], 1, reason: '60.0');
      expect(h['>100ms'], 1, reason: '200.0');
      expect(h.values.reduce((a, b) => a + b), 9, reason: '所有样本必须恰好落入一个桶');
    });

    test('reset 清空样本与累计计数 —— 换压测档位后不清零会被上一档稀释', () {
      final m = FrameMetrics();
      m.addSampleMs(100);
      m.reset();

      expect(m.sampleCount, 0);
      expect(m.totalFrames, 0);
      expect(m.totalJankFrames, 0);
      expect(m.p95Ms, 0);
    });
  });

  test('导出 JSON 带上档位与点数 —— 脱离这两项的 P95 无法回填 SLA', () {
    final m = FrameMetrics();
    m.addSampleMs(10);

    final json = m.toJson(label: '5 万点', pointCount: 50000);
    expect(json, contains('"label": "5 万点"'));
    expect(json, contains('"pointCount": 50000'));
    expect(json, contains('"p95Ms"'));
    expect(json, contains('"histogram"'));
  });
}
