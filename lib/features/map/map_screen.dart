/// 鸭圈首页 · 地图页（PRD §6.4.1 / §6.4.2）。
///
/// **地图渲染的两条分支**：
/// - `AMapInitGuard.canRenderMap()` 为 true → 走高德 `AMapWidget`（待 Key 到位后接入）；
/// - 否则 → 走 [FallbackMapCanvas] 降级底图（PRD:1207）。
///
/// 当前恒走降级分支，因为高德 Key 尚未申请（说明文档 M4-0 未闭环）。
/// 这不是「先凑合」——降级底图本身是 PRD 要求的正式兜底路径，Key 到位后
/// 两条分支并存，不会有任何一条被删掉。
///
/// **布局遵循 §6.4.1 收起口径**：默认只有右上角三点入口 + 左上角摘要胶囊
/// （约 44px 竖向占用），筛选面板由它们唤起，选完即收。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
// 色与图标已迁至 style 扩展（详细设计 §10.4.1）。
import '../../domain/listing_category_style.dart';
import '../../nfr_constants.dart';
import '../../router/app_router.dart';
import '../discovery/discovery_filter.dart';
import '../discovery/filter_panel.dart';
import '../discovery/listing_repository.dart';
import '../perf/perf_panel.dart';
import '../privacy/privacy_consent.dart';
import 'amap_init_guard.dart';
import 'clustering/grid_cluster.dart';
import 'clustering/marker_builder.dart';
import 'fallback_map_canvas.dart';
import 'map_projection.dart';
import 'marker_layer.dart';

/// 聚合网格边长（逻辑像素）。
///
/// 值转引 [NfrPerf.clusterGridSizePx]（`lib/nfr_constants.dart` 为 NFR 数字唯一真源）。
/// 该值原先只存在于本文件、PRD 无对应条目；2026-09-02 缺陷评审已补入 PRD §6.15，
/// 理由同下：60px 略大于单点 Marker 直径 40px —— 小于直径会让「聚不起来的两个点」
/// 在视觉上依然重叠，聚合等于没做；过大则相隔很远的点也被聚成一簇，
/// 用户点开发现它们分散在屏幕各处。
const double _kClusterGridSize = NfrPerf.clusterGridSizePx;

/// 初始缩放：一像素代表多少米。
///
/// 12 m/px 在 390 宽的屏上横向约覆盖 4.7km，与默认 5km 范围档基本吻合 ——
/// 默认视野与默认筛选范围对不上，用户会看到「明明筛了 5km 却只显示一小块」。
const double _kInitialMetersPerPixel = 12;

class MapScreen extends ConsumerStatefulWidget {
  const MapScreen({super.key});

