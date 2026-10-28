/// 我的发布页 widget 测试（[127] 前端段 + [B2-8] 依赖项转真）。
///
/// 覆盖：四页签与卡片要件（标题/价格/状态标/操作组/分页终态）、已接通动作调真接口、
/// **编辑 / 克隆重发 / 页内搜索 / 本地草稿**（[B2-8] 转真）、仍降级的删除动作
/// （不留点了没反应的死按钮）、空态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/features/post/my_publish_screen.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';
import 'package:zhaoyazhao/features/publish/draft_store.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';
import 'package:zhaoyazhao/router/app_router.dart';

import '../../support/fake_repositories.dart';
import '../../support/post_fixtures.dart';

/// 取页面上所有富文本副标题的纯文本（图标以 WidgetSpan 占位符出现）。
///
/// 参数：[tester] 测试器。
/// 返回：[List<String>] 各富文本的 plain text。
List<String> _subtitleTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .where((text) => text.textSpan != null)
    .map((text) => text.textSpan!.toPlainText())
    .toList();

/// 取 `myPostsPayload()` 的第 [index] 条列表项（可变副本）。
///
/// 参数：[index] 条目下标。
/// 返回：[Map] 列表项 payload。
Map<String, Object?> _itemOf(int index) => {
  ...(((myPostsPayload()['items'] as List<Object?>)[index])
      as Map<String, Object?>),
};

/// 用给定列表项构造 `GET /posts/mine` 响应 DTO。
///
/// 参数：[items] 列表项 payload。
/// 返回：[MyPostsPageDto]。
MyPostsPageDto _pageOf(List<Map<String, Object?>> items) =>
    MyPostsPageDto.fromJson({
      ...myPostsPayload(),
      'items': items,
      'total': items.length,
    });

