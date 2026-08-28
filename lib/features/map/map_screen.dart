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

import '../../design_tokens.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import '../discovery/discovery_filter.dart';
import '../discovery/listing_repository.dart';
import '../privacy/privacy_consent.dart';
import 'amap_init_guard.dart';
import 'clustering/grid_cluster.dart';
import 'clustering/marker_builder.dart';
import 'fallback_map_canvas.dart';
import 'filter_panel.dart';
import 'map_projection.dart';
import 'marker_layer.dart';

/// 聚合网格边长（逻辑像素）。
///
/// 60px 略大于单点 Marker 直径 40px：小于直径会让「聚不起来的两个点」在视觉上
/// 依然重叠，聚合等于没做；过大则相隔很远的点也被聚成一簇，用户点开发现它们
/// 分散在屏幕各处。
const double _kClusterGridSize = 60;

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

          return Stack(
            children: [
              _buildMapBody(consent, projection, markers, listings),
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
                      (l) => l.id == _selectedListingId,
                    ),
                    onClose: () => setState(() => _selectedListingId = null),
                  ),
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
    List<Listing> listings,
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
            supplyDemandOf: (id) =>
                listings.firstWhere((l) => l.id == id).supplyDemand,
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
            id: l.id,
            x: p.x,
            y: p.y,
            categoryId: l.category.id,
          );
        })
        .toList(growable: false);

    final clusters = clusterByGrid(points, gridSize: _kClusterGridSize);
    return buildMarkers(
      points,
      clusters,
      thresholdOf: (id) => listingCategoryFromId(id).clusterThreshold,
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

/// 点击单点 Marker 后的信息卡（PRD §6.4.2）。
class _ListingInfoCard extends StatelessWidget {
  const _ListingInfoCard({required this.listing, required this.onClose});

  final Listing listing;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
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
    );
  }
}