  @override
  ConsumerState<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends ConsumerState<MapScreen> {
  /// 视口中心（GCJ-02）。拖动地图改的是它，不是 Marker 坐标。
  double _centerLat = kDefaultCenterLat;
  double _centerLng = kDefaultCenterLng;

  double _metersPerPixel = _kInitialMetersPerPixel;

  /// 缩放手势开始时的基准，用于把相对缩放比换算成绝对值。
  double _scaleStartMetersPerPixel = _kInitialMetersPerPixel;

  /// 当前选中的帖子**本地标识**（`String`，与 Marker 层同口径）。
  ///
  /// 类型刻意跟 [SinglePointMarker.listingId] 保持一致而不用 `int`：选中态是由
  /// 点击 Marker 产生的，而 Marker 的 id 来自 `ClusterPoint.id`（聚合层只用
  /// 基础类型，详细设计 §10.4.3）。若这里改 `int`，每次点击都要解析一次字符串，
  /// 且解析失败时没有合理的退路。跨到域模型时用 `Listing.id.toString()` 对齐。
  String? _selectedListingId;

  @override
  Widget build(BuildContext context) {
    final consent = ref.watch(privacyConsentProvider);
    final listings = ref.watch(filteredListingsProvider);

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: _buildAppBar(),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final projection = MapProjection(
            centerLat: _centerLat,
            centerLng: _centerLng,
            metersPerPixel: _metersPerPixel,
            viewportSize: (
              width: constraints.maxWidth,
              height: constraints.maxHeight,
            ),
          );
          final markers = _buildMarkersFor(listings, projection);
          // 供需查表在此建一次，而不是让 MarkerLayer 每画一个 Marker 就
          // firstWhere 一遍 —— 后者是 O(n²)，5 万点档位下会被真机测成
          // 「CustomPaint 画不动」，从而把优化引向完全错误的方向。
          // 键用 l.id.toString()：Marker 层的标识是 String（§10.4.3），
          // 而 Listing.id 是 int，键类型必须与查表方 marker.listingId 一致，
          // 否则 containsKey 永远为 false —— 而那是个 info 级提示，不报错。
          final supplyDemandById = {
            for (final l in listings) l.id.toString(): l.supplyDemand,
          };

          return Stack(
            children: [
              _buildMapBody(consent, projection, markers, supplyDemandById),
              const Positioned(
                left: AppSpacing.lg,
                top: AppSpacing.md,
                child: _FilterSummaryChip(),
              ),
              const Positioned(
                right: AppSpacing.lg,
                top: AppSpacing.md,
                child: _FilterEntryButton(),
              ),
              // 列表视图入口（PRD §10.1：地图与列表是同层级的两个视图）。
              // 放在筛选入口正下方而非底部中央：底部要留给筛选面板与信息卡，
              // 三者叠在一起会互相遮挡。
              const Positioned(
                right: AppSpacing.lg,
                top: AppSpacing.md + 44 + AppSpacing.sm,
                child: _ListViewEntryButton(),
              ),
              if (ref.watch(filterPanelExpandedProvider))
                const Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  child: FilterPanel(),
                ),
              if (_selectedListingId != null)
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  child: _ListingInfoCard(
                    listing: listings.firstWhere(
                      (l) => l.id.toString() == _selectedListingId,
                    ),
                    onClose: () => setState(() => _selectedListingId = null),
                  ),
                ),
              // POC-B 性能面板（PRD §6.10.1）。放右下而非顶部：顶部已被筛选
              // 入口占据，且压测时要频繁点它，靠近拇指自然位置。
              const Positioned(
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: PerfPanel(),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 导航栏（PRD §6.4.1：实体 48px，含搜索框与通知铃）。
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      toolbarHeight: 48,
      backgroundColor: Color(AppColors.surface),
      elevation: 0,
      titleSpacing: AppSpacing.md,
      title: SizedBox(
        height: 32,
        child: TextField(
          onChanged: (v) =>
              ref.read(discoveryFilterProvider.notifier).setKeyword(v),
          style: TextStyle(fontSize: AppTypeScale.body.size),
          decoration: InputDecoration(
            hintText: '搜索保洁/拼车/租房',
            hintStyle: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textPlaceholder),
            ),
            prefixIcon: Icon(
              Icons.search,
              size: 18,
              color: Color(AppColors.textPlaceholder),
            ),
            // 输入框内高仅 32px，默认的 prefixIcon 约束会把它撑高。
            prefixIconConstraints: const BoxConstraints(minWidth: 32),
            filled: true,
            fillColor: Color(AppColors.background),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.full),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  /// 地图主体：按合规守卫结果二选一。
  Widget _buildMapBody(
    PrivacyConsentStatus consent,
    MapProjection projection,
    List<MapMarker> markers,
    Map<String, SupplyDemand> supplyDemandById,
  ) {
    // 🔴 上架驳回点：构建 AMapWidget 即触发高德原生 SDK 初始化。
    // 未同意隐私协议时走到这一步就是违规，判据见 amap_init_guard.dart 文件头。
    final canRenderRealMap = AMapInitGuard.canRenderMap(consent);

    return GestureDetector(
      onScaleStart: (_) => _scaleStartMetersPerPixel = _metersPerPixel,
      onScaleUpdate: (details) => _onScaleUpdate(details, projection),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (canRenderRealMap)
            // Key 到位后在此接入 AMapWidget。占位为降级底图而非空白，
            // 是为了让这条分支在 Key 缺失时也有确定的视觉，不会白屏。
            FallbackMapCanvas(
              projection: projection,
              notice: '高德地图 Key 未配置，当前为示意底图',
            )
          else
            FallbackMapCanvas(
              projection: projection,
              notice: '示意底图 · 位置为相对分布，不代表真实地理位置',
            ),
          MarkerLayer(
            markers: markers,
            supplyDemandById: supplyDemandById,
            selectedListingId: _selectedListingId,
            onTapMarker: _onTapMarker,
          ),
        ],
      ),
    );
  }

  /// 经纬度 → 像素 → 网格聚合 → 阈值判定 → Marker。
  ///
  /// 每帧重算而不做缓存：投影一变（拖动/缩放）像素坐标全变，缓存命中率接近零，
  /// 而缓存本身要维护失效逻辑。POC-A 实测 5 万点聚合 4.7ms，占 300ms 预算 1.6%，
  /// 当前百来条的量级更无优化必要。
  List<MapMarker> _buildMarkersFor(
    List<Listing> listings,
    MapProjection projection,
  ) {
    final points = listings
        .map((l) {
          final p = projection.toPixel(l.latitude, l.longitude);
          return ClusterPoint(
            // ClusterPoint.id 是本地分桶标识（String），Listing.id 为服务端 int64，
            // 故此处显式转字符串；反向回传时须转回 int（详细设计 §10.4.3）。
            id: l.id.toString(),
            x: p.x,
            y: p.y,
            // 样例数据只有大类没有叶子类目，故叶子 ID 记 0 表示「本地样例、无叶子」。
            // 接入 /map/pins 后此处改为服务端下发的 category_id，
            // topCategory 则改为 topCategoryOf(category_id)。
            leafCategoryId: 0,
            topCategory: l.category,
          );
        })
        .toList(growable: false);

    final clusters = clusterByGrid(points, gridSize: _kClusterGridSize);
    return buildMarkers(
      points,
      clusters,
      // 大类为 null（分类树查不到）时取最保守的阈值 3：宁可多聚也不要在
      // 密集区散成一片点。阈值该取几由产品决定，故留在调用方而非算法层。
      thresholdOf: (topCategory) =>
          topCategory?.clusterThreshold ?? ListingCategory.work.clusterThreshold,
    );
  }

  void _onScaleUpdate(ScaleUpdateDetails details, MapProjection projection) {
    setState(() {
      if (details.scale != 1.0) {
        // 手势放大 → 看得更近 → 每像素代表的米数变小，故用除法。
        // 上下限防止缩到路网糊成一片或放大到浮点精度失效。
        _metersPerPixel = (_scaleStartMetersPerPixel / details.scale).clamp(
          1.0,
          200.0,
        );
      }
      // 拖动：把像素位移换回经纬度增量。手指右移 → 视口中心左移，故取负。
      final double metersPerDegLat = 111320;
      _centerLat +=
          details.focalPointDelta.dy * _metersPerPixel / metersPerDegLat;
      _centerLng -=
          details.focalPointDelta.dx * _metersPerPixel / metersPerDegLat;
    });
  }

  void _onTapMarker(MapMarker marker) {
    setState(() {
      switch (marker) {
        case SinglePointMarker():
          _selectedListingId = marker.listingId;
        case ClusterMarker():
          // 点聚合圈放大地图（PRD §6.4.2）。放大 2 倍而非直接展开列表 ——
          // 展开列表会让用户失去空间上下文，而聚合的意义正是空间聚集。
          _selectedListingId = null;
          _metersPerPixel = (_metersPerPixel / 2).clamp(1.0, 200.0);
      }
    });
  }
}

/// 收起态摘要胶囊（PRD §6.4.1：收起 ≠ 隐藏）。
class _FilterSummaryChip extends ConsumerWidget {
  const _FilterSummaryChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(discoveryFilterProvider);
    return GestureDetector(
      onTap: () => ref.read(filterPanelExpandedProvider.notifier).open(),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.full),
          // 阴影是必需项：浅色底图上无阴影则卡片边界不可辨（PRD §6.4.1）。
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          filter.summaryLabel,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// 右上角三竖点入口（PRD §6.4.1：44×44，遮挡最小的载体）。
class _FilterEntryButton extends ConsumerWidget {
  const _FilterEntryButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expanded = ref.watch(filterPanelExpandedProvider);
    return GestureDetector(
      onTap: () => ref.read(filterPanelExpandedProvider.notifier).toggle(),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(
          expanded ? Icons.close : Icons.more_vert,
          color: Color(AppColors.textPrimary),
        ),
      ),
    );
  }
}

