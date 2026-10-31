/// 出发时刻工具守门测试（计划 U1 / R2 / R4 / R5）。
///
/// **这些断言防的是什么**：库里同时存在 ISO 时刻串与历史自由文本，解析端
/// 若把后者抛错或误判为可解析，详情页会打崩或显示成 1970 年的时刻；
/// chip 与格式化的边界（跨夜、跨月、补零）若错，用户看到的出发时间就是错的。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/departure_time.dart';

void main() {
  group('tryParseDepartTime', () {
    test('RFC3339 UTC 串 → 本地时刻，往返序列化后逐字还原', () {
      const wire = '2026-10-30T10:30:00Z';
      final parsed = tryParseDepartTime(wire);

      expect(parsed, isNotNull);
      expect(parsed!.isUtc, isFalse);
      expect(departTimeToWire(parsed), wire);
    });

    test('历史自由文本、空串、null → null（不抛异常）', () {
      expect(tryParseDepartTime('工作日 8:00'), isNull);
      expect(tryParseDepartTime(''), isNull);
      expect(tryParseDepartTime('   '), isNull);
      expect(tryParseDepartTime(null), isNull);
    });
  });

  group('departTimeToWire', () {
    test('输出 UTC 秒精度串', () {
      expect(
        departTimeToWire(DateTime.utc(2026, 10, 30, 10, 30)),
        '2026-10-30T10:30:00Z',
      );
    });
  });

  group('formatDepartTime', () {
    final now = DateTime(2026, 10, 30, 17, 32);

    test('同日 → 「今天 HH:mm」', () {
      expect(formatDepartTime(DateTime(2026, 10, 30, 18, 32), now: now), '今天 18:32');
    });

    test('次日 → 「明天 HH:mm」', () {
      expect(formatDepartTime(DateTime(2026, 10, 31, 8, 0), now: now), '明天 08:00');
    });

    test('跨月 → 「M月d日 HH:mm」', () {
      expect(formatDepartTime(DateTime(2026, 11, 2, 8, 0), now: now), '11月2日 08:00');
    });

    test('分钟补零（08:05 不显示 08:5）', () {
      expect(formatDepartTime(DateTime(2026, 10, 30, 8, 5), now: now), '今天 08:05');
    });
  });

  group('departTimeQuickChips', () {
    test('三枚 chip 文案固定且顺序为「现在 / 1 小时后 / 明早」', () {
      final chips = departTimeQuickChips(DateTime(2026, 10, 30, 17, 32));

      expect([for (final chip in chips) chip.label], ['现在出发', '1 小时后', '明早 8:00']);
    });

    test('AE1：17:32 点「1 小时后」→ 18:32', () {
      final chips = departTimeQuickChips(DateTime(2026, 10, 30, 17, 32, 47));

      expect(chips[1].value, DateTime(2026, 10, 30, 18, 32));
    });

    test('AE2：23:10 点「1 小时后」→ 次日 00:10', () {
      final chips = departTimeQuickChips(DateTime(2026, 10, 30, 23, 10));

      expect(chips[1].value, DateTime(2026, 10, 31, 0, 10));
    });

    test('AE2：「明早 8:00」无论当前几点一律取次日 08:00', () {
      expect(
        departTimeQuickChips(DateTime(2026, 10, 30, 7, 0))[2].value,
        DateTime(2026, 10, 31, 8, 0),
      );
      expect(
        departTimeQuickChips(DateTime(2026, 10, 30, 23, 0))[2].value,
        DateTime(2026, 10, 31, 8, 0),
      );
    });
  });
}
