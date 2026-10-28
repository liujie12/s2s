/// 我的发布页（PRD §8.3.1 / §8.6 状态机 / §10.1 `my-publish-screen`）。
///
/// 上游：[127] 后端段已交付 `GET /posts/mine`（分页 + `status` 单值筛选）与
/// `PATCH /posts/{id}/status`（乐观锁 + 幂等）。详情页接线见同条目
/// `features/detail/`。
///
/// **本轮接通的动作**（[B2-8] 转真后）：下架（`offline`）、编辑（`PATCH /posts/{id}`）、
/// 克隆重发（`POST /posts/{id}/repost`）、继续编辑（本地草稿恢复）。
/// **仍降级的一类**：删除（openapi 无 `DELETE /posts/{post_id}`，[B2-8] 裁定本轮不做，
/// 登记见说明文档 §2.9）。
///
/// **[B2-8] 转真要点**（裁定见《决策登记表》2026-10-13 B2-8 批）：
///   - **编辑**：先 `GET /posts/{id}` 预填表单，再以 `PublishScreenArgs.editPostId`
///     进发布页编辑态（提交走 PATCH，成功回本页刷新）；联系方式**不回显**（明文唯一
///     出口是 `/posts/{id}/contact`），编辑态留空即服务端「保留原密文」；
///   - **重发**：`POST /posts/{id}/repost` 取克隆草稿进发布页（**新建语义**）；
///     原分类被停用时先提示「该分类已停用，请重选分类」（PRD §8.7）；
///   - **搜索**：页内**本地筛选**（裁定：不新增网络请求），按标题/类目名过滤已加载列表；
///   - **草稿页签**：数据源改为**本地草稿**（PRD §8.7 纯客户端，`draft_store.dart`），
///     卡片动作 `[继续编辑, 删除]`（此处「删除」删的是本地草稿，真实生效）。
///
/// **降级按钮按设计稿原样呈现**（稿是 UI 冻结对象），点击给出「本期内测版暂未开放」
/// 的明确说明 —— 不留一个点了没反应的死按钮（说明文档 [74] 教训）。
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
import '../publish/draft_store.dart';
import '../publish/publish_form_state.dart';
import '../publish/publish_screen_args.dart';
import 'my_posts_provider.dart';
import 'post_dto.dart';
import 'post_repository.dart';
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

  /// 页内搜索关键词（[B2-8] 裁定：本地筛选，不新增网络请求）。
  ///
  /// 空串 = 未筛选。它只作用于**已加载**的列表项 —— 语义是「在当前页里找」，
  /// 与「全站搜索」是两件事（PRD §8.3.1 只给了本页一个搜索图标）。
  String _searchQuery = '';

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

  /// 执行卡片动作（[B2-8]：按动作分派到各自的真通道）。
  ///
  /// 参数：[action] 卡片动作；[item] 该动作所属的列表项（带乐观锁版本号）。
  /// 返回：[Future<void>]。
  Future<void> _onAction(MyPostCardAction action, MyPostItemDto item) async {
    switch (action) {
      case MyPostCardAction.remove:
        // 唯一仍降级的动作：不承诺版本号，只说本期状态
        //（说「后续版本」等于替未排期的事打包票）。
        _showMessage('${_actionLabel(action)}功能本期内测版暂未开放');
      case MyPostCardAction.offline:
        await _changeStatus(action, item);
      case MyPostCardAction.edit:
        await _openEdit(item);
      case MyPostCardAction.repost:
        await _openRepost(item);
      case MyPostCardAction.continueEdit:
        // 该动作只出现在「草稿」页签的本地草稿卡片上（不走本方法，
        // 见 _buildDraftList 的 onContinue）；此处不可达，留空分支让 switch 穷尽。
        break;
    }
  }

  /// 状态变更（下架 / 上架类动作，走 `PATCH /posts/{id}/status`）。
  ///
  /// 参数：[action] 契约动作；[item] 列表项。
  /// 返回：[Future<void>]。
  Future<void> _changeStatus(MyPostCardAction action, MyPostItemDto item) async {
    try {
      await ref
          .read(myPostsProvider.notifier)
          .changeStatus(
            postId: item.id,
            action: action.apiAction!,
            version: item.version,
          );
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

  /// 编辑既有帖（[B2-8]）：取详情预填表单 → 进发布页编辑态 → 返回后刷新。
  ///
  /// 参数：[item] 目标列表项（提供帖 ID 与乐观锁版本）。
  /// 返回：[Future<void>]。
  Future<void> _openEdit(MyPostItemDto item) async {
    try {
      // 列表项不含描述/属性/媒体/坐标，编辑态需要全量字段，故先取详情。
      final detail = await ref.read(postRepositoryProvider).fetchDetail(item.id);
      if (!mounted) return;
      final saved = await context.push<bool>(
        AppRoutes.publish,
        extra: PublishScreenArgs(
          initialForm: _formFromDetail(detail),
          // 编辑态回显媒体缩略图：表单只带 media_id，媒体段还需要 URL。
          initialMedia: [
            for (final media in detail.media)
              (mediaId: media.mediaId, url: media.url),
          ],
          editPostId: item.id,
          // 版本取自**列表项**：详情 DTO 不解析 version（它的消费面是只读展示）。
          editVersion: item.version,
        ),
      );
      if (!mounted) return;
      if (saved == true) {
        await ref.read(myPostsProvider.notifier).refresh();
        if (mounted) _showMessage('已保存');
      }
    } catch (e) {
      if (mounted) _showMessage(asApiException(e).uiMessage);
    }
  }

  /// 克隆重发（[B2-8]）：取克隆草稿 → 进发布页（新建语义）→ 返回后刷新。
  ///
  /// 参数：[item] 目标列表项。
  /// 返回：[Future<void>]。
  Future<void> _openRepost(MyPostItemDto item) async {
    try {
      final draft = await ref.read(postRepositoryProvider).repost(item.id);
      if (!mounted) return;
      if (!draft.categoryAvailable) {
        // PRD §8.7「重发分类变动」：原分类被运营停用，先告知再进编辑态
        //（用户可在发布页重选分类）。
        _showMessage('该分类已停用，请重选分类');
      }
      await context.push<bool>(
        AppRoutes.publish,
        extra: PublishScreenArgs(
          initialForm: _formFromRepost(draft),
          // 克隆草稿只回 media_ids、没有 URL：仍入列以保住计数与提交载荷，
          // 缩略图退化为占位图标（避免「新增一张就把原媒体全冲掉」）。
          initialMedia: [
            for (final mediaId in draft.mediaIds)
              (mediaId: mediaId, url: ''),
          ],
        ),
      );
      if (!mounted) return;
      // 重发是新建语义（走 POST /posts），成功后会进完成页；返回列表时刷新。
      await ref.read(myPostsProvider.notifier).refresh();
    } catch (e) {
      if (mounted) _showMessage(asApiException(e).uiMessage);
    }
  }

  /// 打开页内搜索（本地筛选）：输入关键词并按标题/类目名过滤已加载列表。
  ///
  /// 返回：[Future<void>]。
  Future<void> _openSearch() async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _SearchDialog(initialQuery: _searchQuery),
    );
    if (!mounted || result == null) return;
    setState(() => _searchQuery = result.trim());
  }

  /// 按当前搜索词本地过滤列表项（标题或类目路径任一命中即保留）。
  ///
  /// 参数：[items] 已加载的列表项。
  /// 返回：[List] 过滤后的列表；搜索词为空时原样返回。
  List<MyPostItemDto> _filteredItems(List<MyPostItemDto> items) {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return items;
    return items.where((item) {
      if (item.title.toLowerCase().contains(query)) return true;
      final leafId = item.leafCategoryId;
      if (leafId == null) return false;
      // 类目路径（一级→三级）任一名称命中即匹配：用户可能记得大类名而非叶子名。
      return categoryPathOf(leafId).any(
        (node) => node.name.toLowerCase().contains(query),
      );
    }).toList();
  }

  /// 把详情 DTO 映射为发布页表单（[B2-8] 编辑态预填）。
  ///
  /// 参数：[detail] `GET /posts/{id}` 出参。
  /// 返回：[PublishFormState]；联系方式**留空**（明文不回显，见文件头）。
  PublishFormState _formFromDetail(PostDetailDto detail) {
    return PublishFormState(
      kind: detail.type == 'demand' ? PublishKind.demand : PublishKind.supply,
      leafCategoryId: detail.leafCategoryId,
      lng: detail.lng,
      lat: detail.lat,
      doorNumber: detail.address ?? '',
      title: detail.title,
      priceText: detail.price == null ? '' : _priceTextOf(detail.price!),
      priceUnit: detail.priceUnit,
      description: detail.description ?? '',
      templateValues: _stringAttributes(detail.attributes),
      mediaIds: [for (final media in detail.media) media.mediaId],
      contact: '',
    );
  }

  /// 把克隆重发草稿映射为发布页表单（[B2-8] 重发态预填）。
  ///
  /// 参数：[draft] `POST /posts/{id}/repost` 出参。
  /// 返回：[PublishFormState]；联系方式**留空** —— 发布契约要求 `contact_value`
  ///   必填且明文不回显，用户须重新填写（安全收窄，见《决策登记表》B2-8 批）。
  PublishFormState _formFromRepost(RepostDraftDto draft) {
    return PublishFormState(
      kind: draft.type == 'demand' ? PublishKind.demand : PublishKind.supply,
      leafCategoryId: draft.leafCategoryId,
      lng: draft.lng,
      lat: draft.lat,
      doorNumber: draft.address ?? '',
      title: draft.title,
      priceText: draft.price == null ? '' : _priceTextOf(draft.price!),
      priceUnit: draft.priceUnit,
      description: draft.description ?? '',
      templateValues: _stringAttributes(draft.attributes ?? const {}),
      mediaIds: draft.mediaIds,
      contact: '',
    );
  }

  /// 把契约 `attributes`（Object? 值）转为表单的 `Map<String, String>`。
  ///
  /// 参数：[attributes] 动态属性（可空值）。
  /// 返回：[Map] 仅含非空值的字符串属性。
  Map<String, String> _stringAttributes(Map<String, Object?> attributes) {
    return {
      for (final entry in attributes.entries)
        if (entry.value != null) entry.key: entry.value.toString(),
    };
  }

  /// 价格数字转输入框文本（整数不带小数点，贴合用户输入习惯）。
  ///
  /// 参数：[price] 价格（元）。
  /// 返回：[String] 如 `50` / `49.5`。
  String _priceTextOf(double price) {
    return price == price.roundToDouble()
        ? price.toInt().toString()
        : price.toString();
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
            // [B2-8] 转真：页内本地筛选（裁定不新增网络请求）。
            onPressed: _openSearch,
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
            // 「草稿」页签的数据源是**本地草稿**（PRD §8.7 纯客户端），
            // 与服务端的帖子列表是两条互不相干的来源，故在此分叉。
            child: tab == MyPostsTab.draft
                ? _buildDrafts()
                : postsAsync.when(
                    loading: () => const _SkeletonList(),
                    error: (error, _) => _ErrorView(
                      error: asApiException(error),
                      onRetry: () =>
                          ref.read(myPostsProvider.notifier).refresh(),
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
    final items = _filteredItems(data.items);
    if (items.isEmpty) {
      // 有数据但被搜索词滤空：给可解释的空态，而不是复用「还没发布」文案
      //（后者会让用户以为自己的帖子没了）。
      return _NoMatchView(query: _searchQuery);
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(myPostsProvider.notifier).refresh(),
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.all(AppSpacing.lg),
        // 末行固定为分页终态（设计稿 listEndRow「没有更多了」）
        itemCount: items.length + 1,
        itemBuilder: (context, index) {
          if (index == items.length) {
            return _ListEndRow(hasMore: data.hasMore);
          }
          final item = items[index];
          return _MyPostCard(
            item: item,
            onAction: (action) => _onAction(action, item),
          );
        },
      ),
    );
  }

  /// 组装「草稿」页签列表（数据源 = 本地草稿，见 `draft_store.dart`）。
  ///
  /// 返回：[Widget]。
  Widget _buildDrafts() {
    final draftsAsync = ref.watch(draftListProvider);
    return draftsAsync.when(
      loading: () => const _SkeletonList(),
      error: (error, _) => _ErrorView(
        error: asApiException(error),
        onRetry: () => ref.invalidate(draftListProvider),
      ),
      data: (drafts) {
        if (drafts.isEmpty) return const _EmptyView(tab: MyPostsTab.draft);
        return ListView.builder(
          padding: const EdgeInsets.all(AppSpacing.lg),
          itemCount: drafts.length,
          itemBuilder: (context, index) {
            final draft = drafts[index];
            return _DraftCard(
              snapshot: draft,
              onContinue: () => _continueDraft(draft),
              onRemove: () => _removeDraft(draft),
            );
          },
        );
      },
    );
  }

  /// 继续编辑一份本地草稿：恢复表单进发布页（**新建语义**，非编辑既有帖）。
  ///
  /// 参数：[snapshot] 草稿快照。
  /// 返回：[Future<void>]。
  Future<void> _continueDraft(DraftSnapshot snapshot) async {
    await context.push<bool>(
      AppRoutes.publish,
      extra: PublishScreenArgs(initialForm: snapshot.form),
    );
    if (!mounted) return;
    // 发布成功会清空草稿；返回时刷新草稿列表以反映最新状态。
    ref.invalidate(draftListProvider);
  }

  /// 删除一份本地草稿（**真实生效** —— 删的是本地存储，非「本期暂未开放」）。
  ///
  /// 参数：[snapshot] 草稿快照。
  /// 返回：[Future<void>]。
  Future<void> _removeDraft(DraftSnapshot snapshot) async {
    await ref.read(draftStoreProvider).remove(snapshot.draftId);
    ref.invalidate(draftListProvider);
    if (mounted) _showMessage('已删除草稿');
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
    // 二级 → 一级 → 中性：与地图 Pin / 列表卡同一份字形表，三处必须一致。
    final icon = l2CategoryIcon(leafId) ?? category?.icon ?? neutralCategoryIcon;
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
                      // 副标题 = 完整度 · 浏览 · 收藏 · 发布时间（R7）：
                      // 计数只在帖主视角出现，故这里是浏览/收藏数唯一的渲染处。
                      _CardSubtitle(item: item),
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        // 无价格显示「面议」而非留空（§5.8 允许价格为空）
                        _priceLabel(item),
                        style: TextStyle(
                          fontSize: AppTypeScale.small.size,
                          fontWeight: FontWeight.w700,
                          color: Color(AppColors.accent),
                        ),
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
              // 草稿页签自 [B2-8] 起有数据源（本地草稿），空态文案改为
              //「还没有草稿」—— 原来的「本期内测版暂未开放」已不成立。
              isDraft ? '还没有草稿' : '还没发布，立即发一条',
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

/// 页内搜索弹层（[B2-8] 本地筛选）。
///
/// **为什么单列成 StatefulWidget 而不是在调用处 new 一个 controller**：
/// `showDialog` 的关闭有动画，调用处在 `await` 返回后立刻 dispose 控制器，
/// 弹层在退场动画里仍会重建并读它 —— 直接抛出「controller used after dispose」。
/// 把控制器交给弹层自己的 State 管理，生命周期与弹层一致。
class _SearchDialog extends StatefulWidget {
  /// 构造搜索弹层。
  ///
  /// 参数：[initialQuery] 当前搜索词（回填输入框，便于用户改词）。
  const _SearchDialog({required this.initialQuery});

  /// 当前搜索词。
  final String initialQuery;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialQuery);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('搜索我的发布'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '输入标题或类目关键词'),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          // 空串 = 清除筛选（回到全部已加载项）
          onPressed: () => Navigator.of(context).pop(''),
          child: const Text('清除'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('搜索'),
        ),
      ],
    );
  }
}

