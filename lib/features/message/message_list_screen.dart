/// 消息 Tab 首页（PRD §8.3.4 `message-center`；计划 U11 基线 + U12 完善）。
///
/// 结构对齐设计稿 `02 · 消息列表`：导航「消息」→ 服务号置顶行 → 会话行列表。
/// 未读**只挂 8px 红点**，条数只在服务号行与底部 Tab 出现（R9）；数值一律来自
/// [unreadSummaryProvider]，本页不做二次求和（KTD14）。
///
/// 三种基础态（R33）：空态、首屏加载骨架、拉取失败重试。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/network/api_exception.dart';
import '../../core/time_format.dart';
import '../../core/ui/footprint_geometry.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../../router/app_router.dart';
import '../notify/push_service.dart';
import 'message_dto.dart';
import 'message_list_provider.dart';
import 'message_permission.dart';
import 'widgets/message_icon.dart';

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

  /// 说明层是否已在本页生命周期内弹过（防同一帧重复弹）。
  bool _explainerShown = false;

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

  /// 左滑后二次确认并执行删除（V33「仅自己删除」）。
  ///
  /// 请求成功后才返回 true：由 Provider 立即移除该行，滑动动画结束即消失。
  /// 失败（如服务端未部署该接口）返回 false，行回弹保持可见，避免用户误以为已删。
  ///
  /// 参数：[item] 待删除会话。
  /// 返回：[Future<bool>]；成功 true，取消或失败 false。
  Future<bool> _confirmDelete(ConversationDto item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除会话'),
        content: Text(
          '删除后「${item.peerNickname}」将从你的消息列表移除，对方不受影响；'
          '再收到新消息时会重新出现。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Color(AppColors.error)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return false;

    try {
      await ref
          .read(conversationsProvider.notifier)
          .deleteConversation(item.conversationId);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败：${asApiException(e).uiMessage}')),
        );
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationsAsync = ref.watch(conversationsProvider);
    final permission = ref.watch(messageNotifyPermissionProvider);
    final unread = ref.watch(
      unreadSummaryProvider.select((value) => value.asData?.value),
    );
    _maybeShowExplainer(permission);

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
      body: Column(
        children: [
          if (permission.shouldShowBanner)
            _NotifyBanner(
              onOpenSettings: openAppSettings,
              onDismiss: () =>
                  ref.read(messageNotifyPermissionProvider.notifier).dismissBanner(),
            ),
          Expanded(
            child: conversationsAsync.when(
              loading: () => const _ListSkeleton(),
              error: (error, _) => ListErrorView(
                error: asApiException(error),
                onRetry: () => ref.read(conversationsProvider.notifier).refresh(),
              ),
              data: (data) => _buildList(data, unread?.notificationUnread ?? 0),
            ),
          ),
        ],
      ),
    );
  }

  /// 首次进入时弹通知权限说明层（R16）。
  ///
  /// 参数：[permission] 本地引导状态。
  /// 返回：void；本地标记未读完或已弹过时不动作。
  void _maybeShowExplainer(MessageNotifyPermissionState permission) {
    if (_explainerShown || !permission.shouldShowExplainer) return;
    _explainerShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _showExplainer();
    });
  }

  /// 说明层 → 系统权限弹窗（设计稿 06 帧）。
  ///
  /// 返回：[Future<void>]。
  Future<void> _showExplainer() async {
    final notifier = ref.read(messageNotifyPermissionProvider.notifier);
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('开启消息通知'),
        content: const Text(
          '开启通知后，对方回你消息时手机会收到提醒。只推消息与认证结果，不做营销推送。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('暂不'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('去开启'),
          ),
        ],
      ),
    );
    // 无论选哪项都不再重复弹说明层（R16：不重复拉起）。
    await notifier.markExplainerSeen();
    if (go != true) return;
    final granted = await ref.read(pushServiceProvider).requestPermission();
    if (!granted) await notifier.markDenied();
  }

  /// 列表（服务号置顶 + 会话行 + 收尾条）。
  ///
  /// 参数：[data] 会话累积快照；[notificationUnread] 通知未读条数。
  /// 返回：Widget。
  Widget _buildList(ConversationsData data, int notificationUnread) {
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
        itemCount: data.items.length + 2,
        separatorBuilder: (context, index) => const SizedBox.shrink(),
        itemBuilder: (context, index) {
          // 服务号永久第一行、不可删除（R12）：不包 Dismissible，也不随滚动移除。
          if (index == 0) {
            return _ServiceRow(
              unreadCount: notificationUnread,
              onTap: () => context.push(AppRoutes.notifications),
            );
          }
          if (index == data.items.length + 1) {
            return const ListEndRow();
          }
          final item = data.items[index - 1];
          // 左滑删除（V33「仅自己删除」）：服务号行不在此分支，天然不可删（R12）。
          return Dismissible(
            key: ValueKey<String>('conversation-${item.conversationId}'),
            direction: DismissDirection.endToStart,
            background: const _DeleteBackground(),
            confirmDismiss: (_) => _confirmDelete(item),
            child: _ConversationRow(
              item: item,
              // 会话详情挂在「消息」分支的子路由上（切 Tab 不丢栈）；
              // 把列表行作为 extra 带过去，详情页无需再为标题/缩略图补一次请求。
              onTap: () => context.push(
                '/messages/${item.conversationId}',
                extra: item,
              ),
            ),
          );
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
      key: const ValueKey<String>('message-list-skeleton'),
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
  /// 参数：[item] 会话行数据；[onTap] 进入会话详情。
  const _ConversationRow({required this.item, required this.onTap});

  /// 会话行数据。
  final ConversationDto item;

  /// 进入会话详情。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
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
          const SizedBox(width: AppSpacing.sm),
          _PostThumb(url: item.postThumbnailUrl, gone: item.postGone),
        ],
      ),
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

