/// 发布完成页界面守门测试（PRD §8 T6-④ 完整度卡 / §9.8 三档 / §5.11 有效期）。
///
/// **这一层守的是「完成页不能把最坏情况显示成最好情况」**：`form` 为空
/// （直达路由、或将来某次改动忘了传 extra）时若默认成 🟢，用户会以为自己
/// 信息已完整，从此再也不会来补 —— 而 §9.8 的推荐权重其实只给了他 ×0.5。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';
import 'package:zhaoyazhao/features/publish/publish_success_screen.dart';

void main() {
  /// 一份必填齐全但缺门牌号的表单（→ 🟡 档）。
  PublishFormState yellow() => const PublishFormState(
    leafCategoryId: 40101,
    hasLocation: true,
    title: '九成新实木餐桌',
    priceText: '350',
    priceUnit: '元',
    description: '搬家出售，无磕碰。',
    templateValues: {'condition': '几乎全新'},
    contact: '13800138000',
    agreed: true,
  );

  /// 挂载完成页。
  ///
  /// 参数 [tester] 测试驱动器，[form] 表单快照（可空，模拟直达路由）。
  Future<void> pump(WidgetTester tester, PublishFormState? form) async {
    await tester.pumpWidget(MaterialApp(home: PublishSuccessScreen(form: form)));
  }

  group('§8 T6-④：完整度卡取代单纯的成功 toast', () {
    testWidgets('发布成功文案 + 完整度卡同时在场', (tester) async {
      await pump(tester, yellow());
      expect(find.text('发布成功'), findsOneWidget);
      // 卡片是这一页存在的理由。只剩「发布成功」时它就退化成了一个全屏 toast
      expect(find.text('当前完整度：半完整'), findsOneWidget);
    });

    testWidgets('显示三条件满足数与判定出处，便于对账', (tester) async {
      await pump(tester, yellow());
      expect(find.textContaining('三条件满足 2 / 3'), findsOneWidget);
      expect(find.textContaining('§9.8'), findsOneWidget);
    });

    testWidgets('档名只出现一次 —— 不写「完整度 🟡 半完整」这种重复档名', (tester) async {
      await pump(tester, yellow());
      // 重复档名的写法在改档位时必漏改一处
      expect(find.textContaining('半完整'), findsOneWidget);
    });
  });

  group('🟡 档：列全部差项 + 权益三条 + 补齐入口', () {
    testWidgets('差项列全部而非只报第一条（§5.11「30 秒补上」的前提）', (tester) async {
      await pump(tester, null);
      // 空表单三项全缺，三条都得出现
      expect(find.text('· 还有必填项没填'), findsOneWidget);
      expect(find.text('· 位置补到门牌号'), findsOneWidget);
      expect(find.text('· 分类选到第三级'), findsOneWidget);
    });

    testWidgets('权益三条齐备，且第一条同时说出目标与当前权重', (tester) async {
      await pump(tester, yellow());
      expect(find.text('· 推荐池权重 ×2 优先展示（当前 ×1）'), findsOneWidget);
      expect(find.text('· 附近人 2 倍概率看到你'), findsOneWidget);
      expect(find.text('· 列表页排序前置，不落末位'), findsOneWidget);
    });

    testWidgets('补齐按钮文案不承诺保留现场（跳回发布页会丢已填内容）', (tester) async {
      await pump(tester, yellow());
      expect(find.text('回去补齐（约 30 秒）'), findsOneWidget);
      // 「立即补齐」会让用户以为点进去还是那张填好的表
      expect(find.text('立即补齐'), findsNothing);
    });
  });

  group('🟢 档：无升级空间时不显示差项与补齐按钮', () {
    testWidgets('已达最高档 → 显示权重与权益陈述，不显示「还差这些」', (tester) async {
      await pump(tester, yellow().copyWith(doorNumber: '3 号楼 501'));
      expect(find.text('当前完整度：完整'), findsOneWidget);
      expect(find.textContaining('已是最高档'), findsOneWidget);
      expect(find.textContaining('推荐池权重 ×2'), findsOneWidget);

      // §9.8 表里 🟢 档的「升级引导」列就是一个破折号
      expect(find.textContaining('还差这些'), findsNothing);
      expect(find.text('回去补齐（约 30 秒）'), findsNothing);
    });
  });

  group('form 为空时按 🔴 档而非 🟢', () {
    testWidgets('直达路由（无表单快照）落待补档', (tester) async {
      await pump(tester, null);
      // 拿不到数据就说「完整」，等于把最坏情况显示成最好情况
      expect(find.text('当前完整度：待补'), findsOneWidget);
      expect(find.text('当前完整度：完整'), findsNothing);
      expect(find.textContaining('三条件满足 0 / 3'), findsOneWidget);
      expect(find.text('· 推荐池权重 ×2 优先展示（当前 ×0.5）'), findsOneWidget);
    });
  });

  group('§5.11 有效期说明放在完成页', () {
    testWidgets('说清 7 天、一键续期、14 天退出推荐但不删除', (tester) async {
      await pump(tester, yellow());
      // 发布页那一行是「将挂多久」；用户真正需要记住「7 天后会来问你」的
      // 时刻是刚发完
      expect(find.textContaining('有效期 7 天'), findsOneWidget);
      expect(find.textContaining('这条还在吗'), findsOneWidget);
      expect(find.textContaining('14 天没刷新'), findsOneWidget);
      expect(find.textContaining('不会删除'), findsOneWidget);
    });
  });

  group('后续动作出口', () {
    testWidgets('两个出口都在场且可点', (tester) async {
      await pump(tester, yellow());
      final home = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '去首页看效果'),
      );
      expect(home.onPressed, isNotNull);
      final mine = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '去「我的」'),
      );
      expect(mine.onPressed, isNotNull);
    });
  });
}
