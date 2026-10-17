/// AI 确认页界面守门测试（PRD §5.9 五态表 / §9.8 冲刺区与实时跳档）。
///
/// **为什么逻辑已单测过还要这一层**：`ai_guess_builder_test.dart` 证明「猜得对」，
/// `publish_completeness_test.dart` 证明「档位算得对」，这里证明的是
/// 「服务端返回的猜测真接到了角标、按钮和冲刺区上」。那根线断掉时前两层全绿，
/// 而页面上「确认发布」永远可点、或补了门牌号档位不动 —— 原则 133 的病灶。
///
/// **B2-4 接真后**：本页进页面即调 `POST /ai/publish/parse`，故注入 [FakeAiRepository]；
/// 断言改为对「服务端返回结果 → UI」这条线守门（不再依赖本地 `buildLocalGuess`）。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/ai/ai_dto.dart';
import 'package:zhaoyazhao/features/ai/ai_repository.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';
import 'package:zhaoyazhao/features/publish/ai_confirm_args.dart';
import 'package:zhaoyazhao/features/publish/ai_confirm_screen.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';

import 'support/fake_repositories.dart';
import 'support/post_fixtures.dart';

void main() {
  /// 一份填齐必填项的表单（二手闲置，缺门牌号 → 🟡 档）。
  PublishFormState complete() => const PublishFormState(
    leafCategoryId: 40101,
    lng: 120.1551,
    lat: 30.2741,
    title: '九成新实木餐桌',
    priceText: '350',
    priceUnit: '元',
    description: '搬家出售，无磕碰，可上门自取。',
    templateValues: {'condition': '几乎全新', 'pickup': '仅自取'},
    contact: '13800138000',
    agreed: true,
  );

  /// 服务端「全猜出」返回（对应 complete() 表单）。
  AiParseResultDto fullResult() => const AiParseResultDto(
    guess: AiGuessDto(
      title: '九成新实木餐桌',
      leafCategoryId: 40101,
      price: 350,
      priceUnit: '元',
      templateValues: {'condition': '几乎全新', 'pickup': '仅自取'},
    ),
    scopeVerified: {
      'leaf_category_id': 'user_input',
      'title': 'user_input',
      'price': 'user_input',
      'condition': 'user_input',
      'pickup': 'user_input',
    },
    unresolvedFields: <String>[],
  );

  /// 挂载确认页（注入假 ai 仓库）。
  ///
  /// 参数 [tester] 测试驱动器，[form] 传入的表单快照。
  ///
  /// **为什么要放大视口**：默认 800×600 里，冲刺区与配额说明都在折叠线以下，
  /// 而它们所在的 [ListView] 按需构建 —— 不放大就得到「找不到组件」，
  /// 那不是缺陷，是没看到。**为什么 pumpAndSettle**：进页面即异步解析，
  /// 不停到稳态就断言会停在 parsing 态。
  Future<FakeAiRepository> pump(
    WidgetTester tester,
    PublishFormState form,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final ai = FakeAiRepository();
    // 空表单（未选分类且无标题文本）→ 服务端返回「全未猜出」；
    // 其余（有分类/有标题）→ 返回「全猜出」。
    if (form.leafCategoryId != null || form.title.trim().isNotEmpty) {
      ai.resultToReturn = fullResult();
    }
    await tester.pumpWidget(
      ProviderScope(
        overrides: [aiRepositoryProvider.overrideWithValue(ai)],
        child: MaterialApp(home: AiConfirmScreen(args: AiConfirmArgs(form: form))),
      ),
    );
    await tester.pumpAndSettle();
    return ai;
  }

  /// 取底部「确认发布」是否可点。
  bool confirmEnabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '确认发布'),
    );
    return button.onPressed != null;
  }

  group('§5.9 结果待确认态', () {
    testWidgets('进页面即调服务端解析一次（接真守门）', (tester) async {
      final ai = await pump(tester, complete());
      expect(ai.parseCount, 1);
      // 请求带上了标题文本与已选类目
      expect(ai.lastRequest?.text, '九成新实木餐桌');
      expect(ai.lastRequest?.leafCategoryId, 40101);
    });

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

    testWidgets('展示「AI 辅助生成」内容标识（§5.9 合规裁定）', (tester) async {
      await pump(tester, complete());
      expect(find.textContaining('AI 辅助生成'), findsOneWidget);
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

  group('§5.9 解析失败态', () {
    testWidgets('服务端解析失败 → 失败态，保留「已填内容还在」并给重试入口', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ai = FakeAiRepository()..errorToThrow = Exception('upstream down');
      await tester.pumpWidget(
        ProviderScope(
          overrides: [aiRepositoryProvider.overrideWithValue(ai)],
          child: MaterialApp(
            home: AiConfirmScreen(args: AiConfirmArgs(form: complete())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('识别没成功'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
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
      // TextField 顺序：0 = 「说一句」输入，1 = 冲刺区门牌号（B2-4 新增了前者）
      await tester.enterText(find.byType(TextField).at(1), '3 号楼 2 单元 501');
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
    testWidgets('未取到配额快照时按常量档展示上限，且不含「剩余」', (tester) async {
      await pump(tester, complete());
      // 未登录 → 未实名 → 3 次
      expect(find.textContaining('你当前每日 AI 额度 3 次'), findsOneWidget);
      expect(find.textContaining('未实名'), findsOneWidget);
      expect(find.textContaining('剩余'), findsNothing);
    });

    testWidgets('取到服务端配额快照时展示已用/上限', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ai = FakeAiRepository()
        ..resultToReturn = AiParseResultDto(
          guess: fullResult().guess,
          scopeVerified: fullResult().scopeVerified,
          unresolvedFields: const <String>[],
          quota: AiQuotaDto(used: 2, limit: 20, resetAt: DateTime(2026, 1, 2)),
        );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [aiRepositoryProvider.overrideWithValue(ai)],
          child: MaterialApp(
            home: AiConfirmScreen(args: AiConfirmArgs(form: complete())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('今日 AI 额度已用 2 / 20 次'), findsOneWidget);
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

  group('§5.9 抢发模式（④）', () {
    testWidgets('未补齐必填也可发布，提示为 24h 补全口径', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      // 空猜测 → 分类/标题/价格全「需你补充」，常规模式本应禁用主按钮。
      final ai = FakeAiRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [aiRepositoryProvider.overrideWithValue(ai)],
          child: MaterialApp(
            home: AiConfirmScreen(
              args: AiConfirmArgs(
                form: const PublishFormState(),
                flashMode: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 抢发是「先发占位」——未补齐也允许发布（§5.9 模式④）
      expect(confirmEnabled(tester), isTrue);
      expect(find.textContaining('24 小时内补全'), findsWidgets);
      expect(find.text('还有字段标着「需你补充」，补完才能发布'), findsNothing);
    });
  });

  group('B2-4 发布载荷（真机 400 回归守门）', () {
    testWidgets('AI 猜测必须进载荷 —— 只写展示层会让 POST /posts 400', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ai = FakeAiRepository()..resultToReturn = fullResult();
      final postRepo = FakePostRepository();
      // 成功后本页会 push 成功页，而本用例没有 GoRouter；让 createPost 抛业务错
      // 停在原页即可 —— 载荷在抛错前已记录（lastCreateDraft）。
      postRepo.createErrorToThrow = const ApiException(
        code: ApiErrorCode.paramInvalid,
        message: '测试用阻断',
        requestId: 'req_test',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiRepositoryProvider.overrideWithValue(ai),
            postRepositoryProvider.overrideWithValue(postRepo),
          ],
          child: MaterialApp(
            home: AiConfirmScreen(
              // 模拟 AI 快速入口：位置与联系方式由确认页补，其余靠 AI 猜测。
              args: const AiConfirmArgs(
                form: PublishFormState(
                  lng: 120.1551,
                  lat: 30.2741,
                  contact: '13800138000',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      final draft = postRepo.lastCreateDraft;
      expect(draft, isNotNull);
      expect(draft!['title'], '九成新实木餐桌');
      expect(draft['leaf_category_id'], 40101);
      // 价格此前完全不上送（帖子落库无价），这条守的是跨层漏字段。
      expect(draft['price'], 350);
      expect(draft['price_unit'], '元');
      // 契约必填的位置与联系方式
      expect(draft['lng'], 120.1551);
      expect(draft['lat'], 30.2741);
      expect(draft['contact_value'], '13800138000');
      expect(draft['ai_assisted'], isTrue);
      // 模板字段同样来自猜测，不能丢
      expect((draft['attributes'] as Map)['condition'], '几乎全新');
    });

    testWidgets('发布成功 → 弹「发布成功」并进入成功页（不能停在确认页）',
        (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ai = FakeAiRepository()..resultToReturn = fullResult();
      final postRepo = FakePostRepository();
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const AiConfirmScreen(
              args: AiConfirmArgs(
                form: PublishFormState(
                  leafCategoryId: 40101,
                  lng: 120.1551,
                  lat: 30.2741,
                  title: '九成新实木餐桌',
                  priceText: '350',
                  priceUnit: '元',
                  description: '搬家出售，无磕碰，可上门自取。',
                  templateValues: {'condition': '几乎全新', 'pickup': '仅自取'},
                  contact: '13800138000',
                  agreed: true,
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/publish/success',
            builder: (_, _) => const Scaffold(body: Text('成功页占位')),
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiRepositoryProvider.overrideWithValue(ai),
            postRepositoryProvider.overrideWithValue(postRepo),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      // 成功页必须在栈顶：用户要知道「发布成功了」，而不是停在一个可再点的页面
      expect(find.text('成功页占位'), findsOneWidget);
      expect(find.text('发布成功'), findsOneWidget);
    });

    testWidgets('precheck 阻断 → 弹出可读问题列表（不能一闪而过）', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ai = FakeAiRepository()..resultToReturn = fullResult();
      final postRepo = FakePostRepository()
        ..resultToReturn = PrecheckResultDto.fromJson(precheckBlockedPayload());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiRepositoryProvider.overrideWithValue(ai),
            postRepositoryProvider.overrideWithValue(postRepo),
          ],
          child: MaterialApp(
            home: AiConfirmScreen(
              args: const AiConfirmArgs(
                form: PublishFormState(
                  leafCategoryId: 40101,
                  lng: 120.1551,
                  lat: 30.2741,
                  title: '九成新实木餐桌',
                  priceText: '350',
                  priceUnit: '元',
                  description: '搬家出售，无磕碰，可上门自取。',
                  templateValues: {'condition': '几乎全新', 'pickup': '仅自取'},
                  contact: '13800138000',
                  agreed: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      // 模态弹层：标题 + 服务端原文，必须点「知道了」才关
      expect(find.text('发布前需处理以下问题'), findsOneWidget);
      expect(find.text('包含敏感词：xxx，请修改'), findsOneWidget);
      expect(find.text('知道了'), findsOneWidget);
      // 阻断时不能落库
      expect(postRepo.createCount, 0);
    });

    testWidgets('DioException 包裹的 ApiException → 弹窗显示服务端原文', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final ai = FakeAiRepository()..resultToReturn = fullResult();
      // 拦截器链的真实形态：ApiException 被包进 DioException(type: unknown)
      final postRepo = FakePostRepository()
        ..errorToThrow = DioException(
          requestOptions: RequestOptions(path: '/posts/precheck'),
          type: DioExceptionType.unknown,
          error: const ApiException(
            code: ApiErrorCode.paramInvalid,
            message: '未实名用户发布数量已达上限',
            requestId: 'req_x',
          ),
        );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            aiRepositoryProvider.overrideWithValue(ai),
            postRepositoryProvider.overrideWithValue(postRepo),
          ],
          child: MaterialApp(
            home: AiConfirmScreen(
              args: const AiConfirmArgs(
                form: PublishFormState(
                  leafCategoryId: 40101,
                  lng: 120.1551,
                  lat: 30.2741,
                  title: '九成新实木餐桌',
                  priceText: '350',
                  priceUnit: '元',
                  description: '搬家出售，无磕碰，可上门自取。',
                  templateValues: {'condition': '几乎全新', 'pickup': '仅自取'},
                  contact: '13800138000',
                  agreed: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('确认发布'));
      await tester.pumpAndSettle();

      // 必须解出内层 ApiException 的原文，不能退化成通用兜底文案
      expect(find.text('发布未完成'), findsOneWidget);
      expect(find.textContaining('未实名用户发布数量已达上限'), findsOneWidget);
    });
  });
}
