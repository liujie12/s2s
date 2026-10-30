/// 叠点清单：点「叠点堆」后从底部弹出「这一处有 N 条」，挑一条回到地图选中态。
///
/// **为什么是清单而不是放大**：重叠的几个点放大后仍在原地（它们本来就几乎
/// 同一坐标），放大解决不了「选哪一条」；清单直接把条目摆出来，选完即回到地图
/// 选中态并弹信息卡 —— 与点单个 Pin 完全同一套收尾，不新增第二种跳转语义。
///
/// **为什么用 `showModalBottomSheet` 而不是自绘遮罩**：设计要求「点面板之外的
/// 地图即收起」，模态的 barrier 天然提供这一行为，且只需把 `barrierColor`
/// 置透明即可不压暗底图 —— 自绘一层 `Positioned.fill` 反而要自己处理
/// 「遮罩吃掉一次点击但不移动相机」这件容易出错的事。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../core/text/distance_label.dart';
import '../../design_tokens.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import '../../domain/listing_category_style.dart';
import '../../domain/listing_detail.dart';
import '../detail/post_detail_provider.dart';

/// 弹出叠点清单并等待用户选择。
///
/// 参数：
/// - [context] 当前上下文（地图页）；
/// - [listingIds] 组内信息 ID，**顺序即展示顺序**（调用方已按完整度排好，
///   首行与地图主层那条一致）；
/// - [centerLat]/[centerLng] 距离基准点（优先用户定位，未定位时退回视口中心）。
///
/// 返回：用户点中的信息 ID；点面板外的地图或关闭按钮时为 null。
Future<int?> showOverlapListSheet(
  BuildContext context, {
  required List<int> listingIds,
  required double centerLat,
  required double centerLng,
}) {
  return showModalBottomSheet<int>(
    context: context,
    // 不压暗底图：清单回答的是「这一处有什么」，底图仍要能看清是哪儿。
    barrierColor: Colors.transparent,
    backgroundColor: Colors.transparent,
    elevation: 0,
    isScrollControlled: true,
    builder: (sheetContext) => _OverlapListSheet(
      listingIds: listingIds,
      centerLat: centerLat,
      centerLng: centerLng,
    ),
  );
}

/// 清单面板本体。
class _OverlapListSheet extends StatelessWidget {
  const _OverlapListSheet({
    required this.listingIds,
    required this.centerLat,
    required this.centerLng,
  });

  final List<int> listingIds;
  final double centerLat;
  final double centerLng;

  @override
  Widget build(BuildContext context) {
    // 高度上限与筛选面板同一约束（屏高 72%）：两处弹层长得一样高，
    // 用户在两个入口之间切换时不会觉得「换了一套东西」。
    final double maxHeight = MediaQuery.sizeOf(context).height * 0.72;

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(AppRadius.xl),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          0,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHandle(),
            _buildHeader(context),
            // shrinkWrap + Flexible：条数少时面板贴合内容，条数多时封顶并内部滚动。
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: listingIds.length,
                separatorBuilder: (context, index) => Divider(
                  height: 1,
                  thickness: 1,
                  color: Color(AppColors.border).withValues(alpha: 0.6),
                ),
                itemBuilder: (context, index) => _OverlapRow(
                  listingId: listingIds[index],
                  centerLat: centerLat,
                  centerLng: centerLng,
                ),
              ),
            ),
            SizedBox(height: MediaQuery.paddingOf(context).bottom),
          ],
        ),
      ),
    );
  }

  /// 顶部拖拽条（纯视觉：面板高度由内容决定，不做拖拽手势）。
  Widget _buildHandle() {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(
          top: AppSpacing.sm,
          bottom: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: Color(AppColors.border),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  /// 标题行：「这一处有 N 条」+ 排序说明 + 关闭。
  ///
  /// 不放「放大地图」：清单本身就是空间聚集的结果，再放大是第二套语义。
  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Text(
                      '这一处有 ',
                      style: TextStyle(
                        fontSize: AppTypeScale.h3.size,
                        fontWeight: FontWeight.w600,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                    Text(
                      '${listingIds.length}',
                      style: TextStyle(
                        fontSize: AppTypeScale.h3.size,
                        fontWeight: FontWeight.w700,
                        color: Color(AppColors.primary),
                      ),
                    ),
                    Text(
                      ' 条',
                      style: TextStyle(
                        fontSize: AppTypeScale.h3.size,
                        fontWeight: FontWeight.w600,
                        color: Color(AppColors.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '同一位置 · 按完整度排序',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    color: Color(AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close, size: 18),
            // 视觉 18px，命中区仍按 44 下限（与信息卡的关闭同一口径）。
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            color: Color(AppColors.textSecondary),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }
}

/// 清单里的一行：分类图标 + 标题 + 「供需 · 类目 · 距离 · 价格」+ 完整度角标。
///
/// 标题与价格来自详情接口（`/map/pins` 是紧凑格式，只有 id/坐标/类目/供需/
/// 完整度），故本行自己 watch 一次详情 —— 与地图信息卡同源，
/// 不往紧凑格式里加字段（那会破坏它压体积的前提）。
class _OverlapRow extends ConsumerWidget {
  const _OverlapRow({
    required this.listingId,
    required this.centerLat,
    required this.centerLng,
  });

  final int listingId;
  final double centerLat;
  final double centerLng;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<ListingDetail> detailAsync = ref.watch(
      postDetailProvider(listingId),
    );
    final _RowContent content = _RowContent.of(
      detailAsync,
      centerLat,
      centerLng,
    );

    return InkWell(
      // 未就绪/已下架不可点：点进去只会在详情页看到同一个失败态，白跑一趟。
      onTap: content.canOpen
          ? () => Navigator.of(context).pop(listingId)
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _buildCategoryIcon(content),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    content.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    content.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: Color(AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (content.completeness != null)
              _CompletenessTag(level: content.completeness!),
            const SizedBox(width: AppSpacing.xs),
            Icon(
              Icons.chevron_right,
              size: 18,
              color: content.canOpen
                  ? Color(AppColors.textPlaceholder)
                  : Color(AppColors.border),
            ),
          ],
        ),
      ),
    );
  }

  /// 分类圆标：资源＝分类色实心 + 白图标；需求＝白底 + 分类色描边（与 Pin 同规则）。
  ///
  /// 需求态在叠点堆上不再画 ? 角标（位置让给数量），故这里用空心本体 + 副行
  /// 「需求」字样把供需补回来。
  Widget _buildCategoryIcon(_RowContent content) {
    final Color color = content.pinColor ?? Color(AppColors.border);
    final bool hollow = content.supplyDemand == SupplyDemand.demand;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: hollow ? Color(AppColors.surface) : color,
        shape: BoxShape.circle,
        border: hollow ? Border.all(color: color, width: 2) : null,
      ),
      child: Icon(
        content.icon,
        size: 19,
        color: hollow ? color : Color(AppColors.surface),
      ),
    );
  }
}