/// 列表视图入口。
///
/// 用 `go` 而非 `push`：两个视图同层级，push 会让返回栈累积成
/// 「地图→列表→地图→列表」，用户连按返回要按很多次才退出。
class _ListViewEntryButton extends StatelessWidget {
  const _ListViewEntryButton();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go(AppRoutes.list),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          shape: BoxShape.circle,
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.list, color: Color(AppColors.textPrimary)),
      ),
    );
  }
}

/// 点击单点 Marker 后的信息卡（PRD §6.4.2）。
class _ListingInfoCard extends StatelessWidget {
  const _ListingInfoCard({required this.listing, required this.onClose});

  final Listing listing;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // 整卡可点进详情（PRD §7.5 旅程第 1 步）。整卡而非只给一个小按钮：
      // 卡片本身就是「这条信息」的代表，用户的直觉是点它。
      onTap: () => context.push('/detail/${listing.id}'),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 12,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: listing.category.color,
                shape: BoxShape.circle,
              ),
              child: Icon(
                listing.category.icon,
                size: 20,
                color: Color(AppColors.surface),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    listing.title,
                    style: TextStyle(
                      fontSize: AppTypeScale.h3.size,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '${listing.supplyDemand.label} · ${listing.category.label}'
                    '${listing.priceLabel == null ? '' : ' · ${listing.priceLabel}'}',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: Color(AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      Text(
                        '查看详情',
                        style: TextStyle(
                          fontSize: AppTypeScale.small.size,
                          fontWeight: FontWeight.w600,
                          color: Color(AppColors.primary),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right,
                        size: 16,
                        color: Color(AppColors.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: onClose,
              icon: const Icon(Icons.close, size: 18),
              // 视觉 18px，但命中区仍按 44 下限。
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              color: Color(AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