/// 本地草稿卡片（[B2-8]「草稿」页签；数据源见 `draft_store.dart`）。
///
/// 与 [_MyPostCard] 分开：草稿**不是帖子**（无 id/状态/类目色条），共用卡片
/// 只会逼出一堆恒空字段；两张卡的形状差异远大于共性。
class _DraftCard extends StatelessWidget {
  /// 构造草稿卡片。
  ///
  /// 参数：[snapshot] 草稿快照；[onContinue] 继续编辑；[onRemove] 删除草稿。
  const _DraftCard({
    required this.snapshot,
    required this.onContinue,
    required this.onRemove,
  });

  /// 草稿快照。
  final DraftSnapshot snapshot;

  /// 继续编辑回调。
  final VoidCallback onContinue;

  /// 删除回调。
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final title = snapshot.form.title.trim();
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.isEmpty ? '未命名草稿' : title,
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
            '保存于 ${formatRelativeAge(snapshot.savedAt)}',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: onContinue,
                child: Text(_actionLabel(MyPostCardAction.continueEdit)),
              ),
              TextButton(
                onPressed: onRemove,
                child: Text(_actionLabel(MyPostCardAction.remove)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 搜索无匹配空态（[B2-8] 页内本地筛选）。
///
/// 与 [_EmptyView] 分开：用户在有数据时搜不到，最怕的是「我的帖子是不是没了」，
/// 故文案必须点明是**搜索词**没匹配，而不是「你没有内容」。
class _NoMatchView extends StatelessWidget {
  /// 构造无匹配空态。
  ///
  /// 参数：[query] 当前搜索词。
  const _NoMatchView({required this.query});

  /// 当前搜索词。
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Text(
          '没有匹配「$query」的内容',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            color: Color(AppColors.textSecondary),
          ),
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
  MyPostCardAction.repost => '刷新重发',
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
/// 除「在架」「已过期」外（含下架/归档与契约外取值）一律取中性灰：
/// 它们对用户的差别只在文案，颜色替它们编造差异反而会让灰变成「有含义的颜色」。
///
/// 参数：[apiStatus] 契约状态值。
/// 返回：[(色点/底色, 文字色)]。
(Color, Color) _statusColors(String apiStatus) => switch (apiStatus) {
  PostApiStatus.active => (Color(AppColors.success), Color(AppColors.successText)),
  PostApiStatus.expired => (Color(AppColors.warning), Color(AppColors.warningText)),
  _ => (
    Color(AppColors.textPlaceholder),
    Color(AppColors.textSecondary),
  ),
};

/// 完整度档位选择器（0/1/2 → 双色；PRD §9.8 三档视觉标记）。
///
/// **契约外档位刻意 fail-fast**（[CompletenessLevel.fromApi] 抛 `ApiException.parse`）：
/// 完整度是发布质量的主信号，给个错色点比当屏报错更糟——用户会据此判断「这条信息
/// 齐不齐」。风险面已评估：`completeness_level` 是库内 STORED 生成列、契约枚举锁定
/// 0/1/2，服务端不会送出第三个值；真的送出说明契约或库被改坏，当屏失败是期望行为。
///
/// 参数：[level] 契约 `completeness_level`。
/// 返回：[(圆点色, 文字色)]。
(Color, Color) _completenessColors(int level) {
  final parsed = CompletenessLevel.fromApi(level);
  return switch (parsed) {
    CompletenessLevel.green => (
      Color(AppColors.success),
      Color(AppColors.successText),
    ),
    CompletenessLevel.yellow => (
      Color(AppColors.warning),
      Color(AppColors.warningText),
    ),
    CompletenessLevel.red => (Color(AppColors.error), Color(AppColors.errorText)),
  };
}

/// 卡片副标题：「● 完整 👁 42 ☆ 3｜3 天前发布」（R7 / R8 / KTD10）。
///
/// 计数三态：`null` = 字段缺失（防御分支，整组隐藏）；`0` = 真实 0，照常
/// 显示图标 + `0`；正整数显示数字。整行 `maxLines: 1` + 省略号，数字再长
/// 也不撑高卡片。
class _CardSubtitle extends StatelessWidget {
  const _CardSubtitle({required this.item});

  /// 列表项（本人视角，计数非空即真实值）。
  final MyPostItemDto item;

  @override
  Widget build(BuildContext context) {
    final parsed = CompletenessLevel.fromApi(item.completenessLevel);
    final (dotColor, labelColor) = _completenessColors(item.completenessLevel);
    final published = item.publishAt == null
        ? null
        : formatRelativePublishAge(item.publishAt!);
    final views = item.viewCount;
    final favorites = item.favoriteCount;
    final caption = TextStyle(
      fontSize: AppTypeScale.caption.size,
      color: Color(AppColors.textSecondary),
    );
    final iconColor = Color(AppColors.textSecondary);

    return Text.rich(
      TextSpan(
        children: [
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
              ),
            ),
          ),
          TextSpan(
            text: ' ${parsed.label}',
            style: TextStyle(color: labelColor),
          ),
          // 计数按「字段存在才渲染」：null 是契约缺字段的防御分支，
          // 渲染成 0 会把「没有数据源」说成「没人看过」。
          if (views != null) ...[
            const TextSpan(text: '  '),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(Icons.visibility_outlined, size: 12, color: iconColor),
            ),
            TextSpan(text: ' $views'),
          ],
          if (favorites != null) ...[
            const TextSpan(text: '  '),
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Icon(Icons.star_border, size: 12, color: iconColor),
            ),
            TextSpan(text: ' $favorites'),
          ],
          if (published != null) TextSpan(text: '｜$published'),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: caption,
    );
  }
}

/// 卡片价格文案（无价格显示「面议」，与详情页同一实现处）。
///
/// 参数：[item] 列表项。
/// 返回：[String] 价格文案。
String _priceLabel(MyPostItemDto item) =>
    formatPriceLabel(item.price, item.priceUnit) ?? '面议';
