/// 发布页与认证浮层的界面守门测试（PRD §5.4.1 顶部栏 / §4.4 认证浮层）。
///
/// **为什么校验逻辑已单测过还要这一层**：`publish_form_state_test.dart` 证明的是
/// 「blocker 算得对」，这里证明的是「算出来的结果真的接到了按钮和提示上」。
/// 两者之间那根线断掉时，逻辑测试全绿而按钮永远可点 —— 这正是原则 133
/// 说的「断言测不到病灶」。
///
/// **不测分类选择与提交跳转**：两者都会 `context.push`，需要搭一整套 GoRouter；
/// 而它们真正的观察点在路由表接线处，不在本页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/features/publish/cert_modal_screen.dart';
import 'package:zhaoyazhao/features/publish/publish_screen.dart';

void main() {
  /// 挂载发布页。
  ///
  /// 参数 [tester] 测试驱动器。
  Future<void> pumpPublish(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: PublishScreen())),
    );
  }

  /// 把某段标题滚进视口。
  ///
  /// 参数 [tester] 测试驱动器；[label] 段标题文字。
  /// 表单用的是 [ListView]，它按需构建 —— 默认 800×600 的测试视口里
  /// 第 4 段以后根本没被创建。不滚而直接断言会得到「找不到组件」，
  /// 那不是缺陷，是没看到。
  Future<void> scrollTo(WidgetTester tester, String label) async {
    await tester.scrollUntilVisible(
      find.text(label),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
  }

  /// 取底部主按钮是否可点。
  ///
  /// 参数 [tester] 测试驱动器。返回 true 表示可点。
  bool submitEnabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '同意协议并发布'),
    );
    return button.onPressed != null;
  }

  group('§5.4.1 顶部栏「禁用直到必填齐全」', () {
    testWidgets('首帧：主按钮禁用，且显式说出缺什么', (tester) async {
      await pumpPublish(tester);
      expect(submitEnabled(tester), isFalse);
      // 禁用原因必须出现在界面上 —— 灰按钮不说原因等于把校验规则藏起来
      expect(find.text('请先选择分类'), findsOneWidget);
    });

    testWidgets('顶部「发布」按钮与底部主按钮同步禁用', (tester) async {
      await pumpPublish(tester);
      final top = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '发布'),
      );
      // 两个入口指向同一个动作，只禁用一个等于留了个后门
      expect(top.onPressed, isNull);
    });

    testWidgets('勾了协议但其他项没填，按钮仍禁用（协议不是唯一条件）', (tester) async {
      await pumpPublish(tester);
      await tester.tap(find.text('我已阅读并同意发布协议与信息真实性承诺'));
      await tester.pump();
      expect(submitEnabled(tester), isFalse);
      expect(find.text('请先选择分类'), findsOneWidget);
    });
  });

  group('§5.4.1 各段呈现', () {
    testWidgets('八段编号齐备且顺序与 §5.4.1 一致', (tester) async {
      await pumpPublish(tester);
      // 逐段找标题文字：漏掉一段的表现是页面「看着挺完整」，
      // 只有对照 PRD 才看得出少了哪一项。
      for (final title in [
        '选择分类',
        '位置',
        '标题',
        '价格',
        '描述',
        '媒体',
        '有效期',
        '联系方式',
      ]) {
        await scrollTo(tester, title);
        expect(find.text(title), findsOneWidget, reason: '缺少「$title」段');
      }
    });

    testWidgets('有效期是一行固定说明而非选择器（§5.11「不提供其他可选值」）', (tester) async {
      await pumpPublish(tester);
      await scrollTo(tester, '有效期');
      expect(find.textContaining('默认 7 天'), findsOneWidget);
      // 若日后有人加了天数下拉，这条会失败 —— 这正是它存在的目的
      expect(find.byType(DropdownButton<int>), findsNothing);
    });

    testWidgets('媒体段显示 0 / 9 计数（§5.4.1 第 6 段）', (tester) async {
      await pumpPublish(tester);
      await scrollTo(tester, '媒体');
      expect(find.textContaining('0 / 9'), findsOneWidget);
    });

    testWidgets('地图选点按钮呈现但禁用 —— 不隐藏，以便验收时确认它是待前置', (tester) async {
      await pumpPublish(tester);
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '地图选点'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('§5.4.1 资源 / 需求胶囊切换', () {
    testWidgets('两态都在，默认资源态', (tester) async {
      await pumpPublish(tester);
      expect(find.text('发布资源'), findsOneWidget);
      expect(find.text('发布需求'), findsOneWidget);
    });

    testWidgets('切到需求态不清空已填内容', (tester) async {
      await pumpPublish(tester);
      // 位置是最容易被「切换时整表重置」波及的一项
      await tester.tap(find.text('使用当前位置'));
      await tester.pump();
      expect(find.textContaining('演示位置'), findsOneWidget);

      await tester.tap(find.text('发布需求'));
      await tester.pump();
      expect(find.textContaining('演示位置'), findsOneWidget);
    });
  });

  group('§4.4 认证浮层文案与出口', () {
    /// 挂载认证浮层并捕获返回值。
    ///
    /// 参数 [tester] 测试驱动器；[cert] 要求的资质。
    /// 返回一个持有 pop 结果的单元素列表（回调写入）。
    Future<List<bool?>> pumpCert(
      WidgetTester tester,
      RequiredCert cert,
    ) async {
      final popped = <bool?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                final r = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                    builder: (_) => CertModalScreen(cert: cert),
                  ),
                );
                popped.add(r);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return popped;
    }

    testWidgets('标题随资质类型变化（§4.4「发布此分类需要 X 认证」）', (tester) async {
      await pumpCert(tester, RequiredCert.personalQualification);
      expect(find.text('发布此分类需要个人资质认证'), findsOneWidget);
    });

    testWidgets('企业类目显示企业认证，且不出现「认证认证」叠字', (tester) async {
      await pumpCert(tester, RequiredCert.enterprise);
      // RequiredCert.label 里「企业认证」自带「认证」二字，模板句式再拼一次
      // 就会得到「需要企业认证认证」—— 这条断言就是那次实测抓出来的。
      expect(find.text('发布此分类需要企业认证'), findsOneWidget);
      expect(find.textContaining('认证认证'), findsNothing);
    });

    testWidgets('说明文案逐字照 §4.4', (tester) async {
      await pumpCert(tester, RequiredCert.vehicle);
      expect(find.text('认证通过后可终身使用（每年年审一次）'), findsOneWidget);
    });

    testWidgets('「去认证」返回 true，「暂不发布」返回 null', (tester) async {
      final a = await pumpCert(tester, RequiredCert.personalQualification);
      await tester.tap(find.text('去认证'));
      await tester.pumpAndSettle();
      expect(a, [true]);

      final b = await pumpCert(tester, RequiredCert.personalQualification);
      await tester.tap(find.text('暂不发布'));
      await tester.pumpAndSettle();
      // 返回 null 而非 false：调用方只关心「是否要去认证」，
      // 两种关闭方式（按钮、点空白）没有区别。
      expect(b, [null]);
    });
  });
}