/// 一行所需的展示数据（由详情三态归并，避免在 build 里散落 when 分支）。
class _RowContent {
  const _RowContent({
    required this.title,
    required this.subtitle,
    required this.canOpen,
    this.icon = Icons.place,
    this.pinColor,
    this.supplyDemand,
    this.completeness,
  });

  /// 由详情异步态归并出展示数据。
  ///
  /// 参数：
  /// - [async] 详情三态；
  /// - [centerLat]/[centerLng] 距离基准点。
  /// 返回：[_RowContent]；加载中与失败态 [canOpen] 为 false。
  factory _RowContent.of(
    AsyncValue<ListingDetail> async,
    double centerLat,
    double centerLng,
  ) {
    return async.when(
      loading: () => const _RowContent(
        title: '加载中…',
        subtitle: '',
        canOpen: false,
      ),
      error: (error, _) {
        // 41001 = 已下架/不存在，是用户的预期结果而非故障（文案与详情页同口径）。
        if (asApiException(error).code == ApiErrorCode.postGone) {
          return const _RowContent(
            title: '该信息已下架或不存在',
            subtitle: '看看同一处的其它信息',
            canOpen: false,
          );
        }
        return const _RowContent(
          title: '信息加载失败',
          subtitle: '稍后再试',
          canOpen: false,
        );
      },
      data: (detail) {
        final Listing listing = detail.listing;
        final double meters = distanceInMeters(
          centerLat,
          centerLng,
          listing.latitude,
          listing.longitude,
        );
        final List<String> parts = [
          listing.supplyDemand.label,
          listing.category.label,
          distanceLabel(meters),
          if (listing.priceLabel != null) listing.priceLabel!,
        ];
        return _RowContent(
          title: detail.displayTitle,
          subtitle: parts.join(' · '),
          // 圆标图标与 Pin 圆心同源：二级 → 一级 → 通用图钉。
          icon:
              l2CategoryIcon(detail.leafCategoryId) ??
              listing.category.icon,
          pinColor: listing.category.color,
          supplyDemand: listing.supplyDemand,
          completeness: detail.completeness,
          canOpen: true,
        );
      },
    );
  }

  final String title;
  final String subtitle;

  /// 是否可点（加载中 / 失败 / 已下架都为 false）。
  final bool canOpen;

  final IconData icon;

  /// 分类色（Pin 与圆标共用）；加载态为 null。
  final Color? pinColor;

  final SupplyDemand? supplyDemand;
  final CompletenessLevel? completeness;
}

/// 完整度角标（🟢 完整 / 🟡 半完整 / 🔴 待补）。
///
/// 底色用语义色 12% 透明度、文字用 `*-text` 深色变体 —— 与详情页
/// `_CompletenessLine` 同一套配色口径（原色白字不达 4.5:1）。
class _CompletenessTag extends StatelessWidget {
  const _CompletenessTag({required this.level});

  final CompletenessLevel level;

  @override
  Widget build(BuildContext context) {
    final (int fill, int text) = switch (level) {
      CompletenessLevel.green => (AppColors.success, AppColors.successText),
      CompletenessLevel.yellow => (AppColors.warning, AppColors.warningText),
      CompletenessLevel.red => (AppColors.error, AppColors.errorText),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Color(fill).withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: Color(fill),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            level.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Color(text),
            ),
          ),
        ],
      ),
    );
  }
}
