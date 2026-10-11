/// 「我的」页数据层（[B2-11]）。
///
/// 两条独立数据流，页面各自按 `AsyncValue` 三态渲染：
///   1. [myProfileProvider]：`GET /users/me` → 头部昵称/脱敏号/实名状态；
///   2. [myPageBadgesProvider]：并行聚合三个入口的右侧角标
///      （我的发布「N 在架」/ 我的收藏「N」/ 通知中心「N 未读」）。
///
/// 角度分离的理由：角标失败不该把整个头部拖成错误态（反之亦然），故拆两个
/// Provider；角标三路请求 `Future.wait` 并行，任一失败即整体降级为「不显角标」
/// （角标是增益信息，缺失不影响入口可用）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../favorite/favorite_repository.dart';
import '../notify/notification_repository.dart';
import '../post/post_repository.dart';
import 'profile_dto.dart';
import 'profile_repository.dart';

/// 本人资料 Provider 的状态机（`GET /users/me`）。
class MyProfileNotifier extends Notifier<AsyncValue<MyProfileDto>> {
  @override
  AsyncValue<MyProfileDto> build() {
    unawaited(_load());
    return const AsyncValue.loading();
  }

  /// 拉取本人资料并把失败收敛到错误态。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _load() async {
    try {
      final profile = await ref.read(profileRepositoryProvider).fetchMyProfile();
      state = AsyncValue.data(profile);
    } catch (e) {
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 重新拉取（错误态重试 / 下拉刷新）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    await _load();
  }
}

/// 本人资料 Provider（页面经 `ref.watch` 取 `AsyncValue` 三态）。
final myProfileProvider =
    NotifierProvider<MyProfileNotifier, AsyncValue<MyProfileDto>>(
  MyProfileNotifier.new,
);

/// 「我的」页入口角标快照。
class MyPageBadges {
  /// 构造角标快照。
  ///
  /// 参数：[activePosts] 在架发布数；[favorites] 收藏数；[unread] 未读通知数。
  const MyPageBadges({
    required this.activePosts,
    required this.favorites,
    required this.unread,
  });

  /// 在架发布数（`GET /posts/mine?status=active` 的 total）。
  final int activePosts;

  /// 收藏总数（`GET /favorites` 的 total）。
  final int favorites;

  /// 未读通知数（`GET /notifications` 的 unread_count）。
  final int unread;
}

/// 「我的」页入口角标 Provider 的状态机（并行聚合三路）。
class MyPageBadgesNotifier extends Notifier<AsyncValue<MyPageBadges>> {
  @override
  AsyncValue<MyPageBadges> build() {
    unawaited(_load());
    return const AsyncValue.loading();
  }

  /// 并行拉三路角标并合并。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _load() async {
    try {
      final results = await Future.wait(<Future<int>>[
        // page_size=1：只要 total，不要整页数据。
        ref
            .read(postRepositoryProvider)
            .fetchMine(status: 'active', pageSize: 1)
            .then((page) => page.total),
        ref
            .read(favoriteRepositoryProvider)
            .fetchFavorites(pageSize: 1)
            .then((page) => page.total),
        ref
            .read(notificationRepositoryProvider)
            .fetchNotifications(pageSize: 1)
            .then((page) => page.unreadCount),
      ]);
      state = AsyncValue.data(
        MyPageBadges(activePosts: results[0], favorites: results[1], unread: results[2]),
      );
    } catch (e) {
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 重新拉取角标（下拉刷新）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    await _load();
  }
}

/// 「我的」页入口角标 Provider。
final myPageBadgesProvider =
    NotifierProvider<MyPageBadgesNotifier, AsyncValue<MyPageBadges>>(
  MyPageBadgesNotifier.new,
);
