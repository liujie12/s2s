/// 通知中心页（PRD §8.3.3 `notification-screen`；[B2-11]）。
///
/// 结构（对齐设计稿 `buildNotification`）：导航「通知」+ 右动作「全部已读」→
/// 三格分段 Tab（系统/互动/认证）→ 通知行列表 → 收尾条「没有更多了」。
///
/// 未读为**双通道**（设计稿口径）：红点 + 标题色阶（未读 text-primary /
/// 已读 text-secondary），不可只做红点。行尾**不带 chevron**（PRD §8.3.3
/// 「不做展开态」），点击跳对应详情。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/time_format.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import 'notification_dto.dart';
import 'notification_provider.dart';

/// 通知中心页。
class NotificationScreen extends ConsumerStatefulWidget {
  /// 构造通知中心页。
  const NotificationScreen({super.key});

  @override
  ConsumerState<NotificationScreen> createState() => _NotificationScreenState();
}

/// 通知中心页状态（持滚动控制器做触底加载）。
class _NotificationScreenState extends ConsumerState<NotificationScreen> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// 触底加载下一页。
  ///
  /// 参数：无。
  /// 返回：void。
  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.pixels >= position.maxScrollExtent - 200) {
      _loadMoreSafely();
    }
  }

  /// 加载下一页并吞掉异常（失败保留已加载数据）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _loadMoreSafely() async {
    try {
      await ref.read(notificationsProvider.notifier).loadMore();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asApiException(e).uiMessage)),
      );
    }
  }

  /// 全部已读并提示失败。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _markAllRead() async {
    try {
      await ref.read(notificationsProvider.notifier).markAllRead();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asApiException(e).uiMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(notifyTabProvider);
    final notificationsAsync = ref.watch(notificationsProvider);

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, size: 18, color: Color(AppColors.textPrimary)),
          onPressed: () => context.pop(),
        ),
        title: Text(
          '通知',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _markAllRead,
            child: Text(
              '全部已读',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.primary),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _SegTabs(
            current: tab,
            onSelect: (next) => ref.read(notifyTabProvider.notifier).select(next),
          ),
          Expanded(
            child: notificationsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ListErrorView(
                error: asApiException(error),
                onRetry: () => ref.read(notificationsProvider.notifier).refresh(),
              ),
              data: (data) => _buildList(data),
            ),
          ),
        ],
      ),
    );
  }

  /// 列表（含空态与收尾条）。
  ///
  /// 参数：[data] 通知累积快照。
  /// 返回：Widget。
  Widget _buildList(NotificationsData data) {
    if (data.items.isEmpty) {
      return const _EmptyView();
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(notificationsProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _controller,
        padding: EdgeInsets.zero,
        itemCount: data.items.length + 1,
        separatorBuilder: (context, index) => const SizedBox.shrink(),
        itemBuilder: (context, index) {
          if (index == data.items.length) {
            return const ListEndRow();
          }
          return _NotifyRow(item: data.items[index]);
        },
      ),
    );
  }
}

/// 三格分段 Tab（系统/互动/认证）。
class _SegTabs extends StatelessWidget {
  /// 构造分段 Tab。
  ///
  /// 参数：[current] 当前页签；[onSelect] 选择回调。
  const _SegTabs({required this.current, required this.onSelect});

  /// 当前页签。
  final NotifyTab current;

  /// 选择回调。
  final ValueChanged<NotifyTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 颜色必须落在 decoration 内：Container 同时给 color 与 decoration 会触发
      // 「Cannot provide both a color and a decoration」断言（debug 红屏）。
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        border: Border(bottom: BorderSide(color: Color(AppColors.border))),
      ),
      child: Row(
        children: [
          for (final tab in NotifyTab.values)
            Expanded(
              child: InkWell(
                onTap: () => onSelect(tab),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  child: Center(
                    child: Text(
                      tab.label,
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        color: Color(
                          tab == current ? AppColors.primary : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单条通知行（图标 + 标题/摘要 + 时间/未读点，行尾无 chevron）。
class _NotifyRow extends StatelessWidget {
  /// 构造通知行。
  ///
  /// 参数：[item] 通知项。
  const _NotifyRow({required this.item});

  /// 通知项。
  final NotificationDto item;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => _openTarget(context),
      child: Container(
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          border: Border(bottom: BorderSide(color: Color(AppColors.border))),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_iconFor(item.type), size: 20, color: Color(AppColors.primary)),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      // 未读/已读双通道之一：标题色阶（另一通道是右侧红点）。
                      color: Color(
                        item.isRead ? AppColors.textSecondary : AppColors.textPrimary,
                      ),
                    ),
                  ),
                  if (item.content != null && item.content!.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      item.content!,
                      style: TextStyle(
                        fontSize: AppTypeScale.small.size,
                        color: Color(AppColors.textSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatRelativeAge(item.createdAt),
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
                if (!item.isRead) ...[
                  const SizedBox(height: AppSpacing.xs),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Color(AppColors.error),
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 按类型给图标（系统/互动/认证三通道各一）。
  ///
  /// 参数：[type] 契约类型值。
  /// 返回：[IconData]。
  static IconData _iconFor(String type) => switch (type) {
        'system' => Icons.notifications_none,
        'interaction' => Icons.chat_bubble_outline,
        'cert' => Icons.check_circle_outline,
        _ => Icons.notifications_none,
      };

  /// 点击跳转目标（`target.kind=post` → 详情；其余暂不跳）。
  ///
  /// 参数：[context] 构建上下文。
  /// 返回：void。
  void _openTarget(BuildContext context) {
    if (item.targetKind == 'post' && item.targetPostId != null) {
      context.push('/detail/${item.targetPostId}');
    }
  }
}

/// 空态。
class _EmptyView extends StatelessWidget {
  /// 构造空态。
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.notifications_none, size: 40, color: Color(AppColors.textPlaceholder)),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '暂无通知',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
