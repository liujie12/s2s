/// 「我的发布」列表状态层（[127] 前端段）。
///
/// 数据流：页签（[myPostsTabProvider]）→ `GET /posts/mine`（契约单值筛选）
/// → 分页累积（[MyPostsData]）→ 页面按 `AsyncValue` 三态渲染（详细设计 §15.3）。
///
/// 三个设计取舍：
///   1. **切页签即重载**：`build()` 内 `ref.watch(页签)`，换页签由 Riverpod
///      重建驱动，页面不需要手动触发刷新（也不会漏掉某条切换路径）；
///   2. **竞态丢弃**（详细设计 §15.2）：切页签后旧请求的响应必须丢掉，否则
///      新页签会短暂显示旧页签的数据 —— 每次写入前比一次当前页签；
///   3. **草稿页签发请求是错的**：服务端不存 `draft`（PRD §8.7），发一个
///      `status=draft` 只会吃 `40001`，故该页签直接给空数据（页面渲染降级空态）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import 'post_dto.dart';
import 'post_repository.dart';
import 'post_status.dart';

/// 列表数据快照（累积当前页签已加载的全部条目）。
class MyPostsData {
  /// 构造列表快照。
  ///
  /// 参数：[items] 已加载条目（按服务端序，页 1 在前）；[total] 服务端符合条件的
  ///   总条数；[page] 已加载到第几页（从 1 起，用于触底加载下一页）。
  const MyPostsData({
    required this.items,
    required this.total,
    required this.page,
  });

  /// 已加载条目。
  final List<MyPostItemDto> items;

  /// 服务端符合条件总条数。
  final int total;

  /// 已加载到的页码。
  final int page;

  /// 是否还有下一页（以 `total` 判定，与页大小无关）。
  bool get hasMore => items.length < total;
}

/// 当前页签状态（UI 状态，非异步数据）。
class MyPostsTabNotifier extends Notifier<MyPostsTab> {
  @override
  MyPostsTab build() => MyPostsTab.all;

  /// 切换页签（相同页签不写状态，避免无谓重建）。
  ///
  /// 参数：[tab] 目标页签。
  /// 返回：void。
  void select(MyPostsTab tab) {
    if (state != tab) state = tab;
  }
}

/// 页签 Provider（页面经 `ref.watch` 取当前页签）。
final myPostsTabProvider = NotifierProvider<MyPostsTabNotifier, MyPostsTab>(
  MyPostsTabNotifier.new,
);

/// 「我的发布」列表状态机（`AsyncValue` 三态 + 分页累积 + 状态变更）。
class MyPostsNotifier extends Notifier<AsyncValue<MyPostsData>> {
  /// 追加分页的在途标志（防并发重复请求）。
  ///
  /// **为什么不能用 `state.isLoading`**：追加分页刻意**不写 loading 态**（写了会让
  /// 整屏回到骨架），故追加期间 `isLoading` 恒为 false；而滚动监听每个滚动帧都会
  /// 回调，一次惯性滑动就会并发发出多个**同一页码**的请求，每个响应各自
  /// `[...prev, ...items]` → 同一页被追加多次，用户看到重复卡片。
  /// Dart 单线程 run-to-completion：首个 `await` 前同步置位即可挡住后续进入。
  bool _loadingMore = false;

  /// 最近一次「加载更多」失败的页码（防滚动监听无冷却地反复重发同页与反复弹提示）。
  ///
  /// 清空时机 = 用户显式重试：下拉刷新 / 切换页签 / 页面重建。
  int? _failedPage;

  @override
  AsyncValue<MyPostsData> build() {
    final tab = ref.watch(myPostsTabProvider);
    _failedPage = null;
    if (!tab.hasDataSource) {
      // 草稿页签：无数据源（服务端不存 draft、本地草稿属 Batch2），
      // 直接给空数据 —— 空数据 + 页面降级空态，而不是发一个必然 40001 的请求。
      return const AsyncValue.data(
        MyPostsData(items: [], total: 0, page: 1),
      );
    }
    unawaited(_loadFirstPage(tab));
    return const AsyncValue.loading();
  }

