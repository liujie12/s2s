/// 我的发布页（PRD §8.3.1 / §8.6 状态机 / §10.1 `my-publish-screen`）。
///
/// 上游：[127] 后端段已交付 `GET /posts/mine`（分页 + `status` 单值筛选）与
/// `PATCH /posts/{id}/status`（乐观锁 + 幂等）。详情页接线见同条目
/// `features/detail/`。
///
/// **本轮接通的动作**：下架（`offline`）、刷新重发（`republish`）。
/// **本轮降级的三类**（Batch1 无契约/无数据源，登记见说明文档 §2.9）：
///   - 编辑 / 继续编辑：依赖 Batch2 的 `PATCH /posts/{id}`（openapi 占位）
///     与发布页编辑态（本轮未做）；
///   - 删除：openapi 无 `DELETE /posts/{post_id}`；
///   - 顶部「搜索」：设计稿 `FLOW_LINKS` 未给它跳转边（无目标页）；
///   - 「草稿」页签：服务端不存 `draft`（PRD §8.7），本地草稿属 Batch2。
/// 降级按钮**按设计稿原样呈现**（稿是 UI 冻结对象），点击给出「本期内测版
/// 暂未开放」的明确说明 —— 不留一个点了没反应的死按钮（说明文档 [74] 教训：
/// 「立即补齐」承诺了一件做不到的事）。
///
/// **契约缺口一并未做**：PRD §5.11「一键刷新续 7 天」对应契约 `action=renew`，
/// 但设计稿本页操作组无此按钮，按「不新增稿外按钮」本轮不呈现，缺口登记 §2.9。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../core/time_format.dart';
import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category_style.dart';
import '../../domain/listing_detail.dart';
import '../../router/app_router.dart';
import 'my_posts_provider.dart';
import 'post_dto.dart';
import 'post_status.dart';

/// 我的发布页。
class MyPublishScreen extends ConsumerStatefulWidget {
  /// 构造我的发布页。
  const MyPublishScreen({super.key});

  @override
  ConsumerState<MyPublishScreen> createState() => _MyPublishScreenState();
}

class _MyPublishScreenState extends ConsumerState<MyPublishScreen> {
  /// 列表滚动控制器（触底加载下一页；§8.3.1 列表分页）。
  final ScrollController _scrollController = ScrollController();

