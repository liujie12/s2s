/// 列表页（PRD §6.4.3 / §10.1）。
///
/// **与地图页共享筛选态**：两页读同一个 `discoveryFilterProvider`，在列表页改了
/// 范围或分类，切回地图立刻生效。PRD §10.1 明确要求，否则会出现「地图 3 个 Pin、
/// 列表 12 条」这种用户一眼看得见的不一致。
///
/// **筛选面板在本页不做收起**（PRD §6.4.1 末条）：地图页收起是为了不遮挡底图，
/// 列表页没有底图可遮，收起只会多一次点击。
///
/// **本期不做的四项**（说明文档 M4-3 已记录范围与原因）：收藏星标（依赖账号）、
/// 实名/资质小标（依赖 §6.9 信任体系）、「联系 TA」按钮（联系中转页尚未实现，
/// 放了会跳占位屏）、位置文案（需逆地理编码，依赖高德 Key）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import '../../router/app_router.dart';
import 'discovery_filter.dart';
import 'filter_panel.dart';
import 'listing_repository.dart';
import 'listing_sort.dart';

class ListScreen extends ConsumerWidget {
  const ListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listings = ref.watch(sortedListingsProvider);

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: _buildAppBar(context),
      body: Column(
        children: [
          // 面板与排序条固定在顶部，不随列表滚动：它们是当前结果集的控制器，
          // 滚到第 50 条时想换个排序还得先滚回顶部，是很常见的体验缺陷。
          const FilterPanel(elevated: false),
          const _SortBar(),
          const Divider(height: 1),
          Expanded(
            child: listings.isEmpty
                ? const _EmptyState()
                : _ListingList(listings: listings),
          ),
        ],
      ),
    );
  }

  /// 顶部栏（PRD §6.4.3：返回 + 标题 + 地图视图跳转）。
  ///
  /// 搜索图标未放：搜索框已在地图页顶部常驻，且关键词属共享筛选态 ——
  /// 本页再放一个入口，两处输入框要同步光标与内容，收益不抵复杂度。
  /// 当前关键词由摘要行回显（见 [_SortBar] 上方的结果计数行）。
  PreferredSizeWidget _buildAppBar(BuildContext context) {
    return AppBar(
      toolbarHeight: 48,
      backgroundColor: Color(AppColors.surface),
      elevation: 0,
      title: Text(
        '附近信息',
        style: TextStyle(
          fontSize: AppTypeScale.h3.size,
          fontWeight: FontWeight.w600,
          color: Color(AppColors.textPrimary),
        ),
      ),
      actions: [
        TextButton.icon(
          // go 而非 push：地图与列表是同一层级的两个视图，push 会让返回栈
          // 累积成「地图→列表→地图→列表」，用户连按返回要按很多次才退出。
          onPressed: () => context.go(AppRoutes.home),
          icon: Icon(
            Icons.map_outlined,
            size: 18,
            color: Color(AppColors.primary),
          ),
          label: Text(
            '地图',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.primary),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
      ],
    );
  }
}

/// 排序条 + 结果计数（PRD §6.4.3 排序五档）。
class _SortBar extends ConsumerWidget {
  const _SortBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(listingSortProvider);
    final count = ref.watch(sortedListingsProvider).length;

