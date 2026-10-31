/// 选单下拉控件（[OptionField]）的 widget 测试。
///
/// 守的是本轮两条口径：① 选单统一走「值行 + 面板」，不再铺 chip；
/// ② 品牌/颜色可手填、车型不可手填。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/option_field.dart';

/// 把控件放进最小可交互宿主（[onChanged] 写回状态并重建）。
///
/// 参数 [initial] 初始值；[options] 候选值；[allowCustom] 是否允许手填。
/// 返回：状态宿主控件。
Widget _host({
  required String initial,
  required List<String> options,
  bool allowCustom = false,
  required ValueChanged<String> onValue,
}) {
  var value = initial;
  return MaterialApp(
    home: Scaffold(
      body: StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: const EdgeInsets.all(16),
          child: OptionField(
            value: value,
            options: options,
            allowCustom: allowCustom,
            maxLength: 12,
            placeholder: '请选择',
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
  testWidgets('未选时显示占位，点开面板后选一项并写回', (tester) async {
    String? written;
    await tester.pumpWidget(
      _host(
        initial: '',
        options: const ['轿车', 'SUV'],
        onValue: (v) => written = v,
      ),
    );

    expect(find.text('请选择'), findsOneWidget);
    expect(find.text('SUV'), findsNothing);

    await tester.tap(find.text('请选择'));
    await tester.pumpAndSettle();
    expect(find.text('轿车'), findsOneWidget);
    expect(find.text('SUV'), findsOneWidget);

    await tester.tap(find.text('SUV'));
    await tester.pumpAndSettle();
    expect(written, 'SUV');
    // 选中后面板收起，值行显示实值
    expect(find.text('SUV'), findsOneWidget);
    expect(find.text('轿车'), findsNothing);
  });

  testWidgets('再点已选项即清空（与旧 chip 行为一致）', (tester) async {
    String? written;
    await tester.pumpWidget(
      _host(
        initial: '轿车',
        options: const ['轿车', 'SUV'],
        onValue: (v) => written = v,
      ),
    );

    await tester.tap(find.text('轿车').first);
    await tester.pumpAndSettle();
    // 展开后「轿车」同时出现在值行与面板项
    expect(find.text('轿车'), findsNWidgets(2));

    await tester.tap(find.text('轿车').last);
    await tester.pumpAndSettle();
    expect(written, '');
    expect(find.text('请选择'), findsOneWidget);
  });

  testWidgets('允许手填时，面板底部进入手填并写回原样值', (tester) async {
    String? written;
    await tester.pumpWidget(
      _host(
        initial: '',
        options: const ['比亚迪', '大众'],
        allowCustom: true,
        onValue: (v) => written = v,
      ),
    );

    await tester.tap(find.text('请选择'));
    await tester.pumpAndSettle();
    expect(find.text('没找到？手动输入'), findsOneWidget);

    await tester.tap(find.text('没找到？手动输入'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '极石');
    await tester.pumpAndSettle();
    expect(written, '极石');

    // 「返回列表」把手填框换回面板
    await tester.tap(find.text('返回列表'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('比亚迪'), findsOneWidget);
  });

  testWidgets('不允许手填时（车型）面板没有手填入口', (tester) async {
    await tester.pumpWidget(
      _host(
        initial: '',
        options: const ['轿车', 'SUV'],
        onValue: (_) {},
      ),
    );

    await tester.tap(find.text('请选择'));
    await tester.pumpAndSettle();
    expect(find.text('没找到？手动输入'), findsNothing);
  });
}