  /// 触底判定余量（像素）：提前一屏约 1/4 触发，避免用户等到底部才加载。
  static const double _loadMoreThreshold = 200;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  /// 滚动监听：接近底部时加载下一页。
  ///
  /// 返回：void。
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - _loadMoreThreshold) {
      unawaited(_loadMore());
    }
  }

  /// 加载下一页；失败只提示不清屏（已加载内容保留）。
  ///
  /// 返回：[Future<void>]。
  Future<void> _loadMore() async {
    try {
      await ref.read(myPostsProvider.notifier).loadMore();
    } catch (e) {
      if (mounted) _showMessage(asApiException(e).uiMessage);
    }
  }

  /// 执行卡片动作：已接通动作调真接口，降级动作给出明确说明。
  ///
  /// 参数：[action] 卡片动作；[item] 该动作所属的列表项（带乐观锁版本号）。
  /// 返回：[Future<void>]。
  Future<void> _onAction(MyPostCardAction action, MyPostItemDto item) async {
    final apiAction = action.apiAction;
    if (apiAction == null) {
      // 降级动作：不承诺版本号，只说本期状态（说「后续版本」等于替未排期的事打包票）
      _showMessage('${_actionLabel(action)}功能本期内测版暂未开放');
      return;
    }
    try {
      await ref
          .read(myPostsProvider.notifier)
          .changeStatus(postId: item.id, action: apiAction, version: item.version);
      _showMessage('已${_actionLabel(action)}');
    } catch (e) {
      final apiError = asApiException(e);
      if (apiError.code == ApiErrorCode.versionConflict) {
        // 契约 description：0 行统一回 40903，客户端必须**重取**后由用户重试。
        // 这里立刻重取，让卡片显示权威状态与新版本号（用户不会再点一次旧版本）。
        await ref.read(myPostsProvider.notifier).refresh();
      }
      if (mounted) _showMessage(apiError.uiMessage);
    }
  }

  /// 顶部提示（§11.4 唯一回显格式由 [ApiException.uiMessage] 承载）。
  ///
  /// 参数：[text] 提示文案。
  /// 返回：void。
  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(myPostsTabProvider);
    final postsAsync = ref.watch(myPostsProvider);

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Color(AppColors.textPrimary)),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go(AppRoutes.home),
        ),
        title: Text(
          '我的发布',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.search, color: Color(AppColors.textPrimary)),
            // 降级：设计稿 navBar 有「搜索」但 FLOW_LINKS 无该跳转边（无目标页）
            onPressed: () => _showMessage('搜索功能本期内测版暂未开放'),
          ),
        ],
      ),
      body: Column(
        children: [
          _TabBar(
            current: tab,
            onSelect: (next) =>
                ref.read(myPostsTabProvider.notifier).select(next),
          ),
          Expanded(
            child: postsAsync.when(
              loading: () => const _SkeletonList(),
              error: (error, _) => _ErrorView(
                error: asApiException(error),
                onRetry: () => ref.read(myPostsProvider.notifier).refresh(),
              ),
              data: (data) => _buildList(tab, data),
            ),
          ),
        ],
      ),
    );
  }

  /// 组装列表体（三态中的 data 态：空态 / 卡片列表 + 分页终态）。
  ///
  /// 参数：[tab] 当前页签；[data] 已加载数据。
  /// 返回：[Widget]。
  Widget _buildList(MyPostsTab tab, MyPostsData data) {
    if (data.items.isEmpty) {
      return _EmptyView(tab: tab);
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(myPostsProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(AppSpacing.lg),
        // 末行固定为分页终态（设计稿 listEndRow「没有更多了」）
        itemCount: data.items.length + 1,
        itemBuilder: (context, index) {
          if (index == data.items.length) {
            return _ListEndRow(hasMore: data.hasMore);
          }
          final item = data.items[index];
          return _MyPostCard(
            item: item,
            onAction: (action) => _onAction(action, item),
          );
        },
      ),
    );
  }
}

/// 四页签切换条（PRD §8.3.1 筛选 Tab）。
class _TabBar extends StatelessWidget {
  const _TabBar({required this.current, required this.onSelect});

  /// 当前页签。
  final MyPostsTab current;

