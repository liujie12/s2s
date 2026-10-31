/// 出发时间内联控件的 widget 测试（计划 U4 / R1-R4 / R7）。
///
/// **这些断言防的是什么**：
///   - AE1/AE2 是 chip 的跨夜边界 —— 差一小时跨天、明早取次日，
///     算错一天用户在详情页看到的就是错日期；
///   - AE3 是滚轮范围 —— `initialDateTime` 越界会直接抛断言，
///     范围算错则用户能选到过去；
///   - R7 是历史自由文本 —— 解析不了必须原样留值、不得回调覆盖，
///     否则老帖子的「工作日 8:00」会被静默清成空。
///
/// **为什么用注入的 [DepartTimeField.now]**：chip 的基准时刻若不固定，
/// 跨分钟跑测试就会偶发失败；注入后同一份断言在任何时间都成立。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/departure_time.dart';
import 'package:zhaoyazhao/features/publish/depart_time_field.dart';

/// 承载控件的测试台：把回调写回 `value`，模拟发布页的受控行为。
///
/// 构造参数：[initial] 初始字段值；[now] 注入的当前时刻。
class _Harness extends StatefulWidget {
  const _Harness({this.initial = '', this.now});

  /// 初始字段字符串值。
  final String initial;

  /// 注入的当前时刻。
  final DateTime? now;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  /// 当前字段值（受控回写）。
  late String value = widget.initial;

  /// 每次 onChanged 写回的顺序记录（用于断言「没有回调」）。
  final List<String> writes = [];

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: DepartTimeField(
          value: value,
          now: widget.now,
          onChanged: (next) {
            writes.add(next);
            setState(() => value = next);
          },
        ),
      ),
    );
  }
}

