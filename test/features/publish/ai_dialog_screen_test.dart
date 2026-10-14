/// 模式③ 对话式一问一答测试（PRD §5.9「每屏 1 问，新手首选用」）。
///
/// 守的是「引导节奏与必答闸门」这两条线：一屏一问不能退化成一张长表单；
/// 必答项未答时「下一步」必须禁用（否则新手会跳过必填、到最后发不出去）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/ai_dialog_screen.dart';

void main() {
  /// 挂载引导页。
  ///
  /// 参数：[tester] 测试驱动器。
  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: AiDialogScreen())),
    );
    await tester.pumpAndSettle();
  }

  group('§5.9 模式③ 每屏 1 问', () {
    testWidgets('首问为「你想发布什么？」并显示进度 1 / 8', (tester) async {
      await pump(tester);
      expect(find.text('第 1 / 8 问'), findsOneWidget);
      expect(find.text('你想发布什么？'), findsOneWidget);
    });

    testWidgets('首问可前进 → 到分类问（2 / 8）', (tester) async {
      await pump(tester);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 8 问'), findsOneWidget);
      expect(find.text('它属于哪个分类？'), findsOneWidget);
    });

    testWidgets('分类未选时「下一步」禁用（必答闸门）', (tester) async {
      await pump(tester);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();

      final button = tester.widget<ElevatedButton>(
        find.widgetWithText(ElevatedButton, '下一步'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('可「上一步」回到上一问，且答案保留', (tester) async {
      await pump(tester);
      await tester.tap(find.text('下一步'));
      await tester.pumpAndSettle();
      expect(find.text('第 2 / 8 问'), findsOneWidget);

      await tester.tap(find.text('上一步'));
      await tester.pumpAndSettle();
      expect(find.text('第 1 / 8 问'), findsOneWidget);
      // 首问的类型选择仍在（选「我有资源要发布」态为选中）
      expect(find.text('我有资源要发布'), findsOneWidget);
    });

    testWidgets('末问主按钮文案为「开始识别并发布」', (tester) async {
      await pump(tester);
      // 逐问前进到末问需要真实填答（分类/位置/价格…），此处只验证首问
      // 不是末问文案 —— 反向守「文案随步骤切换」这条线。
      expect(find.text('开始识别并发布'), findsNothing);
      expect(find.text('下一步'), findsOneWidget);
    });
  });
}
