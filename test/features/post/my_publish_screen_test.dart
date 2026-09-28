/// 我的发布页 widget 测试（[127] 前端段）。
///
/// 覆盖：四页签与卡片要件（标题/价格/状态标/操作组/分页终态）、已接通动作调真接口、
/// 降级动作给明确说明（不留点了没反应的死按钮）、空态与草稿页签降级。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/post/my_publish_screen.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';

import '../../support/fake_repositories.dart';
import '../../support/post_fixtures.dart';

void main() {
  late FakePostRepository repo;

  setUp(() {
    repo = FakePostRepository();
  });

  /// 渲染页面（注入假仓库，不依赖真实网络）。
  ///
  /// 参数：[tester] 测试器。
  /// 返回：[Future<void>] 首屏数据已落地。
  Future<void> pumpScreen(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [postRepositoryProvider.overrideWithValue(repo)],
        child: const MaterialApp(home: MyPublishScreen()),
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
    // 价格与单位同详情页口径（整数去小数尾巴）
    expect(find.text('299 元/元'), findsOneWidget);
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

  testWidgets('点「下架」：调真接口并带列表项的乐观锁版本号', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('下架'));
    await tester.pumpAndSettle();

    expect(repo.lastChangePostId, 1001);
    expect(repo.lastChangeAction, 'offline');
    expect(repo.lastChangeVersion, 1);
    expect(find.text('已下架'), findsWidgets);
  });

  testWidgets('点「编辑」（Batch2 依赖）：给出明确说明而非静默', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();

    expect(find.textContaining('编辑功能本期内测版暂未开放'), findsOneWidget);
    expect(repo.lastChangePostId, isNull, reason: '降级动作不得打到真接口');
  });

  testWidgets('切「草稿」页签：显示降级空态（本地草稿属 Batch2）', (tester) async {
    await pumpScreen(tester);
    final before = repo.mineFetchCount;

    await tester.tap(find.text('草稿'));
    await tester.pumpAndSettle();

    expect(find.text('草稿箱本期内测版暂未开放'), findsOneWidget);
    expect(repo.mineFetchCount, before, reason: '草稿页签无契约筛选值，不应发请求');
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

  testWidgets('点顶部「搜索」（无目标页）：给出明确说明', (tester) async {
    await pumpScreen(tester);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pumpAndSettle();

    expect(find.textContaining('搜索功能本期内测版暂未开放'), findsOneWidget);
  });
}