  /// 拉第一页并把失败收敛到错误态（首屏无数据可保留）。
  ///
  /// 参数：[tab] 发起时的页签（写状态前用它做竞态比对）。
  /// 返回：[Future<void>]。
  Future<void> _loadFirstPage(MyPostsTab tab) async {
    try {
      await _fetch(tab: tab, page: 1);
    } catch (e) {
      if (ref.read(myPostsTabProvider) != tab) return;
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 拉指定页；[append] 为 true 时追加而非覆盖。
  ///
  /// 参数：[tab] 发起时的页签；[page] 页码；[append] 是否追加。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException] 由调用方决定收敛方式（首屏→错误态；加载更多→提示）。
  Future<void> _fetch({
    required MyPostsTab tab,
    required int page,
    bool append = false,
  }) async {
    final result = await ref
        .read(postRepositoryProvider)
        .fetchMine(page: page, status: tab.apiStatus);
    // 竞态守卫（详设 §15.2）：切页签后旧响应到达必须丢弃。
    if (ref.read(myPostsTabProvider) != tab) return;
    final prev = append
        ? (state.asData?.value.items ?? const <MyPostItemDto>[])
        : const <MyPostItemDto>[];
    state = AsyncValue.data(
      MyPostsData(
        items: [...prev, ...result.items],
        total: result.total,
        page: result.page,
      ),
    );
  }

  /// 刷新当前页签（下拉刷新 / 错误态重试按钮）。
  ///
  /// 返回：[Future<void>]；失败收敛为错误态（页面据此显示重试入口）。
  Future<void> refresh() async {
    final tab = ref.read(myPostsTabProvider);
    if (!tab.hasDataSource) return;
    _failedPage = null;
    state = const AsyncValue.loading();
    await _loadFirstPage(tab);
  }

  /// 触底加载下一页。
  ///
  /// 返回：[Future<void>]；失败**保留已加载数据**并把异常抛给页面弹提示 ——
  ///   一页失败清空整屏，比少一页更糟。失败后同页不再被滚动监听自动重试
  ///   （否则每个滚动帧重发一次、每帧弹一条提示），须由用户下拉刷新恢复。
  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (_loadingMore || current == null || !current.hasMore || state.isLoading) {
      return;
    }
    final nextPage = current.page + 1;
    if (_failedPage == nextPage) return;
    _loadingMore = true;
    try {
      await _fetch(
        tab: ref.read(myPostsTabProvider),
        page: nextPage,
        append: true,
      );
    } catch (_) {
      _failedPage = nextPage;
      rethrow;
    } finally {
      _loadingMore = false;
    }
  }

  /// 变更帖子状态（真接口），成功后重拉当前页签。
  ///
  /// 为什么成功后重拉而不是本地改状态：`version` 由服务端自增（后端详设
  /// §5.3.3），本地推算会让下一次操作带着过期版本号吃 `40903`；重拉拿回
  /// 权威状态与版本号。
  ///
  /// 参数：[postId] 帖子 ID；[action] 契约动作值（[MyPostCardAction.apiAction]）；
  ///   [version] 当前乐观锁版本号（取自列表项）。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException]（40903 版本冲突等）由页面按 §12.2 行为表提示。
  Future<void> changeStatus({
    required int postId,
    required String action,
    required int version,
  }) async {
    await ref
        .read(postRepositoryProvider)
        .changeStatus(postId, action: action, version: version);
    await refresh();
  }
}

/// 「我的发布」列表 Provider（页面经 `ref.watch` 取 `AsyncValue` 三态）。
final myPostsProvider = NotifierProvider<MyPostsNotifier, AsyncValue<MyPostsData>>(
  MyPostsNotifier.new,
);
