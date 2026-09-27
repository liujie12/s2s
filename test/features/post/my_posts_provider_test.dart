/// 「我的发布」列表状态层测试（[127] 前端段）。
///
/// 覆盖三件容易做错的东西：页签 → 契约单值筛选的映射（含草稿页签不发请求）、
/// 分页追加（不是覆盖）、状态变更后必须重拉（version 由服务端自增）。
///
/// **订阅先行**：页面是 `ref.watch` 这个 Provider 的，切页签才由 Riverpod 重建
/// 驱动重载；`container.read` 不建立订阅，靠它取状态会让「切页签触发重载」
/// 这条断言失真（懒重建不触发）。故 setUp 里用 `container.listen` 保持订阅。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/post/my_posts_provider.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';
import 'package:zhaoyazhao/features/post/post_status.dart';

import '../../support/fake_repositories.dart';
import '../../support/post_fixtures.dart';

void main() {
  late FakePostRepository repo;
  late ProviderContainer container;

  setUp(() {
    repo = FakePostRepository();
    container = ProviderContainer(
      overrides: [postRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    container.listen(myPostsProvider, (_, _) {});
  });

  test('首屏按「全部」拉第一页：不带 status 筛选', () async {
    await pumpEventQueue();

    expect(repo.lastMinePage, 1);
    expect(repo.lastMineStatus, isNull);
    final data = container.read(myPostsProvider).requireValue;
    expect(data.items, hasLength(2));
    expect(data.total, 2);
    expect(data.hasMore, isFalse);
  });

  test('切「已下架」页签：只传 offline（契约单值，2026-09-27 裁定）', () async {
    await pumpEventQueue();

    container.read(myPostsTabProvider.notifier).select(MyPostsTab.offline);
    await pumpEventQueue();

    expect(repo.lastMineStatus, PostApiStatus.offline);
    expect(container.read(myPostsProvider).requireValue.items, hasLength(2));
  });

  test('「草稿」页签不发请求（服务端不存 draft，PRD §8.7）', () async {
    await pumpEventQueue();
    final before = repo.mineFetchCount;

    container.read(myPostsTabProvider.notifier).select(MyPostsTab.draft);
    await pumpEventQueue();

    expect(repo.mineFetchCount, before,
        reason: '草稿无契约筛选值，发 status=draft 只会吃 40001');
    expect(container.read(myPostsProvider).requireValue.items, isEmpty);
  });

  test('触底加载第二页：追加而非覆盖', () async {
    repo.mineToReturn = MyPostsPageDto.fromJson({
      ...myPostsPayload(),
      'total': 5,
    });
    container.invalidate(myPostsProvider);
    await pumpEventQueue();
    expect(container.read(myPostsProvider).requireValue.hasMore, isTrue);

    await container.read(myPostsProvider.notifier).loadMore();

    expect(repo.lastMinePage, 2);
    expect(container.read(myPostsProvider).requireValue.items, hasLength(4),
        reason: '两页各 2 条应累加为 4 条；覆盖会让用户上滑时丢数据');
  });

  test('changeStatus：透传 action/version，成功后重拉（version 由服务端自增）',
      () async {
    await pumpEventQueue();
    final before = repo.mineFetchCount;

    await container.read(myPostsProvider.notifier).changeStatus(
          postId: 1001,
          action: PostStatusAction.offline,
          version: 1,
        );

    expect(repo.lastChangePostId, 1001);
    expect(repo.lastChangeAction, 'offline');
    expect(repo.lastChangeVersion, 1,
        reason: '乐观锁入参必须取自列表项，服务端不接受缺失或本地推算值');
    expect(repo.mineFetchCount, before + 1,
        reason: '不重拉会让本地 version 落后，下一次操作必吃 40903');
  });

  test('并发触底只发一次下一页请求（在途守卫挡重复页）', () async {
    repo.mineToReturn = MyPostsPageDto.fromJson({
      ...myPostsPayload(),
      'total': 5,
    });
    container.invalidate(myPostsProvider);
    await pumpEventQueue();
    final before = repo.mineFetchCount;

    // 滚动监听每帧都会调 loadMore：三次并发必须只落一次请求，
    // 否则同一页会被追加三次（用户看到重复卡片）
    await Future.wait([
      container.read(myPostsProvider.notifier).loadMore(),
      container.read(myPostsProvider.notifier).loadMore(),
      container.read(myPostsProvider.notifier).loadMore(),
    ]);

    expect(repo.mineFetchCount, before + 1);
    expect(container.read(myPostsProvider).requireValue.items, hasLength(4),
        reason: '首屏 2 条 + 第二页 2 条；重复追加会变成 6 条');
  });

  test('加载更多失败后不再被自动重试同页（下拉刷新才恢复）', () async {
    repo.mineToReturn = MyPostsPageDto.fromJson({
      ...myPostsPayload(),
      'total': 5,
    });
    container.invalidate(myPostsProvider);
    await pumpEventQueue();

    repo.mineErrorToThrow = ApiException.parse('第二页拉取失败');
    await expectLater(
      container.read(myPostsProvider.notifier).loadMore(),
      throwsA(isA<ApiException>()),
    );
    final afterFail = repo.mineFetchCount;

    // 滚动监听继续回调：同页被抑制，不发请求、也不再弹提示
    await container.read(myPostsProvider.notifier).loadMore();
    expect(repo.mineFetchCount, afterFail);

    // 用户下拉刷新即清空抑制标记，自动加载恢复
    repo.mineErrorToThrow = null;
    await container.read(myPostsProvider.notifier).refresh();
    await container.read(myPostsProvider.notifier).loadMore();
    expect(repo.mineFetchCount, afterFail + 2);
  });

  test('首屏失败收敛为错误态（不产生未捕获的异步异常）', () async {
    repo.mineErrorToThrow = ApiException.parse('服务端不可用');
    container.invalidate(myPostsProvider);
    await pumpEventQueue();

    final state = container.read(myPostsProvider);
    expect(state.hasError, isTrue);
    expect(state.error, isA<ApiException>());
  });
}
