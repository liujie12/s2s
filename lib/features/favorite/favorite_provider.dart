/// 收藏列表状态层（[B2-11]）。
///
/// 数据流：页签（[favoriteTabProvider]）→ `GET /favorites?type=` → 分页累积
/// （[FavoritesData]）→ 页面按 `AsyncValue` 三态渲染。切页签即重载（`build()`
/// 内 `ref.watch(页签)`），并由页签比对做竞态丢弃（详设 §15.2）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import 'favorite_dto.dart';
import 'favorite_repository.dart';

/// 收藏页签（设计稿 `my-favorite-screen` 的三格：资源/需求/全部）。
enum FavoriteTab {
  /// 资源。
  resource,

  /// 需求。
  demand,

  /// 全部。
  all,
}

/// 页签 → 契约 `type` 线值。
extension FavoriteTabApi on FavoriteTab {
  /// 契约查询参数值（openapi `type` enum: resource/demand/all）。
  String get apiType => switch (this) {
        FavoriteTab.resource => 'resource',
        FavoriteTab.demand => 'demand',
        FavoriteTab.all => 'all',
      };

  /// 页签文案（与设计稿逐字一致）。
  String get label => switch (this) {
        FavoriteTab.resource => '资源',
        FavoriteTab.demand => '需求',
        FavoriteTab.all => '全部',
      };
}

/// 当前收藏页签状态。
class FavoriteTabNotifier extends Notifier<FavoriteTab> {
  @override
  FavoriteTab build() => FavoriteTab.resource;

  /// 切换页签（相同不写状态）。
  ///
  /// 参数：[tab] 目标页签。
  /// 返回：void。
  void select(FavoriteTab tab) {
    if (state != tab) state = tab;
  }
}

/// 收藏页签 Provider。
final favoriteTabProvider = NotifierProvider<FavoriteTabNotifier, FavoriteTab>(
  FavoriteTabNotifier.new,
);

/// 收藏列表累积快照。
class FavoritesData {
  /// 构造快照。
  ///
  /// 参数：[items] 已加载项（服务端序）；[total] 总数；[page] 已加载页码。
  const FavoritesData({required this.items, required this.total, required this.page});

  /// 已加载项。
  final List<FavoriteItemDto> items;

  /// 服务端符合条件的总数。
  final int total;

  /// 已加载到的页码。
  final int page;

  /// 是否还有下一页。
  bool get hasMore => items.length < total;
}

/// 收藏列表状态机。
class FavoritesNotifier extends Notifier<AsyncValue<FavoritesData>> {
  /// 追加分页在途标志（防滚动监听并发重发同页）。
  bool _loadingMore = false;

  @override
  AsyncValue<FavoritesData> build() {
    final tab = ref.watch(favoriteTabProvider);
    unawaited(_loadFirstPage(tab));
    return const AsyncValue.loading();
  }

  /// 拉第一页并把失败收敛到错误态。
  ///
  /// 参数：[tab] 发起时的页签（写状态前做竞态比对）。
  /// 返回：[Future<void>]。
  Future<void> _loadFirstPage(FavoriteTab tab) async {
    try {
      await _fetch(tab: tab, page: 1);
    } catch (e) {
      if (ref.read(favoriteTabProvider) != tab) return;
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 拉指定页；[append] 为 true 时追加。
  ///
  /// 参数：[tab] 发起时页签；[page] 页码；[append] 是否追加。
  /// 返回：[Future<void>]。
  Future<void> _fetch({
    required FavoriteTab tab,
    required int page,
    bool append = false,
  }) async {
    final result = await ref
        .read(favoriteRepositoryProvider)
        .fetchFavorites(type: tab.apiType, page: page);
    if (ref.read(favoriteTabProvider) != tab) return;
    final prev = append
        ? (state.asData?.value.items ?? const <FavoriteItemDto>[])
        : const <FavoriteItemDto>[];
    state = AsyncValue.data(
      FavoritesData(
        items: [...prev, ...result.items],
        total: result.total,
        page: result.page,
      ),
    );
  }

  /// 刷新当前页签（下拉刷新 / 重试）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    final tab = ref.read(favoriteTabProvider);
    state = const AsyncValue.loading();
    await _loadFirstPage(tab);
  }

  /// 触底加载下一页。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]；失败保留已加载数据并把异常抛给页面。
  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (_loadingMore || current == null || !current.hasMore || state.isLoading) {
      return;
    }
    _loadingMore = true;
    try {
      await _fetch(tab: ref.read(favoriteTabProvider), page: current.page + 1, append: true);
    } finally {
      _loadingMore = false;
    }
  }

  /// 取消收藏并刷新（点星标/上滑）。
  ///
  /// 参数：[postId] 帖子 ID。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException] 由页面提示。
  Future<void> remove(int postId) async {
    await ref.read(favoriteRepositoryProvider).removeFavorite(postId);
    await refresh();
  }
}

/// 收藏列表 Provider。
final favoritesProvider = NotifierProvider<FavoritesNotifier, AsyncValue<FavoritesData>>(
  FavoritesNotifier.new,
);
