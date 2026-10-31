/// 消息 Tab 首页（PRD §8.3.4 `message-center`；计划 U11 基线 + U12 完善）。
///
/// 结构对齐设计稿 `02 · 消息列表`：导航「消息」→ 服务号置顶行 → 会话行列表。
/// 未读**只挂 8px 红点**，条数只在服务号行与底部 Tab 出现（R9）；数值一律来自
/// [unreadSummaryProvider]，本页不做二次求和（KTD14）。
///
/// 三种基础态（R33）：空态、首屏加载骨架、拉取失败重试。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/time_format.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import 'message_dto.dart';
import 'message_list_provider.dart';

/// 消息 Tab 首页。
class MessageListScreen extends ConsumerStatefulWidget {
  /// 构造消息 Tab 首页。
  const MessageListScreen({super.key});

  @override
  ConsumerState<MessageListScreen> createState() => _MessageListScreenState();
}

/// 消息列表页状态（持滚动控制器做触底加载）。
class _MessageListScreenState extends ConsumerState<MessageListScreen> {
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
      await ref.read(conversationsProvider.notifier).loadMore();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asApiException(e).uiMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Text(
          '消息',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: conversationsAsync.when(
        loading: () => const _ListSkeleton(),
        error: (error, _) => ListErrorView(
          error: asApiException(error),
          onRetry: () => ref.read(conversationsProvider.notifier).refresh(),
        ),
        data: (data) => _buildList(data),
      ),
    );
  }

  /// 列表（含空态与收尾条）。
  ///
  /// 参数：[data] 会话累积快照。
  /// 返回：Widget。
  Widget _buildList(ConversationsData data) {
    if (data.items.isEmpty) {
      return const _EmptyView();
    }
    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(conversationsProvider.notifier).refresh();
        await ref.read(unreadSummaryProvider.notifier).refresh();
      },
      child: ListView.separated(
        controller: _controller,
        padding: EdgeInsets.zero,
        itemCount: data.items.length + 1,
        separatorBuilder: (context, index) => const SizedBox.shrink(),
        itemBuilder: (context, index) {
          if (index == data.items.length) {
            return const ListEndRow();
          }
          return _ConversationRow(item: data.items[index]);
        },
      ),
    );
  }
}

/// 首屏加载骨架（R33：骨架而非转圈）。
class _ListSkeleton extends StatelessWidget {
  /// 构造骨架。
  const _ListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: 6,
      separatorBuilder: (context, index) => const SizedBox.shrink(),
      itemBuilder: (context, index) => Container(
        color: Color(AppColors.surface),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: Color(AppColors.border),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(width: 96, height: 12, color: Color(AppColors.border)),
                  const SizedBox(height: AppSpacing.sm),
                  Container(width: 180, height: 10, color: Color(AppColors.border)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单条会话行（头像 + 昵称/摘要 + 时间 + 未读红点）。
class _ConversationRow extends StatelessWidget {
  /// 构造会话行。
  ///
  /// 参数：[item] 会话行数据。
  const _ConversationRow({required this.item});

  /// 会话行数据。
  final ConversationDto item;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        border: Border(bottom: BorderSide(color: Color(AppColors.border))),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          _Avatar(url: item.peerAvatarUrl, nickname: item.peerNickname),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.peerNickname,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          fontWeight: FontWeight.w500,
                          color: Color(AppColors.textPrimary),
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    if (item.postGone) const _GoneChip(),
                    const Spacer(),
                    if (item.lastMessageAt != null)
                      Text(
                        formatRelativeAge(item.lastMessageAt!),
                        style: TextStyle(
                          fontSize: AppTypeScale.caption.size,
                          color: Color(AppColors.textPlaceholder),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _preview(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          if (item.unread) ...[
            const SizedBox(width: AppSpacing.sm),
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
    );
  }

  /// 列表摘要文案：卡片类消息用固定说明，空会话用引导语。
  ///
  /// 参数：无。
  /// 返回：[String] 摘要。
  String _preview() {
    final preview = item.lastMessagePreview;
    if (preview != null && preview.isNotEmpty) return preview;
    return switch (item.lastMessageType) {
      'apply' => '[联系方式申请]',
      'contact' => '[已同意查看联系方式]',
      _ => '开始聊聊吧',
    };
  }
}

/// 对方头像（URL 缺失/加载失败时退回昵称首字占位）。
class _Avatar extends StatelessWidget {
  /// 构造头像。
  ///
  /// 参数：[url] 头像 URL（可空）；[nickname] 昵称（取首字做占位）。
  const _Avatar({required this.url, required this.nickname});

  /// 头像 URL。
  final String? url;

  /// 昵称。
  final String nickname;

  @override
  Widget build(BuildContext context) {
    final initial = nickname.isEmpty ? '' : nickname.substring(0, 1);
    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color(AppColors.primaryLight),
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: url == null || url!.isEmpty
          ? Text(
              initial,
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                fontWeight: FontWeight.w600,
                color: Color(AppColors.primaryDark),
              ),
            )
          : Image.network(
              url!,
              fit: BoxFit.cover,
              errorBuilder: (context, error, stack) => Text(
                initial,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.primaryDark),
                ),
              ),
            ),
    );
  }
}

/// 「已下架」胶囊（R4：帖子下架不影响会话，行内标注）。
class _GoneChip extends StatelessWidget {
  /// 构造胶囊。
  const _GoneChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Color(AppColors.background),
        border: Border.all(color: Color(AppColors.border)),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        '已下架',
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          fontWeight: FontWeight.w600,
          color: Color(AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// 空态（R33）。
class _EmptyView extends StatelessWidget {
  /// 构造空态。
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Color(AppColors.border),
                  width: 1.5,
                ),
              ),
              child: Icon(
                Icons.chat_bubble_outline,
                size: 24,
                color: Color(AppColors.primary),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '还没有会话',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                fontWeight: FontWeight.w600,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '在详情页点「发消息」，就能和发布者直接聊',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