  /// 选中回调。
  final ValueChanged<MyPostsTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color(AppColors.surface),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      child: Row(
        children: [
          for (final tab in MyPostsTab.values)
            Expanded(
              child: InkWell(
                onTap: () => onSelect(tab),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: 2,
                        color: tab == current
                            ? Color(AppColors.primary)
                            : Colors.transparent,
                      ),
                    ),
                  ),
                  child: Text(
                    tab.label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      fontWeight: tab == current
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: tab == current
                          ? Color(AppColors.primary)
                          : Color(AppColors.textSecondary),
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

/// 单条「我的发布」卡片（设计稿：色条 · 缩略图 · 信息 · 状态标 + 卡内操作组）。
class _MyPostCard extends StatelessWidget {
  const _MyPostCard({required this.item, required this.onAction});

  /// 列表项（契约 `MyPostItem`）。
  final MyPostItemDto item;

  /// 动作回调。
  final ValueChanged<MyPostCardAction> onAction;

  @override
  Widget build(BuildContext context) {
    // 分类查表失败取中性色（详设 §10.4.1 降级取向：不兜底成某个真实分类色）
    final leafId = item.leafCategoryId;
    final category = leafId == null ? null : topCategoryOf(leafId);
    final accent = category?.color ?? neutralCategoryColor;
    final deep = category?.deepColor ?? neutralCategoryColor;
    final icon = category?.icon ?? neutralCategoryIcon;
    final actions = cardActionsFor(item.status);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Color(AppColors.border)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧分类色条：与地图 Pin、列表卡片同一套配色（PRD §6.4.2）
                Container(
                  width: 4,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                // 缩略图位：设计稿用分类色块占位（媒体上传链路未接通，
                // 发布侧 `media_ids` 恒空，见 publish_form_state 说明）
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Icon(icon, size: 22, color: deep),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          fontWeight: FontWeight.w600,
                          color: Color(AppColors.textPrimary),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        _subtitle(item),
                        style: TextStyle(
                          fontSize: AppTypeScale.caption.size,
                          color: Color(AppColors.textSecondary),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          Text(
                            // 无价格显示「面议」而非留空（§5.8 允许价格为空）
                            _priceLabel(item),
                            style: TextStyle(
                              fontSize: AppTypeScale.small.size,
                              fontWeight: FontWeight.w700,
                              color: Color(AppColors.accent),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          _CompletenessDot(level: item.completenessLevel),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _StatusChip(apiStatus: item.status),
              ],
            ),
          ),
          // 分隔线把「信息」与「操作」隔开：同色同底两行紧贴时按钮会被读成正文
          Divider(height: 1, color: Color(AppColors.border)),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (final action in actions)
                  Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: TextButton(
                      onPressed: () => onAction(action),
                      child: Text(_actionLabel(action)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态标（设计稿：在架绿 / 下架灰 / 草稿黄）。
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.apiStatus});

  /// 契约状态值（[PostApiStatus]）。
  final String apiStatus;

  @override
  Widget build(BuildContext context) {
    final (Color dot, Color text) = _statusColors(apiStatus);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: dot.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        _statusLabel(apiStatus),
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          fontWeight: FontWeight.w600,
          color: text,
        ),
      ),
    );
  }
}

/// 完整度档位点（PRD §9.8 三档视觉标记；卡片只给「色点 + 档名」双通道）。
class _CompletenessDot extends StatelessWidget {
  const _CompletenessDot({required this.level});

  /// 契约 `completeness_level`(0/1/2)。
  final int level;

  @override
  Widget build(BuildContext context) {
    final parsed = CompletenessLevel.fromApi(level);
    final (int dot, int text) = switch (parsed) {
      CompletenessLevel.green => (AppColors.success, AppColors.successText),
      CompletenessLevel.yellow => (AppColors.warning, AppColors.warningText),
      CompletenessLevel.red => (AppColors.error, AppColors.errorText),
    };
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: Color(dot), shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          parsed.label,
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: Color(text),
          ),
        ),
      ],
    );
  }
}

/// 分页终态行（设计稿 listEndRow；还有下一页时显示加载提示）。
class _ListEndRow extends StatelessWidget {
  const _ListEndRow({required this.hasMore});

  /// 是否还有下一页。
  final bool hasMore;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Center(
        child: hasMore
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                '没有更多了',
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  color: Color(AppColors.textPlaceholder),
                ),
              ),
      ),
    );
  }
}

/// 首屏加载骨架（详设 §15.3：**首屏不用转圈**，转圈会让「慢」被感知为「卡」）。
class _SkeletonList extends StatelessWidget {
  const _SkeletonList();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppSpacing.lg),
      itemCount: 3,
      itemBuilder: (context, index) => Container(
        height: 96,
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: Color(AppColors.border)),
        ),
      ),
    );
  }
}

/// 空态（PRD §8.3.1 空状态 + 草稿页签的降级说明）。
class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.tab});

  /// 当前页签（草稿页签文案不同）。
  final MyPostsTab tab;

  @override
  Widget build(BuildContext context) {
    final isDraft = !tab.hasDataSource;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 鸭子 IP 的 SVG 资产未接入（同 login_screen 的 TODO(M4-4)），
            // 先用几何占位 —— 灰块会被读成「图没加载出来」，故用带色图标。
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: Color(AppColors.primaryLight),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isDraft ? Icons.drafts_outlined : Icons.inbox_outlined,
                size: 34,
                color: Color(AppColors.primary),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              isDraft ? '草稿箱本期内测版暂未开放' : '还没发布，立即发一条',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
            if (!isDraft) ...[
              const SizedBox(height: AppSpacing.md),
              FilledButton(
                onPressed: () => context.push(AppRoutes.publish),
                style: FilledButton.styleFrom(
                  backgroundColor: Color(AppColors.primary),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
                child: const Text('去发布'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 错误态（详设 §15.3：按 §12.2 行为分类渲染 —— 确定性失败只给文案，
/// 其余给重试入口；`42907` 的倒计时不适用于本端点，契约未为 `/posts/mine`
/// 声明 429）。
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.error, required this.onRetry});

  /// 归一后的业务异常（[asApiException]）。
  final ApiException error;

  /// 重试回调。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final behavior = error.code.behavior;
    final retryable = behavior != ErrBehavior.deterministicFail &&
        behavior != ErrBehavior.none;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.cloud_off_outlined,
            size: 48,
            color: Color(AppColors.textPlaceholder),
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              // §11.4 UI 报错唯一回显格式（message（request_id））
              error.uiMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ),
          if (retryable) ...[
            const SizedBox(height: AppSpacing.md),
            OutlinedButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ],
      ),
    );
  }
}