/// 左滑会话行时露出的删除底（error 实底 + 白色图标与文字）。
class _DeleteBackground extends StatelessWidget {
  /// 构造删除底。
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color(AppColors.error),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.delete_outline,
            size: 20,
            color: Color(AppColors.surface),
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            '删除',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.surface),
            ),
          ),
        ],
      ),
    );
  }
}

/// 服务号行（R12 / R13）：永久置顶、无删除手势，点击进既有通知中心。
class _ServiceRow extends StatelessWidget {
  /// 构造服务号行。
  ///
  /// 参数：[unreadCount] 通知未读条数；[onTap] 点击进通知中心。
  const _ServiceRow({required this.unreadCount, required this.onTap});

  /// 通知未读条数（R9：本行显示条数并沿用 99+ 规则）。
  final int unreadCount;

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badge = unreadBadgeLabel(unreadCount);
    return InkWell(
      onTap: onTap,
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
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Color(AppColors.primary),
                shape: BoxShape.circle,
              ),
              child: const CustomPaint(
                size: Size.square(44),
                painter: _ServiceFootprintPainter(),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        '服务号',
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          fontWeight: FontWeight.w500,
                          color: Color(AppColors.textPrimary),
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: Color(AppColors.primaryLight),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          '置顶',
                          style: TextStyle(
                            fontSize: AppTypeScale.caption.size,
                            fontWeight: FontWeight.w600,
                            color: Color(AppColors.primaryDark),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    badge == null ? '查看系统通知' : '$badge 条未读通知',
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
            if (badge != null)
              Container(
                constraints: const BoxConstraints(minWidth: 18),
                height: 18,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Color(AppColors.error),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  badge,
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    fontWeight: FontWeight.w600,
                    color: Color(AppColors.surface),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 服务号头像内的品牌脚印（主色圆底 + 白色脚印，A3 同源）。
///
/// 变换与登录页 `_BrandFootprintPainter` 一致（72dp 基准
/// translate(36,33.5) rotate(14°) scale(0.52) translate(-54,-45)），
/// 按实际边长等比缩放；几何走共享真源 [FootprintGeometry]，不复制坐标。
class _ServiceFootprintPainter extends CustomPainter {
  const _ServiceFootprintPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double k = size.width / 72;
    canvas.save();
    canvas
      ..translate(36 * k, 33.5 * k)
      ..rotate(14 * math.pi / 180)
      ..scale(0.52 * k)
      ..translate(-54, -45);
    FootprintGeometry.paint(
      canvas,
      Paint()
        ..color = const Color(AppColors.surface)
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ServiceFootprintPainter oldDelegate) => false;
}

/// 帖子缩略图（R3 / R4）：44px；下架置灰并标注「已下架」，无图渲染占位块。
class _PostThumb extends StatelessWidget {
  /// 构造缩略图。
  ///
  /// 参数：[url] 首图签名 URL（可空）；[gone] 帖子是否已下架。
  const _PostThumb({required this.url, required this.gone});

  /// 首图 URL。
  final String? url;

  /// 帖子是否已下架。
  final bool gone;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Color(AppColors.background),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Color(AppColors.border)),
      ),
      alignment: Alignment.center,
      child: gone
          ? Text(
              '已\n下架',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                height: 1.2,
                color: Color(AppColors.textPlaceholder),
              ),
            )
          : url == null || url!.isEmpty
              ? Icon(
                  Icons.image_outlined,
                  size: 18,
                  color: Color(AppColors.textPlaceholder),
                )
              : Image.network(
                  url!,
                  fit: BoxFit.cover,
                  width: 44,
                  height: 44,
                  errorBuilder: (context, error, stack) => Icon(
                    Icons.image_outlined,
                    size: 18,
                    color: Color(AppColors.textPlaceholder),
                  ),
                ),
    );
  }
}

/// 顶部「通知未开启」提示（R16：被拒后常驻、可关闭、给系统设置入口）。
class _NotifyBanner extends StatelessWidget {
  /// 构造提示条。
  ///
  /// 参数：[onOpenSettings] 去设置；[onDismiss] 关闭提示。
  const _NotifyBanner({
    required this.onOpenSettings,
    required this.onDismiss,
  });

  /// 去系统设置。
  final VoidCallback onOpenSettings;

  /// 关闭提示。
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color(AppColors.primaryLight),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.notifications_off_outlined,
            size: 18,
            color: Color(AppColors.primaryDark),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '通知未开启，可能收不到新消息提醒',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.primaryDark),
              ),
            ),
          ),
          TextButton(
            onPressed: onOpenSettings,
            child: const Text('去设置'),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: Icon(
              Icons.close,
              size: 16,
              color: Color(AppColors.primaryDark),
            ),
            tooltip: '关闭提示',
          ),
        ],
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
              child: MessageBubbleIcon(
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
