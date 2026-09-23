/// 发布页模板接线 widget 测试（[124] 前端段 / B3）。
///
/// 断言页面层的三条 B3 行为（provider 网络链断言在
/// publish_template_provider_test.dart，本文件不重复）：
///   - 模板加载中：骨架段 + 主按钮禁用 + 「模板加载中…」（异步闸门由页面
///     合成，不进 [PublishFormState.blocker] 同步链）；
///   - 服务端模板到达：字段整体替换为服务端集合，必填校验按服务端口径；
///   - 拉取失败：降级本地模板字段，页面照常可填。
///
/// 用 [_FakeCategoryRepository] 走微任务（fake async 下 pumpAndSettle 可
/// 推进），不走真 IO；`initialForm` 测试缝预填表单，避免拉起 GoRouter +
/// 级联选择器全链路。
///
/// **为什么视口加高而不是 scrollUntilVisible**：发布页是懒构建 ListView，
/// 模板段在首屏下方，不滚动不构建；但滚动本身会推进帧与微任务，provider
/// 在滚动途中就 resolve，「骨架首帧」断言变得不确定。加高视口让全部
/// 子节点首帧即构建，加载中/已加载两态都可稳定断言。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/category/category_repository.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';
import 'package:zhaoyazhao/features/publish/publish_screen.dart';

import '../../support/fake_repositories.dart';

/// 假 category 仓库（共享替身，见 support/fake_repositories.dart）：
/// 本文件用其 fetchTemplate 的正常/失败两态。
typedef _FakeCategoryRepository = FakeCategoryRepository;

void main() {
  late _FakeCategoryRepository repo;

  setUp(() {
    repo = _FakeCategoryRepository();
  });

  /// 加高测试视口使长表单全部子节点首帧即构建（理由见文件头）。
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  /// 除模板必填项外全部填妥的表单（叶子 10101 全职招聘）。
  ///
  /// 模板字段留空：用例正是要观察「模板加载中 → 服务端必填未填」的
  /// blocker 迁移。文本控制器从空串起步不影响本文件断言 —— blocker
  /// 读状态不读控制器（initialForm 缝的已知边界）。
  PublishFormState filledExceptTemplate() {
    return const PublishFormState(
      leafCategoryId: 10101,
      hasLocation: true,
      title: '火锅店招服务员',
      priceUnit: '面议',
      description: '包吃包住，月休四天，详情面议。',
      contact: '13800138000',
      agreed: true,
    );
  }

  /// 组装发布页（仅注入假仓库；页面 build 路径不触 GoRouter/鉴权 provider）。
  ///
  /// 参数 [form] 初始表单快照。
  /// 返回：待 pump 的 [Widget]。
  Widget app(PublishFormState form) {
    return ProviderScope(
      overrides: [categoryRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(home: PublishScreen(initialForm: form)),
    );
  }

  /// 主按钮（底部「同意协议并发布」）的 onPressed 是否为空（禁用判据）。
  bool submitDisabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '同意协议并发布'),
    );
    return button.onPressed == null;
  }

  testWidgets('未选分类：不发起模板请求，无模板段，blocker 为先选分类',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(app(const PublishFormState()));
    await tester.pumpAndSettle();

    expect(repo.templateFetchCount, 0);
    expect(find.text('分类专属信息'), findsNothing);
    expect(find.text('模板加载中…'), findsNothing);
    expect(find.text('请先选择分类'), findsOneWidget);
    expect(submitDisabled(tester), isTrue);
  });

  testWidgets('加载中渲染骨架并禁提交；服务端模板到达后字段整体替换',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(app(filledExceptTemplate()));

    // 首帧（微任务未推进，provider 未 resolve）：骨架段 + 异步闸门，
    // 此时服务端字段与本地字段都不渲染
    expect(find.text('模板加载中…'), findsOneWidget);
    expect(find.text('分类专属信息'), findsOneWidget);
    expect(find.text('招聘人数'), findsNothing);
    expect(submitDisabled(tester), isTrue);

    await tester.pumpAndSettle();

    // 服务端字段集到达（fixture：headcount 必填 number + board 选单），
    // 本地 1.1 模板的「工作时间」字段不在服务端集合里，必须消失
    expect(find.text('招聘人数'), findsOneWidget);
    expect(find.text('食宿情况'), findsOneWidget);
    expect(find.text('工作时间'), findsNothing);
    // 服务端 required 口径参与 blocker：headcount 未填 → 必填未齐
    expect(find.text('模板必填项未填完'), findsOneWidget);
    expect(find.text('模板加载中…'), findsNothing);
    expect(submitDisabled(tester), isTrue);
    expect(repo.templateFetchCount, 1);
  });

  testWidgets('拉取失败降级本地模板字段，页面照常渲染可填', (tester) async {
    useTallSurface(tester);
    repo.templateErrorToThrow = const ApiException(
      code: ApiErrorCode.networkFailure,
      message: '网络连接失败，请检查网络后重试',
    );

    await tester.pumpWidget(app(filledExceptTemplate()));
    await tester.pumpAndSettle();

    // 本地 1.1 模板三字段（含服务端 fixture 没有的 work_hours）
    expect(find.text('招聘人数'), findsOneWidget);
    expect(find.text('工作时间'), findsOneWidget);
    expect(find.text('食宿情况'), findsOneWidget);
    expect(find.text('模板加载中…'), findsNothing);
    expect(repo.templateFetchCount, 1);
  });
}