// ── 展示文案（唯一落点：与设计稿逐字对齐，探针「稿↔码对数」按本文件取字面量） ──

/// 动作按钮文案（设计稿 `buildMyPublish` 的按钮字面量）。
///
/// 参数：[action] 卡片动作。
/// 返回：[String] 按钮文案。
String _actionLabel(MyPostCardAction action) => switch (action) {
  MyPostCardAction.edit => '编辑',
  MyPostCardAction.offline => '下架',
  MyPostCardAction.republish => '刷新重发',
  MyPostCardAction.remove => '删除',
  MyPostCardAction.continueEdit => '继续编辑',
};

/// 状态标文案。
///
/// `expired`/`archived` 不与 `offline` 合并：三者在「全部」页签同屏出现，
/// 合并会让用户看不出「到期了」还是「被我下架了」（设计稿只画了在架/已下架，
/// 这两个取值是契约有而稿未覆盖的部分，登记见说明文档 §2.9）。
///
/// 参数：[apiStatus] 契约状态值。
/// 返回：[String] 状态文案。
String _statusLabel(String apiStatus) => switch (apiStatus) {
  PostApiStatus.active => '在架',
  PostApiStatus.offline => '已下架',
  PostApiStatus.expired => '已过期',
  PostApiStatus.archived => '已归档',
  _ => '未知状态',
};

/// 状态标配色（图形色 + 承载文字的深色变体，同 design_tokens 的 *-text 约定）。
///
/// 参数：[apiStatus] 契约状态值。
/// 返回：[(色点/底色, 文字色)]。
(Color, Color) _statusColors(String apiStatus) => switch (apiStatus) {
  PostApiStatus.active => (Color(AppColors.success), Color(AppColors.successText)),
  PostApiStatus.expired => (Color(AppColors.warning), Color(AppColors.warningText)),
  PostApiStatus.offline ||
  PostApiStatus.archived => (
    Color(AppColors.textPlaceholder),
    Color(AppColors.textSecondary),
  ),
  _ => (
    Color(AppColors.textPlaceholder),
    Color(AppColors.textSecondary),
  ),
};

/// 卡片副标题：「浏览 N｜3 天前发布」。
///
/// `view_count` Batch1 恒 null（浏览计数随 [129] 埋点落库），此时**不显示
/// 「浏览 0」**——那是把「没有数据源」说成「没人看过」，会把发布者劝退。
///
/// 参数：[item] 列表项。
/// 返回：[String] 副标题文案。
String _subtitle(MyPostItemDto item) {
  final publishAt = item.publishAt;
  final age = publishAt == null ? null : formatRelativeAge(publishAt);
  final published = age == null
      ? null
      : (age == '刚刚' ? '刚刚发布' : '$age发布');
  final views = item.viewCount;
  if (views == null) return published ?? '发布时间未知';
  return published == null ? '浏览 $views' : '浏览 $views｜$published';
}

/// 卡片价格文案（无价格显示「面议」，与详情页同一实现处）。
///
/// 参数：[item] 列表项。
/// 返回：[String] 价格文案。
String _priceLabel(MyPostItemDto item) =>
    formatPriceLabel(item.price, item.priceUnit) ?? '面议';
