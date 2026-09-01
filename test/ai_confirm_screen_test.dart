/// AI 确认页界面守门测试（PRD §5.9 五态表 / §9.8 冲刺区与实时跳档）。
///
/// **为什么逻辑已单测过还要这一层**：`ai_guess_builder_test.dart` 证明「猜得对」，
/// `publish_completeness_test.dart` 证明「档位算得对」，这里证明的是
/// 「算出来的结果真接到了角标、按钮和冲刺区上」。那根线断掉时前两层全绿，
/// 而页面上「确认发布」永远可点、或补了门牌号档位不动 —— 原则 133 的病灶。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/ai_confirm_screen.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';

void main() {
  /// 一份填齐必填项的表单（二手闲置，缺门牌号 → 🟡 档）。
  PublishFormState complete() => const PublishFormState(
    leafCategoryId: 40101,
    hasLocation: true,
    title: '九成新实木餐桌',
    priceText: '350',
    priceUnit: '元',
    description: '搬家出售，无磕碰，可上门自取。',
    templateValues: {'condition': '几乎全新', 'pickup': '仅自取'},
    contact: '13800138000',
    agreed: true,
  );

  /// 挂载确认页。
  ///
  /// 参数 [tester] 测试驱动器，[form] 传入的表单快照。
  ///
  /// **为什么要放大视口**：默认 800×600 里，冲刺区与配额说明都在折叠线以下，
  /// 而它们所在的 [ListView] 按需构建 —— 不放大就得到「找不到组件」，
  /// 那不是缺陷，是没看到（发布页测试用的是 `scrollUntilVisible`，
  /// 但本页要断言「补门牌号后底部档位实时变化」，需要两处同屏可见）。
  Future<void> pump(WidgetTester tester, PublishFormState form) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(child: MaterialApp(home: AiConfirmScreen(form: form))),
    );
  }

  /// 取底部「确认发布」是否可点。
  bool confirmEnabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '确认发布'),
    );
    return button.onPressed != null;
  }

  group('§5.9 结果待确认态', () {
    testWidgets('标题与副文说明「可以改」—— 不改也能发，但必须知道可以改', (tester) async {
      await pump(tester, complete());
      expect(find.text('AI 已识别，请核对'), findsOneWidget);
      expect(find.text('每项都可以改，改完再发'), findsOneWidget);
    });

    testWidgets('逐字段展示猜测值，且猜出的项带「AI 猜」角标', (tester) async {
      await pump(tester, complete());
      expect(find.text('九成新实木餐桌'), findsOneWidget);
      expect(find.text('生活 > 二手闲置转让 > 家具家电'), findsOneWidget);
      expect(find.text('350 元'), findsOneWidget);
      // 四件套至少四行带角标 —— 少一个角标等于有一项被当成用户自己填的
      expect(find.text('AI 猜'), findsAtLeastNWidgets(4));
    });

    testWidgets('每行猜测都说出来源（§5.10 Step 4 的用户可见化）', (tester) async {
      await pump(tester, complete());
      expect(find.text('据你已填'), findsAtLeastNWidgets(4));
    });

    testWidgets('「全部重填」在右上而非底部 —— 放弃动作要与确认动作拉开距离', (tester) async {
      await pump(tester, complete());
      final reset = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '全部重填'),
      );
      expect(reset.onPressed, isNotNull);
      // 它必须在 AppBar 里，不能混进底部按钮区
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('全部重填')),
        findsOneWidget,
      );
    });
  });

  group('§5.9「部分字段无法猜出」', () {
    testWidgets('未猜出的字段标「需你补充」并给「去填」入口', (tester) async {
      // 空表单：分类、标题、价格全猜不出
      await pump(tester, const PublishFormState());
      expect(find.text('需你补充'), findsAtLeastNWidgets(3));
      expect(find.text('去填 ›'), findsAtLeastNWidgets(3));
      // 没猜出来的项不该有角标 —— 那会让用户以为 AI 猜了个空值
      expect(find.text('AI 猜'), findsNothing);
    });

    testWidgets('有字段未补齐时「确认发布」禁用，且说出原因', (tester) async {
      await pump(tester, const PublishFormState());
      expect(confirmEnabled(tester), isFalse);
      // 灰按钮不说原因等于把规则藏起来（与发布页同一取向）
      expect(find.text('还有字段标着「需你补充」，补完才能发布'), findsOneWidget);
    });

    testWidgets('全部字段有值时「确认发布」可点', (tester) async {
      await pump(tester, complete());
      expect(confirmEnabled(tester), isTrue);
      expect(find.text('还有字段标着「需你补充」，补完才能发布'), findsNothing);
    });
  });

  group('§9.8 冲刺区与实时跳档', () {
    testWidgets('🟡 档显示冲刺区，只放门牌号一项（三级类目已选到底）', (tester) async {
      await pump(tester, complete());
      expect(find.text('再花 5 秒升「完整」'), findsOneWidget);
      expect(find.text('位置补到门牌号'), findsOneWidget);
      // 分类已选到第三级，故该冲刺项不该出现 —— 让用户去补一个已达成的条件
      // 会让他觉得这个提示是假的
      expect(find.text('分类选到第三级'), findsNothing);
    });

    testWidgets('底部实时显示档位与还差几项', (tester) async {
      await pump(tester, complete());
      expect(find.text('当前完整度：半完整'), findsOneWidget);
      expect(find.text('还差 1 项升完整'), findsOneWidget);
    });

    testWidgets('填入门牌号 → 档位实时从半完整跳完整，冲刺区消失', (tester) async {
      await pump(tester, complete());
      await tester.enterText(find.byType(TextField).first, '3 号楼 2 单元 501');
      await tester.pump();

      expect(find.text('当前完整度：完整'), findsOneWidget);
      expect(find.text('当前完整度：半完整'), findsNothing);
      // §5.9「再花 5 秒」这句承诺必须有可见的兑现
      expect(find.text('附近人 2 倍概率看到'), findsOneWidget);
      expect(find.text('再花 5 秒升「完整」'), findsNothing);
    });

    testWidgets('「取当前定位门牌」呈现但禁用 —— 不隐藏，以便验收确认它是待前置', (tester) async {
      await pump(tester, complete());
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '取当前定位门牌'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('未选分类时冲刺区列出三级类目那一项', (tester) async {
      await pump(tester, const PublishFormState());
      expect(find.text('分类选到第三级'), findsOneWidget);
      expect(find.text('选择三级类目'), findsOneWidget);
    });
  });

  group('§5.10 配额说明', () {
    testWidgets('只说上限不说剩余（剩余次数的计数在服务端）', (tester) async {
      await pump(tester, complete());
      // 未登录 → 未实名 → 3 次
      expect(find.textContaining('你当前每日 AI 额度 3 次'), findsOneWidget);
      expect(find.textContaining('未实名'), findsOneWidget);
      expect(find.textContaining('剩余'), findsNothing);
    });

    testWidgets('高敏类目在文案里标出 +10（家政需个人资质）', (tester) async {
      await pump(tester, complete().withCategory(50101));
      expect(find.textContaining('高敏类目 +10'), findsOneWidget);
    });
  });

  group('§5.9 逐项修改', () {
    testWidgets('点某行弹出修改框，改完新值上屏', (tester) async {
      await pump(tester, complete());
      await tester.tap(find.text('九成新实木餐桌'));
      await tester.pumpAndSettle();
      expect(find.text('修改标题'), findsOneWidget);

      await tester.enterText(find.byType(TextField).last, '实木餐桌九成新');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('实木餐桌九成新'), findsOneWidget);
    });

    testWidgets('改成空 = 撤回修改，回到 AI 原猜测值（不留「有值但是空」的第三态）', (tester) async {
      await pump(tester, complete());
      await tester.tap(find.text('九成新实木餐桌'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '改一下');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('改一下'), findsOneWidget);

      await tester.tap(find.text('改一下'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('九成新实木餐桌'), findsOneWidget);
    });

    testWidgets('取消不改动原值', (tester) async {
      await pump(tester, complete());
      await tester.tap(find.text('350 元'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '999');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('350 元'), findsOneWidget);
      expect(find.text('999'), findsNothing);
    });
  });
}
