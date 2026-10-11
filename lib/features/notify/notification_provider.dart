/// 通知中心状态层（[B2-11]）。
///
/// 数据流：页签（[notifyTabProvider]）→ `GET /notifications?type=` → 分页累积
/// （[NotificationsData]）→ 页面按 `AsyncValue` 三态渲染。切页签即重载 +
/// 竞态丢弃（详设 §15.2）。「全部已读」成功后就地刷新并同步未读数。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import 'notification_dto.dart';
import 'notification_repository.dart';

/// 通知页签（设计稿 `notification-screen` 的三格：系统/互动/认证）。
enum NotifyTab {
  /// 系统。
  system,

  /// 互动。
  interaction,

  /// 认证。
  cert,
}

/// 页签 → 契约 `type` 线值 / 文案。
extension NotifyTabApi on NotifyTab {
  /// 契约查询值（openapi `type` enum: system/interaction/cert）。
  String get apiType => switch (this) {
        NotifyTab.system => 'system',
        NotifyTab.interaction => 'interaction',
        NotifyTab.cert => 'cert',
      };

  /// 页签文案（与设计稿逐字一致）。
  String get label => switch (this) {
        NotifyTab.system => '系统',
        NotifyTab.interaction => '互动',
        NotifyTab.cert => '认证',
      };
}

/// 当前通知页签状态。
class NotifyTabNotifier extends Notifier<NotifyTab> {
  @override
  NotifyTab build() => NotifyTab.system;

  /// 切换页签（相同不写状态）。
  ///
  /// 参数：[tab] 目标页签。
  /// 返回：void。
  void select(NotifyTab tab) {
    if (state != tab) state = tab;
  }
}

/// 通知页签 Provider。
final notifyTabProvider = NotifierProvider<NotifyTabNotifier, NotifyTab>(
  NotifyTabNotifier.new,
);

/// 通知列表累积快照。
class NotificationsData {
  /// 构造快照。
  ///
  /// 参数：[items] 已加载项；[total] 总数；[page] 已加载页码；[unreadCount] 未读总数。
  const NotificationsData({
    required this.items,
    required this.total,
    required this.page,
    required this.unreadCount,
  });

  /// 已加载项。
  final List<NotificationDto> items;

  /// 服务端符合条件的总数。
  final int total;

  /// 已加载到的页码。
  final int page;

  /// 未读总数（跨类型，用于角标）。
  final int unreadCount;

  /// 是否还有下一页。
  bool get hasMore => items.length < total;
}

/// 通知列表状态机。
class NotificationsNotifier extends Notifier<AsyncValue<NotificationsData>> {
  /// 追加分页在途标志。
  bool _loadingMore = false;

  @override
  AsyncValue<NotificationsData> build() {
    final tab = ref.watch(notifyTabProvider);
    unawaited(_loadFirstPage(tab));
    return const AsyncValue.loading();
  }

  /// 拉第一页并把失败收敛到错误态。
  ///
  /// 参数：[tab] 发起时的页签。
  /// 返回：[Future<void>]。
  Future<void> _loadFirstPage(NotifyTab tab) async {
    try {
      await _fetch(tab: tab, page: 1);
    } catch (e) {
      if (ref.read(notifyTabProvider) != tab) return;
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 拉指定页；[append] 为 true 时追加。
  ///
  /// 参数：[tab] 发起时页签；[page] 页码；[append] 是否追加。
  /// 返回：[Future<void>]。
  Future<void> _fetch({
    required NotifyTab tab,
    required int page,
    bool append = false,
  }) async {
    final result = await ref
        .read(notificationRepositoryProvider)
        .fetchNotifications(type: tab.apiType, page: page);
    if (ref.read(notifyTabProvider) != tab) return;
    final prev = append
        ? (state.asData?.value.items ?? const <NotificationDto>[])
        : const <NotificationDto>[];
    state = AsyncValue.data(
      NotificationsData(
        items: [...prev, ...result.items],
        total: result.total,
        page: result.page,
        unreadCount: result.unreadCount,
      ),
    );
  }

  /// 刷新当前页签。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    final tab = ref.read(notifyTabProvider);
    state = const AsyncValue.loading();
    await _loadFirstPage(tab);
  }

  /// 触底加载下一页。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> loadMore() async {
    final current = state.asData?.value;
    if (_loadingMore || current == null || !current.hasMore || state.isLoading) {
      return;
    }
    _loadingMore = true;
    try {
      await _fetch(tab: ref.read(notifyTabProvider), page: current.page + 1, append: true);
    } finally {
      _loadingMore = false;
    }
  }

  /// 全部已读（不带 ids＝服务端标记该用户全部未读）并刷新。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException] 由页面提示。
  Future<void> markAllRead() async {
    await ref.read(notificationRepositoryProvider).markRead();
    await refresh();
  }
}

/// 通知列表 Provider。
final notificationsProvider =
    NotifierProvider<NotificationsNotifier, AsyncValue<NotificationsData>>(
  NotificationsNotifier.new,
);