void main() {
  late FakePostRepository repo;

  setUp(() {
    repo = FakePostRepository();
    // 本地草稿存储走 SharedPreferences（真实现，内存 mock），
    // 与 privacy/category 等既有测试同一纪律。
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  /// 带真实路由的壳：编辑/重发/继续编辑都会 `context.push` 到发布页，
  /// 故这些用例必须挂在 GoRouter 下（发布页用占位 widget 取代）。
  ///
  /// 返回：[GoRouter]。
  GoRouter buildRouter() => GoRouter(
    initialLocation: AppRoutes.myPublish,
    routes: [
      GoRoute(
        path: AppRoutes.myPublish,
        builder: (_, _) => const MyPublishScreen(),
      ),
      GoRoute(
        path: AppRoutes.publish,
        builder: (_, _) => const Scaffold(body: Text('发布页占位')),
      ),
      GoRoute(
        path: AppRoutes.home,
        builder: (_, _) => const Scaffold(body: Text('首页占位')),
      ),
    ],
  );

  /// 渲染页面（注入假仓库，不依赖真实网络）。
  ///
  /// 参数：[tester] 测试器；[router] 需要真路由（编辑/重发用例）时传入。
  /// 返回：[Future<void>] 首屏数据已落地。
  Future<void> pumpScreen(WidgetTester tester, {GoRouter? router}) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [postRepositoryProvider.overrideWithValue(repo)],
        child: router == null
            ? const MaterialApp(home: MyPublishScreen())
            : MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('四页签与卡片要件齐备（标题/价格/状态标/操作组/分页终态）',
      (tester) async {
    await pumpScreen(tester);

    for (final label in ['全部', '在架', '已下架', '草稿']) {
      expect(find.text(label), findsWidgets, reason: '页签「$label」必须在场');
    }
    expect(find.text('九成新实木餐桌转让'), findsOneWidget);
    // 价格与单位同详情页口径（整数去小数尾巴；单位自带「元」不再补前缀）
    expect(find.text('299 元'), findsOneWidget);
    // 无价格显示「面议」而非留空
    expect(find.text('面议'), findsOneWidget);
    // 操作组随状态变化（设计稿规格：在架 → 编辑/下架；已下架 → 刷新重发/删除）
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('下架'), findsOneWidget);
    expect(find.text('刷新重发'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    // 分页终态（设计稿 listEndRow）
    expect(find.text('没有更多了'), findsOneWidget);
  });

  testWidgets('卡片分类块用二级字形（40101 → 401「二手闲置转让」= inventory_2）',
      (tester) async {
    await pumpScreen(tester);

    // 一级「生活」是 volunteer_activism；二级 401 才是 inventory_2。
    // 断言后者在场即可证明卡片读的是二级图标（与地图 Pin / 列表卡同一份映射）。
    expect(find.byIcon(Icons.inventory_2), findsWidgets);
  });

  testWidgets('点「下架」：调真接口并带列表项的乐观锁版本号', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('下架'));
    await tester.pumpAndSettle();

    expect(repo.lastChangePostId, 1001);
    expect(repo.lastChangeAction, 'offline');
    expect(repo.lastChangeVersion, 1);
    expect(find.text('已下架'), findsWidgets);
  });

  testWidgets('点「编辑」：先取详情再进发布页编辑态（不再降级提示）', (tester) async {
    await pumpScreen(tester, router: buildRouter());

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(repo.lastDetailPostId, 1001, reason: '编辑态需要全量字段，须先取详情');
    expect(find.text('发布页占位'), findsOneWidget, reason: '应进入发布页编辑态');
    expect(find.textContaining('本期内测版暂未开放'), findsNothing);
  });

  testWidgets('点「刷新重发」：调 repost 取克隆草稿进发布页（新建语义）', (tester) async {
    await pumpScreen(tester, router: buildRouter());

    await tester.tap(find.text('刷新重发'));
    await tester.pumpAndSettle();

    expect(repo.lastRepostPostId, 1002, reason: '刷新重发须打 repost 而非 PATCH status');
    expect(repo.lastChangePostId, isNull, reason: '重发不得走状态变更');
    expect(find.text('发布页占位'), findsOneWidget);
  });

  testWidgets('点「删除」：仍为降级提示（[B2-8] 裁定本轮不做删除端点）',
      (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.textContaining('删除功能本期内测版暂未开放'), findsOneWidget);
  });

  testWidgets('切「草稿」页签：无本地草稿时显示空态且不发请求', (tester) async {
    await pumpScreen(tester);
    final before = repo.mineFetchCount;

    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    expect(find.text('还没有草稿'), findsOneWidget);
    expect(repo.mineFetchCount, before, reason: '草稿页签数据源是本地，不应发请求');
  });

  testWidgets('草稿页签：有本地草稿时渲染卡片，「继续编辑」进发布页', (tester) async {
    await const DraftStore().save(
      DraftSnapshot.of(
        const PublishFormState(title: '本地草稿标题', contact: '13800138000'),
      ),
    );

    await pumpScreen(tester, router: buildRouter());
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    expect(find.text('本地草稿标题'), findsOneWidget);
    expect(find.text('继续编辑'), findsOneWidget);

    await tester.tap(find.text('继续编辑'));
    await tester.pumpAndSettle();
    expect(find.text('发布页占位'), findsOneWidget);
  });

  testWidgets('草稿页签：「删除」真实清掉本地草稿', (tester) async {
    await const DraftStore().save(
      DraftSnapshot.of(const PublishFormState(title: '待删除草稿')),
    );

    await pumpScreen(tester, router: buildRouter());
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();
    expect(find.text('待删除草稿'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('待删除草稿'), findsNothing);
    expect(find.text('还没有草稿'), findsOneWidget);
  });

  testWidgets('空列表：显示引导空态（不仅是一句「暂无数据」）', (tester) async {
    repo.mineToReturn = MyPostsPageDto.fromJson({
      ...myPostsPayload(),
      'items': <Object?>[],
      'total': 0,
    });

    await pumpScreen(tester);

    expect(find.text('还没发布，立即发一条'), findsOneWidget);
    expect(find.text('去发布'), findsOneWidget);
  });

  testWidgets('点顶部「搜索」：页内本地筛选（不发请求，无匹配给可解释空态）',
      (tester) async {
    await pumpScreen(tester);
    final before = repo.mineFetchCount;

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '不存在的关键词');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle();

    expect(find.textContaining('没有匹配'), findsOneWidget);
    expect(repo.mineFetchCount, before, reason: '本地筛选不得发请求');
  });

  testWidgets('非草稿卡片：浏览 42 与收藏 3 以图标 + 数字出现（R7）',
      (tester) async {
    await pumpScreen(tester);

    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    // 1001 收藏 3、1002 收藏 0：两张卡都给星标。
    expect(find.byIcon(Icons.star_border), findsNWidgets(2));
    final subtitles = _subtitleTexts(tester);
    expect(
      subtitles.any((text) => text.contains('42') && text.contains('3')),
      isTrue,
      reason: '实收：$subtitles',
    );
  });

  testWidgets('浏览为 null：只出现收藏组（防御分支，不渲染成 0）',
      (tester) async {
    repo.mineToReturn = _pageOf([_itemOf(1)]);
    await pumpScreen(tester);

    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    expect(
      _subtitleTexts(tester).any((text) => text.contains(' 0')),
      isTrue,
      reason: '收藏 0 要显示「星形图标 + 0」',
    );
  });

  testWidgets('已下架卡片：与在架卡同样显示计数（R9 三页签一致）',
      (tester) async {
    repo.mineToReturn = _pageOf([
      {..._itemOf(1), 'view_count': 20, 'favorite_count': 5},
    ]);
    await pumpScreen(tester);

    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    expect(find.byIcon(Icons.star_border), findsOneWidget);
    final subtitles = _subtitleTexts(tester);
    expect(
      subtitles.any((text) => text.contains('20') && text.contains('5')),
      isTrue,
      reason: '实收：$subtitles',
    );
  });

  testWidgets('草稿卡片：不出现浏览/收藏计数', (tester) async {
    await const DraftStore().save(
      DraftSnapshot.of(const PublishFormState(title: '无计数的草稿')),
    );

    await pumpScreen(tester);
    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    expect(find.text('无计数的草稿'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
    expect(find.byIcon(Icons.star_border), findsNothing);
  });

  testWidgets('超长计数：副标题单行省略，不撑高卡片', (tester) async {
    repo.mineToReturn = _pageOf([
      {..._itemOf(0), 'view_count': 1234567890123, 'favorite_count': 987654321},
    ]);
    await pumpScreen(tester);

    final subtitle = tester
        .widgetList<Text>(find.byType(Text))
        .firstWhere((text) => text.textSpan != null);
    expect(subtitle.maxLines, 1);
    expect(subtitle.overflow, TextOverflow.ellipsis);
  });
}
