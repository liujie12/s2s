/// 发布提交链 precheck 接线测试（[124]/[125] 前端段 / B4）。
///
/// 断言 `_submit` 的服务端前置校验三形态（repository 契约断言在
/// post_repository_test.dart，本文件不重复）：
///   - 通过：precheck 载荷按 `postDraftPayload` 映射发出，成功跳完成页
///     （`POST /posts` 为 B5，当前占位跳转是既定行为）；
///   - 阻断：底部弹层一次性列全 blocks（message 逐字取服务端值），
///     40302/40304 带动作入口；
///   - 链路失败：SnackBar 按 §11.4 唯一格式，不跳完成页。
///
/// 走真 GoRouter（成功跳转是被测行为，MaterialApp 不带路由无法断言）；
/// category/post 两仓库均用共享 fake（support/fake_repositories.dart，
/// 纯微任务不走真 IO）——模板侧 fake 让 B3 闸门（templatePending）就位，
/// 提交按钮才能进 precheck 分支。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/category/category_repository.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';
import 'package:zhaoyazhao/features/publish/publish_screen.dart';

import '../../support/fake_repositories.dart';
import '../../support/post_fixtures.dart';

void main() {
  late FakeCategoryRepository categoryRepo;
  late FakePostRepository postRepo;

  setUp(() {
    categoryRepo = FakeCategoryRepository();
    postRepo = FakePostRepository();
  });

  /// 一份可提交的表单（叶子 40101 无资质要求，跳过本地资质拦截直达
  /// precheck）。templateValues 两键都填：headcount 是 fake fetchTemplate
  /// 恒返字段集（10101 默认）的必填项，condition 是本地 40101 模板的
  /// 必填项——loadedTemplate 就位后按服务端字段集校验，headcount 不填
  /// 会被 blocker 拦住进不了 precheck 分支。
  PublishFormState submittable() {
    return const PublishFormState(
      leafCategoryId: 40101,
      hasLocation: true,
      title: '九成新实木餐桌转让',
      priceUnit: '元',
      priceText: '350',
      description: '搬家出售，购入一年，无磕碰，可上门自取。',
      templateValues: {'headcount': '3', 'condition': '几乎全新'},
      contact: '13800138000',
      agreed: true,
    );
  }

  /// 组装带真 GoRouter 的发布页（成功页/认证中心挂占位 Text 供断言）。
  ///
  /// 参数 [form] 初始表单。
  /// 返回：待 pump 的 [Widget]。
  Widget app(PublishFormState form) {
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => PublishScreen(initialForm: form)),
        GoRoute(
          path: '/publish/success',
          builder: (_, _) => const Scaffold(body: Text('成功页占位')),
        ),
        GoRoute(
          path: '/trust',
          builder: (_, _) => const Scaffold(body: Text('认证中心占位')),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        isLoggedInProvider.overrideWithValue(true),
        categoryRepositoryProvider.overrideWithValue(categoryRepo),
        postRepositoryProvider.overrideWithValue(postRepo),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  /// 加高视口 + 组装 + 等模板就位（fake fetchTemplate 纯微任务，
  /// pumpAndSettle 推进后 templatePending 解除、提交按钮可点）。
  Future<void> pumpReady(WidgetTester tester, PublishFormState form) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(form));
    await tester.pumpAndSettle();
  }

  /// 点底部主按钮并等弹层/跳转稳定。
  Future<void> tapSubmit(WidgetTester tester) async {
    await tester.tap(find.text('同意协议并发布'));
    await tester.pumpAndSettle();
  }

  testWidgets('通过：载荷按 postDraftPayload 映射发出，成功跳完成页',
      (tester) async {
    await pumpReady(tester, submittable());
    await tapSubmit(tester);

    // 表单映射：type/leaf/title/contact_value 透传，派生字段未夹带
    expect(postRepo.lastDraft, isNotNull);
    expect(postRepo.lastDraft!['type'], 'resource');
    expect(postRepo.lastDraft!['leaf_category_id'], 40101);
    expect(postRepo.lastDraft!['title'], '九成新实木餐桌转让');
    expect(postRepo.lastDraft!['contact_value'], '13800138000');
    expect(postRepo.lastDraft!.containsKey('l2_category_id'), isFalse);
    expect(postRepo.lastDraft!.containsKey('grid_id'), isFalse);
    // 占位跳转（B5 换 POST /posts 前的既定行为）
    expect(find.text('成功页占位'), findsOneWidget);
  });

  testWidgets('阻断：blocks 一次性列全，message 逐字取服务端值，两码带动作'
      '入口', (tester) async {
    postRepo.resultToReturn = PrecheckResultDto.fromJson(
      precheckBlockedPayload(),
    );

    await pumpReady(tester, submittable());
    await tapSubmit(tester);

    expect(find.text('发布前需处理以下问题'), findsOneWidget);
    // 五码 message 全部出现（一次性给全，不逐条弹）
    expect(find.text('包含敏感词：xxx，请修改'), findsOneWidget);
    expect(find.text('该图未通过审核，无法发布'), findsOneWidget);
    expect(find.text('此类信息平台禁止发布'), findsOneWidget);
    expect(find.text('高敏类目未认证，禁止发布'), findsOneWidget);
    expect(find.text('未实名发布已达上限'), findsOneWidget);
    // 两码有动作入口
    expect(find.text('去认证'), findsOneWidget);
    expect(find.text('去实名'), findsOneWidget);
    // 未跳完成页
    expect(find.text('成功页占位'), findsNothing);

    // 动作入口：关弹层跳认证中心
    await tester.tap(find.text('去实名'));
    await tester.pumpAndSettle();
    expect(find.text('认证中心占位'), findsOneWidget);
  });

  testWidgets('链路失败：SnackBar 按 §11.4 唯一格式，不跳完成页',
      (tester) async {
    postRepo.errorToThrow = const ApiException(
      code: ApiErrorCode.networkFailure,
      message: '网络连接失败，请检查网络后重试',
      requestId: 'req_abc123',
    );

    await pumpReady(tester, submittable());
    await tapSubmit(tester);

    expect(
      find.text('网络连接失败，请检查网络后重试（req_abc123）'),
      findsOneWidget,
    );
    expect(find.text('成功页占位'), findsNothing);
  });
}
