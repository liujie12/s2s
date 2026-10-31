/// 车牌控件（[PlateField]）的 widget 测试。
///
/// 守的是「三段齐全才落值」与「存储值可回显」两条：半截车牌会让必填判定与
/// 详情展示都变脏，必须在控件层就挡住。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/plate_field.dart';

/// 把车牌控件放进最小可交互宿主（[onChanged] 写回状态并重建）。
///
/// 参数 [initial] 初始值；[onValue] 值变化回调。
/// 返回：状态宿主控件。
Widget _host({required String initial, required ValueChanged<String> onValue}) {
  var value = initial;
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: const EdgeInsets.all(16),
          child: PlateField(
            value: value,
            onChanged: (v) {
              onValue(v);
              setState(() => value = v);
            },
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('已有值按三段回显', (tester) async {
    await tester.pumpWidget(_host(initial: '皖A12345', onValue: (_) {}));

    expect(find.text('皖'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('12345'), findsOneWidget);
  });

  testWidgets('只选省份与字母、没填号码时不落值（不产生半截车牌）', (tester) async {
    String? written;
    await tester.pumpWidget(
      _host(initial: '', onValue: (v) => written = v),
    );

    await tester.tap(find.text('省份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('皖'));
    await tester.pumpAndSettle();
    expect(written, '');

    await tester.tap(find.text('字母'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    expect(written, '');
  });

  testWidgets('三段齐全后拼成 皖A12345', (tester) async {
    String? written;
    await tester.pumpWidget(
      _host(initial: '', onValue: (v) => written = v),
    );

    await tester.tap(find.text('省份'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('皖'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('字母'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '12345');
    await tester.pumpAndSettle();
    expect(written, '皖A12345');
  });

  testWidgets('号码段自动转大写并剔除非字母数字', (tester) async {
    String? written;
    await tester.pumpWidget(
      _host(initial: '皖A', onValue: (v) => written = v),
    );

    await tester.enterText(find.byType(TextField), 'ad1-234');
    await tester.pumpAndSettle();
    expect(written, '皖AAD1234');
  });
}
