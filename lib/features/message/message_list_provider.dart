/// 消息域状态层（2026-10-31）：会话列表与未读汇总。
///
/// 两条数据流分离：
///   1. [conversationsProvider]：`GET /conversations` → 分页累积 → 列表页三态；
///   2. [unreadSummaryProvider]：`GET /unread-summary` → **唯一未读真源**
///      （KTD14）。Tab 角标、服务号行、安卓桌面角标都读它，客户端不做二次求和。
///
/// 未登录时两条流都返回确定空值、不发请求（`isLoggedInProvider` 为假）。
/// 未读是增益信息：拉取失败保留上一次的值，不把 Tab 拖成错误态。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../nfr_constants.dart';
import '../auth/auth_repository.dart';
import 'message_dto.dart';
import 'message_repository.dart';

/// 会话列表累积快照。
class ConversationsData {
  /// 构造快照。
  ///
  /// 参数：[items] 已加载行；[total] 服务端总数；[page] 已加载页码。
  const ConversationsData({
    required this.items,
    required this.total,
    required this.page,
  });

  /// 空快照（未登录 / 空列表）。
  static const ConversationsData empty = ConversationsData(
    items: <ConversationDto>[],
    total: 0,
    page: 1,
  );

  /// 已加载会话行。
  final List<ConversationDto> items;

  /// 服务端符合条件总数。
  final int total;

  /// 已加载到的页码。
  final int page;

  /// 是否还有下一页。
  bool get hasMore => items.length < total;
}

/// 会话列表状态机。
class ConversationsNotifier extends Notifier<AsyncValue<ConversationsData>> {
  /// 追加分页在途标志。
  bool _loadingMore = false;

  @override
  AsyncValue<ConversationsData> build() {
    if (!ref.watch(isLoggedInProvider)) {
      return const AsyncValue.data(ConversationsData.empty);
    }
    unawaited(_loadFirstPage());
    return const AsyncValue.loading();
  }

  /// 拉第一页并把失败收敛到错误态。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _loadFirstPage() async {
    try {
      await _fetch(page: 1);
    } catch (e) {
      if (!ref.read(isLoggedInProvider)) return;
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 拉指定页；[append] 为 true 时追加。
  ///
  /// 参数：[page] 页码；[append] 是否追加。
  /// 返回：[Future<void>]。
  Future<void> _fetch({required int page, bool append = false}) async {
    final result = await ref
        .read(messageRepositoryProvider)
        .fetchConversations(page: page);
    if (!ref.read(isLoggedInProvider)) return;
    final prev = append
        ? (state.asData?.value.items ?? const <ConversationDto>[])
        : const <ConversationDto>[];
    state = AsyncValue.data(
      ConversationsData(
        items: [...prev, ...result.items],
        total: result.total,
        page: result.page,
      ),
    );
  }

  /// 重新拉第一页（错误态重试 / 下拉刷新）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    await _loadFirstPage();
  }

  /// 静默重拉第一页：实时事件触发的后台刷新。
  ///
  /// 与 [refresh] 的区别是**不进入 loading 态**——实时消息到达时列表若闪一次骨架屏，
  /// 比晚 100ms 更新更伤体验。失败保留旧值（实时是增益信息，不把列表拖成错误态）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refreshSilently() async {
    if (!ref.read(isLoggedInProvider)) return;
    try {
      await _fetch(page: 1);
    } catch (_) {
      // 保留上一屏数据，等待下一次事件或用户手动刷新
    }
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
      await _fetch(page: current.page + 1, append: true);
    } finally {
      _loadingMore = false;
    }
  }
}

/// 会话列表 Provider。
final conversationsProvider =
    NotifierProvider<ConversationsNotifier, AsyncValue<ConversationsData>>(
  ConversationsNotifier.new,
);

/// 未读汇总状态机（唯一出口，KTD14）。
class UnreadSummaryNotifier extends Notifier<AsyncValue<UnreadSummaryDto>> {
  @override
  AsyncValue<UnreadSummaryDto> build() {
    if (!ref.watch(isLoggedInProvider)) {
      return const AsyncValue.data(UnreadSummaryDto.zero);
    }
    unawaited(_load());
    return const AsyncValue.data(UnreadSummaryDto.zero);
  }

  /// 拉一次未读汇总；失败保留上一次的值（角标是增益信息）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _load() async {
    try {
      final summary =
          await ref.read(messageRepositoryProvider).fetchUnreadSummary();
      if (!ref.read(isLoggedInProvider)) return;
      state = AsyncValue.data(summary);
    } catch (_) {
      // 不写错误态：Tab 角标缺省为「无角标」比显示错误更符合预期；
      // 真正的失败提示由消息列表页自己的三态承担。
    }
  }

  /// 主动刷新（App 回前台、收发消息、读会话后调用）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() => _load();
}

/// 未读汇总 Provider。
final unreadSummaryProvider =
    NotifierProvider<UnreadSummaryNotifier, AsyncValue<UnreadSummaryDto>>(
  UnreadSummaryNotifier.new,
);

/// 未读角标文案（R9 / R11：0 不渲染，超过上限显示「99+」）。
///
/// 参数：[total] 未读总数（来自 [unreadSummaryProvider]）。
/// 返回：[String?]；0 或负数返回 null（调用方据此不渲染角标）。
String? unreadBadgeLabel(int total) {
  if (total <= 0) return null;
  if (total > NfrChat.unreadBadgeMax) return '${NfrChat.unreadBadgeMax}+';
  return '$total';
}
