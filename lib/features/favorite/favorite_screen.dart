/// 我的收藏页（PRD §8.3.2 `my-favorite-screen`；[B2-11]）。
///
/// 结构（对齐设计稿 `buildMyFavorite`）：导航「我的收藏」+ 三格分段 Tab
/// （资源/需求/全部）→ 收藏卡片列表 → 收尾条「没有更多了」。
///
/// 卡片副标题 = 类目面包屑（契约 `category_path`）· 价格文案；设计稿原含「距离」，
/// 但收藏列表无定位中心、契约亦无该字段，故**不显示距离**（口径见 DEC-31 记录）。
/// 取消收藏按 PRD §8.3.2 提供「点星标」入口，点击后先弹二次确认再提交。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../detail/detail_screen.dart';
import 'favorite_dto.dart';
import 'favorite_provider.dart';

/// 我的收藏页。
class FavoriteScreen extends ConsumerStatefulWidget {
  /// 构造我的收藏页。
  const FavoriteScreen({super.key});

  @override
  ConsumerState<FavoriteScreen> createState() => _FavoriteScreenState();
}

/// 我的收藏页状态（持滚动控制器做触底加载）。
class _FavoriteScreenState extends ConsumerState<FavoriteScreen> {
  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // 收藏可能在其他页面（详情页）新增：复用已加载快照时标脏，
    // 由 provider 重建走 build() 重拉，保证列表与「我的」页收藏总数一致。
    // 必须放到首帧之后：initState 里改 provider 会触发
    // 「markNeedsBuild() called during build」红屏。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (ref.read(favoritesProvider).hasValue) {
        ref.invalidate(favoritesProvider);
      }
    });
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

  /// 加载下一页并吞掉异常（失败保留已加载数据，由页面底部提示）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _loadMoreSafely() async {
    try {
      await ref.read(favoritesProvider.notifier).loadMore();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asApiException(e).uiMessage)),
      );
    }
  }

  /// 点星标取消收藏：先二次确认，确认后才提交并提示失败。
  ///
  /// 参数：[item] 待取消的收藏项（标题用于确认文案）。
  /// 返回：[Future<void>]。
  Future<void> _remove(FavoriteItemDto item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('取消收藏'),
        content: Text('确定要取消收藏「${item.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              '取消收藏',
              style: TextStyle(color: Color(AppColors.errorText)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(favoritesProvider.notifier).remove(item.postId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(asApiException(e).uiMessage)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final tab = ref.watch(favoriteTabProvider);
    final favoritesAsync = ref.watch(favoritesProvider);

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
          '我的收藏',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: Column(
        children: [
          _SegTabs(
            current: tab,
            onSelect: (next) => ref.read(favoriteTabProvider.notifier).select(next),
          ),
          Expanded(
            child: favoritesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => ListErrorView(
                error: asApiException(error),
                onRetry: () => ref.read(favoritesProvider.notifier).refresh(),
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
  /// 参数：[data] 收藏累积快照。
  /// 返回：Widget。
  Widget _buildList(FavoritesData data) {
    if (data.items.isEmpty) {
      return const _EmptyView();
    }
    return RefreshIndicator(
      onRefresh: () => ref.read(favoritesProvider.notifier).refresh(),
      child: ListView.separated(
        controller: _controller,
        padding: const EdgeInsets.all(AppSpacing.lg),
        itemCount: data.items.length + 1,
        separatorBuilder: (context, index) => const SizedBox(height: AppSpacing.md),
        itemBuilder: (context, index) {
          if (index == data.items.length) {
            return const ListEndRow();
          }
          final item = data.items[index];
          return _FavoriteCard(item: item, onRemove: () => _remove(item));
        },
      ),
    );
  }
}

/// 三格分段 Tab（资源/需求/全部）。
class _SegTabs extends StatelessWidget {
  /// 构造分段 Tab。
  ///
  /// 参数：[current] 当前页签；[onSelect] 选择回调。
  const _SegTabs({required this.current, required this.onSelect});

  /// 当前页签。
  final FavoriteTab current;

  /// 选择回调。
  final ValueChanged<FavoriteTab> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        border: Border(bottom: BorderSide(color: Color(AppColors.border))),
      ),
      child: Row(
        children: [
          for (final tab in FavoriteTab.values)
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

/// 收藏卡片（他人视角精简版：标题 + 类目路径 · 价格 + 星标取消）。
class _FavoriteCard extends StatelessWidget {
  /// 构造收藏卡片。
  ///
  /// 参数：[item] 收藏项；[onRemove] 取消收藏回调。
  const _FavoriteCard({required this.item, required this.onRemove});

  /// 收藏项。
  final FavoriteItemDto item;

  /// 取消收藏回调。
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      // 带上入口来源与已加载的收藏态：41001 时详情页据此把星标渲染为
      // 「已收藏可取消」，而不是不可点的未知态（KTD4 / R5）。
      onTap: () => context.push(
        '/detail/${item.postId}',
        extra: const DetailScreenArgs(
          fromFavorites: true,
          initialFavorited: true,
        ),
      ),
      child: Container(
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A000000),
              offset: Offset(0, 2),
              blurRadius: 8,
            ),
          ],
        ),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.h3.size,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _subtitle(item),
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
            IconButton(
              onPressed: onRemove,
              tooltip: '取消收藏',
              icon: Icon(Icons.star, size: 20, color: Color(AppColors.primary)),
            ),
          ],
        ),
      ),
    );
  }

  /// 副标题 = 「类目路径」·「价格文案」，两段各自非空才拼（不补空串）。
  ///
  /// 参数：[item] 收藏项。
  /// 返回：String 副标题。
  static String _subtitle(FavoriteItemDto item) {
    final parts = <String>[];
    final path = item.categoryPath;
    if (path != null && path.isNotEmpty) parts.add(path.join(' › '));
    parts.add(_priceText(item));
    return parts.join(' · ');
  }

  /// 价格文案：有价 → `¥{price}{unit}`（整数不显小数）；无价 → `面议`。
  ///
  /// 参数：[item] 收藏项。
  /// 返回：String 价格文案。
  static String _priceText(FavoriteItemDto item) {
    final price = item.price;
    if (price == null) return '面议';
    final unit = item.priceUnit;
    final amount = price == price.roundToDouble()
        ? price.toStringAsFixed(0)
        : price.toString();
    return unit == null || unit.isEmpty ? '¥$amount' : '¥$amount/$unit';
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
          Icon(Icons.star_border, size: 40, color: Color(AppColors.textPlaceholder)),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '还没有收藏，去首页逛逛 →',
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