void main() {
  /// 组装测试台。
  ///
  /// 参数 [initial] 初始值；[now] 当前时刻。
  /// 返回：待 pump 的 [Widget]。
  Widget app({String initial = '', DateTime? now}) =>
      _Harness(initial: initial, now: now);

  /// 取测试台状态（读取写入记录）。
  _HarnessState harness(WidgetTester tester) =>
      tester.state<_HarnessState>(find.byType(_Harness));

  group('快捷 chip', () {
    testWidgets('AE1：17:32 点「1 小时后」→ 值行「今天 18:32」且上送对应 UTC 串', (
      tester,
    ) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      await tester.pumpWidget(app(now: now));

      await tester.tap(find.text('1 小时后'));
      await tester.pumpAndSettle();

      expect(harness(tester).writes, [
        departTimeToWire(DateTime(2026, 10, 30, 18, 32)),
      ]);
      expect(find.text('今天 18:32'), findsOneWidget);
    });

    testWidgets('AE2：23:10 点「1 小时后」→「明天 00:10」', (tester) async {
      final now = DateTime(2026, 10, 30, 23, 10);
      await tester.pumpWidget(app(now: now));

      await tester.tap(find.text('1 小时后'));
      await tester.pumpAndSettle();

      expect(harness(tester).writes, [
        departTimeToWire(DateTime(2026, 10, 31, 0, 10)),
      ]);
      expect(find.text('明天 00:10'), findsOneWidget);
    });

    testWidgets('AE2：「明早 8:00」恒取次日 08:00，与当前时刻无关', (tester) async {
      final now = DateTime(2026, 10, 30, 23, 0);
      await tester.pumpWidget(app(now: now));

      await tester.tap(find.text('明早 8:00'));
      await tester.pumpAndSettle();

      expect(harness(tester).writes, [
        departTimeToWire(DateTime(2026, 10, 31, 8, 0)),
      ]);
      expect(find.text('明天 08:00'), findsOneWidget);
    });
  });

  group('滚轮展开与收起', () {
    testWidgets('点值行展开滚轮，再点收起', (tester) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      await tester.pumpWidget(app(now: now));

      expect(find.byType(CupertinoDatePicker), findsNothing);

      await tester.tap(find.text('选择出发时间'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsOneWidget);

      await tester.tap(find.text('选择出发时间'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsNothing);
    });

    testWidgets('点 chip 后滚轮若已展开则收起（不占版面）', (tester) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      await tester.pumpWidget(app(now: now));

      await tester.tap(find.text('选择出发时间'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsOneWidget);

      await tester.tap(find.text('现在出发'));
      await tester.pumpAndSettle();
      expect(find.byType(CupertinoDatePicker), findsNothing);
      expect(find.text('今天 17:32'), findsOneWidget);
    });
  });

  group('滚轮范围与初始定位（AE3）', () {
    testWidgets('可选范围是 [当前步长整点, 当前 + 7 天]', (tester) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      await tester.pumpWidget(app(now: now));
      await tester.tap(find.text('选择出发时间'));
      await tester.pumpAndSettle();

      final picker = tester.widget<CupertinoDatePicker>(
        find.byType(CupertinoDatePicker),
      );
      // 17:32 向上对齐到 5 分钟步长 → 17:35，早于当前时刻的项不可选
      expect(picker.minimumDate, DateTime(2026, 10, 30, 17, 35));
      // 17:32 + 7 天 = 11/6 17:32，向下对齐步长 → 17:30
      expect(picker.maximumDate, DateTime(2026, 11, 6, 17, 30));
      expect(picker.minuteInterval, 5);
      expect(picker.mode, CupertinoDatePickerMode.dateAndTime);
      expect(picker.use24hFormat, isTrue);
    });

    testWidgets('未选值时滚轮定位到下限', (tester) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      await tester.pumpWidget(app(now: now));
      await tester.tap(find.text('选择出发时间'));
      await tester.pumpAndSettle();

      final picker = tester.widget<CupertinoDatePicker>(
        find.byType(CupertinoDatePicker),
      );
      expect(picker.initialDateTime, DateTime(2026, 10, 30, 17, 35));
    });

    testWidgets('已选值时滚轮定位到该时刻', (tester) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      final selected = departTimeToWire(DateTime(2026, 10, 31, 9, 15));
      await tester.pumpWidget(app(initial: selected, now: now));

      expect(find.text('明天 09:15'), findsOneWidget);

      await tester.tap(find.text('明天 09:15'));
      await tester.pumpAndSettle();

      final picker = tester.widget<CupertinoDatePicker>(
        find.byType(CupertinoDatePicker),
      );
      expect(picker.initialDateTime, DateTime(2026, 10, 31, 9, 15));
    });
  });

  group('R7 历史自由文本', () {
    testWidgets('解析不了的历史文本显示未选，且不回调覆盖原值', (tester) async {
      final now = DateTime(2026, 10, 30, 17, 32);
      await tester.pumpWidget(
        app(initial: '工作日 8:00', now: now),
      );
      await tester.pumpAndSettle();

      expect(find.text('选择出发时间'), findsOneWidget);
      expect(find.text('工作日 8:00'), findsNothing);
      expect(harness(tester).writes, isEmpty);

      // 展开滚轮同样不得触发写回（初始化不是用户操作）
      await tester.tap(find.text('选择出发时间'));
      await tester.pumpAndSettle();
      expect(harness(tester).writes, isEmpty);
    });
  });

  group('可访问性', () {
    testWidgets('值行有可读语义标签，热区不小于 44×44', (tester) async {
      final handle = tester.ensureSemantics();
      final now = DateTime(2026, 10, 30, 17, 32);

      await tester.pumpWidget(app(now: now));

      expect(find.bySemanticsLabel('出发时间'), findsOneWidget);

      // chip 内部也含 InkWell，故把查找范围收进值行的语义节点
      final rowSize = tester.getSize(
        find.descendant(
          of: find.bySemanticsLabel('出发时间'),
          matching: find.byType(InkWell),
        ),
      );
      expect(rowSize.height, greaterThanOrEqualTo(44));

      final chipSize = tester.getSize(
        find.widgetWithText(ChoiceChip, '现在出发'),
      );
      expect(chipSize.height, greaterThanOrEqualTo(44));
      handle.dispose();
    });

    testWidgets('已选后语义 value 为格式化文案', (tester) async {
      final handle = tester.ensureSemantics();
      final now = DateTime(2026, 10, 30, 17, 32);

      await tester.pumpWidget(
        app(initial: departTimeToWire(DateTime(2026, 10, 30, 18, 32)), now: now),
      );

      final semantics = tester.getSemantics(find.bySemanticsLabel('出发时间'));
      expect(semantics.value, '今天 18:32');
      handle.dispose();
    });
  });
}