    return Container(
      color: Color(AppColors.surface),
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            '$count 条',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              // 排序档位反向排列（末尾在右）时会与视觉顺序不符，故保持正序。
              child: Row(
                children: ListingSort.values.map((s) {
                  return Padding(
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: _SortChip(
                      sort: s,
                      selected: s == current,
                      onTap: () =>
                          ref.read(listingSortProvider.notifier).set(s),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SortChip extends StatelessWidget {
  const _SortChip({
    required this.sort,
    required this.selected,
    required this.onTap,
  });

  final ListingSort sort;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        // 视觉高 28，靠上下透明 padding 补到 44 命中区（iOS HIG 下限）。
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          sort.label,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            // 选中态同时改颜色与字重：只改颜色在色觉障碍下不可辨，
            // 只改字重则在小字号下差异过弱。
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? Color(AppColors.primary)
                : Color(AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

class _ListingList extends StatelessWidget {
  const _ListingList({required this.listings});

  final List<Listing> listings;

  @override
  Widget build(BuildContext context) {
    // ListView.builder 而非 ListView(children:)：压测档位下有 5 万条，
    // 后者会一次性构建全部卡片。
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: listings.length,
      itemBuilder: (context, i) => _ListingCard(listing: listings[i]),
    );
  }
}

/// 列表卡片（PRD §6.4.3）。
class _ListingCard extends StatelessWidget {
  const _ListingCard({required this.listing});

  final Listing listing;

  @override
  Widget build(BuildContext context) {
    final meters = distanceInMeters(
      kDefaultCenterLat,
      kDefaultCenterLng,
      listing.latitude,
      listing.longitude,
    );

    return GestureDetector(
      onTap: () => context.push('/detail/${listing.id}'),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _CategoryBadge(
              category: listing.category,
              supplyDemand: listing.supplyDemand,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listing.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.textPrimary),
                      height: 1.35,
                    ),
                  ),
                  if (listing.priceLabel != null) ...[
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      listing.priceLabel!,
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        fontWeight: FontWeight.w600,
                        // 价格用强调色而非分类色：分类色已由左侧色块承担，
                        // 两处同色会让价格看起来只是分类的附属信息。
                        color: Color(AppColors.accent),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${_formatDistance(meters)} · ${_formatAge(listing.createdAt)}',
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: Color(AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    // 面包屑本应两级（PRD §6.4.3），二级分类属 §7.4.1 模板字段，
                    // 尚未建模。先出一级，二级到位后在此处补 ' / 二级名'。
                    '${listing.category.label} · ${listing.supplyDemand.label}',
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: Color(AppColors.textPlaceholder),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 左侧分类色块（PRD §6.4.3：大类色方块 + 资源/需求态图标）。
///
/// 与地图 Marker 同一套配色规则（§6.4.2）：资源＝分类色实心配白图标，
/// 需求＝浅底配分类深色图标。两处若各自定义，用户在地图上认得的颜色
/// 到列表里对不上。
class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category, required this.supplyDemand});

  final ListingCategory category;
  final SupplyDemand supplyDemand;

  @override
  Widget build(BuildContext context) {
    final isSupply = supplyDemand == SupplyDemand.supply;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: isSupply ? category.color : Color(AppColors.background),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: isSupply ? null : Border.all(color: category.color, width: 1.5),
      ),
      child: Icon(
        category.icon,
        size: 22,
        // 需求态用 deepColor：分类原色在浅灰底上对比度不足
        // （design_tokens.dart:74）。
        color: isSupply ? Color(AppColors.surface) : category.deepColor,
      ),
    );
  }
}

/// 空态（PRD §6.4.4）。
///
/// 本期只做静态空态。§6.4.4 的 S2 动态蜂窝半径引擎与 30 秒分层兜底属
/// Batch2，此处不实现 —— 做半套（比如只做自动扩圈不做兜底文案）会让用户
/// 看到范围莫名其妙变了却没有任何解释。
class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(discoveryFilterProvider);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: 48,
              color: Color(AppColors.textPlaceholder),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '这个范围内暂时没有信息',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              // 回显当前条件：空结果最常见的原因是筛窄了，而用户往往
              // 不记得自己选了什么。只说「没有信息」会让人以为平台没内容。
              '当前筛选：${filter.summaryLabel}',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: Color(AppColors.textPlaceholder),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            if (filter.radius != SearchRadius.city)
              TextButton(
                onPressed: () => ref
                    .read(discoveryFilterProvider.notifier)
                    .setRadius(SearchRadius.city),
                child: const Text('扩大到全城看看'),
              ),
          ],
        ),
      ),
    );
  }
}

/// 距离文案。
///
/// 1km 以内用米（取整到 10m）：「368m」比「0.37km」更符合步行距离的直觉。
/// 超过则用公里保留一位小数。
String _formatDistance(double meters) {
  if (meters < 1000) return '${(meters / 10).round() * 10}m';
  return '${(meters / 1000).toStringAsFixed(1)}km';
}

/// 发布时间的相对文案。
///
/// 用相对时间而非绝对时间戳：列表页要回答的是「这条还新不新」，
/// 「2 小时前」直接给出答案，「08-28 10:15」还要用户自己算。
/// 超过 7 天回落到日期 —— 「23 天前」这种表述反而不如日期直观。
String _formatAge(DateTime createdAt) {
  final d = DateTime.now().difference(createdAt);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays <= 7) return '${d.inDays} 天前';
  return '${createdAt.month}-${createdAt.day.toString().padLeft(2, '0')}';
}
