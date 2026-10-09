/// 鸭圈首页 · 地图页（PRD §6.4.1 / §6.4.2）。
///
/// **地图渲染的两条分支**：
/// - 已同意隐私协议**且**构建期注入了高德 Key → 走高德 `AMapWidget`；
/// - 否则 → 走 [FallbackMapCanvas] 降级底图（PRD:1207）。
///
/// 降级不是「先凑合」—— 它是 PRD 要求的正式兜底路径，三种情况都会走到：
/// 未同意协议、未注入 Key、以及将来地图加载失败。真地图接入后两条分支并存，
/// 不会有任何一条被删掉。
///
/// **Pin 的归属**：两条分支都由 [MarkerLayer] 在 Dart 侧叠加绘制，不用高德的
/// Marker —— 理由见 `_buildAmap` 的注释（投影自持，说明文档 §2119）。
///
/// **布局遵循 §6.4.1 收起口径**：默认只有右上角三点入口 + 左上角摘要胶囊
/// （约 44px 竖向占用），筛选面板由它们唤起，选完即收。
library;

import 'dart:math' as math;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../../core/cache/grid_id.dart';
import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
// 色与图标已迁至 style 扩展（详细设计 §10.4.1）。
import '../../domain/listing_category_style.dart';
import '../../domain/listing_detail.dart';
import '../../nfr_constants.dart';
import '../../router/app_router.dart';
import '../city/city_selector_sheet.dart';
import '../detail/post_detail_provider.dart';
import '../discovery/discovery_filter.dart';
import '../discovery/discovery_providers.dart';
import '../discovery/discovery_query.dart';
import '../discovery/filter_panel.dart';
import '../discovery/map_dto.dart';
import '../location/location_center.dart';
import '../location/location_guide.dart';
import '../location/location_permission.dart';
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

/// 缩放下限：一像素代表多少米（放到最近）。
///
/// 与 [`_kMaxMetersPerPixel`] 成对使用，且**两条分支必须用同一对值**：
/// 降级底图靠 Dart 自己 clamp，真地图靠 `MinMaxZoomPreference` 换算成 zoom 交给
/// 原生相机。只夹一边会让 Pin 与底图在边界处错位（状态说 1 m/px、底图却更近）。
const double _kMinMetersPerPixel = 1;

/// 缩放上限：一像素代表多少米（放到最远）。理由同上。
const double _kMaxMetersPerPixel = 200;

/// 赤道处每度纬度对应的米数（全城档「缩小视野」把 pin 外接框换算成米制尺寸用）。
///
/// 与 `map_projection.dart` 内部同值，此处为独立常量：投影层把它当实现细节私有，
/// 地图页不 import 其私有符号，故各自声明（地理常数，非阈值/TTL 类红线口径）。
const double _kMetersPerDegreeLat = 111320;

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

  /// 请求视口 —— 与上面三个**渲染视口**字段刻意分开。
  ///
  /// `PinsQuery` 的 family 键含 `lng/lat/zoom`，而渲染视口在拖动中**每帧**都变。
  /// 若请求直接读渲染视口，一次拖动会发出上百个请求（每个都带 3s 读超时）：
  /// Marker 永远停在「正在加载」，且请求洪水会触发服务端限流 → 表现为「加载
  /// 很慢」并最终「加载失败」。
  ///
  /// 渲染视口**不能**改成只更新一次：Pin 是 Flutter 覆盖层、投影自持
  /// （见 [_buildAmap] 注释），不逐帧重投影拖动时会明显拖影。
  /// 故两个诉求各留一条路：渲染每帧更新，请求只在手势结束那一刻同步。
  double _fetchLat = kDefaultCenterLat;
  double _fetchLng = kDefaultCenterLng;
  double _fetchMetersPerPixel = _kInitialMetersPerPixel;

  /// 缩放手势开始时的基准，用于把相对缩放比换算成绝对值。
  double _scaleStartMetersPerPixel = _kInitialMetersPerPixel;

  /// 当前选中的帖子**本地标识**（`String`，与 Marker 层同口径）。
  ///
  /// 类型刻意跟 [SinglePointMarker.listingId] 保持一致而不用 `int`：选中态是由
  /// 点击 Marker 产生的，而 Marker 的 id 来自 `ClusterPoint.id`（聚合层只用
  /// 基础类型，详细设计 §10.4.3）。若这里改 `int`，每次点击都要解析一次字符串，
  /// 且解析失败时没有合理的退路。跨到域模型时用 `Listing.id.toString()` 对齐。
  String? _selectedListingId;

  /// 高德地图控制器。仅真地图分支有值（`onMapCreated` 回调里赋值），
  /// 用于程序化改视角（当前唯一场景：点聚合圈放大）。
  AMapController? _amapController;

  /// 是否已取得过有效定位（首屏骨架屏判定）。
  bool _located = false;

  /// 连续取点失败次数（§6.8「≥ [NfrLocation.locateFailThreshold] 次 → C 态降级」）。
  int _locateFailCount = 0;

  @override
  void initState() {
    super.initState();
    // 视口中心从共享参考中心初始化（默认杭州；定位成功/手动选城市会改写）。
    final center = ref.read(locationCenterProvider);
    _centerLat = center.lat;
    _centerLng = center.lng;
    // 请求视口同源初始化：若只同步渲染视口，首帧会按「字段默认值（杭州）」发一次
    // 请求，而参考中心若已被手动选城市改过，这次请求就是白发的。
    _fetchLat = center.lat;
    _fetchLng = center.lng;
    // ⚠ 参考中心的监听【不能】注册在这里：Riverpod 的 ref.listen 在 initState 中
    // 不生效（debug 下断言报错，release 下断言被剥离 → 静默失效）。注册点见 build()。
    // 2026-10-08 实测教训：[132] 首版写在此处，表现为「取点成功（171 个定位点）但
    // 相机永不移动、蓝点落在视口外」。
  }

  @override
  Widget build(BuildContext context) {
    // 参考中心变化（定位成功取点 / 手动选城市）→ 同步视口 + 推给原生相机。
    // 必须注册在 build（initState 中 ref.listen 无效，见 initState 处注释）。
    // 用户拖动只改本地 _centerLat/_centerLng、不改 Provider，故不构成回环。
    ref.listen(locationCenterProvider, (previous, next) {
      if (next.lat == _centerLat && next.lng == _centerLng) return;
      setState(() {
        _centerLat = next.lat;
        _centerLng = next.lng;
      });
      _pushCameraToAmap();
      // 同时同步请求视口：不能只依赖 onCameraMoveEnd —— 定位居中是最核心的
      // 路径，若插件在该次程序化移动后不回调，请求会停在默认中心。
      // 与后续 onCameraMoveEnd 重复同步无副作用：`PinsQuery` 值相等 → 同键 → 不发请求。
      _syncFetchViewport();
    });
    final consent = ref.watch(privacyConsentProvider);
    // 探索数据源：真后端 `/map/pins`（[126] 前端段切入；此前读的是本地 mock 样例，
    // 而详情页读真后端 —— 两者 ID 空间不通，正是「详情看不了」的根因）。
    // 五要素随筛选态与视口变化；`PinsQuery` 实现值相等，故同一组合只发一次。
    final filter = ref.watch(discoveryFilterProvider);
    final pinsQuery = PinsQuery(
      leafCategoryIds: leafCategoryIdsFor(filter.categories),
      postTypes: postTypesFor(filter.supplyDemand),
      radius: toApiRadius(filter.radius),
      gridId: gridIdOf(_fetchLng, _fetchLat),
      // 分类树版本号取本地常量真源（随包发布，与服务端不一致时契约只回 stale 标记、
      // 不报错，故落后是降级而非故障）。
      categoryVersion: categoryTreeVersion,
      // lng/lat/zoom 取**请求视口**而非渲染视口，见 `_fetchLat` 的注释。
      lng: _fetchLng,
      lat: _fetchLat,
      zoom: MapProjection.zoomForMetersPerPixel(_fetchLat, _fetchMetersPerPixel),
    );
    final pinsAsync = ref.watch(pinsProvider(pinsQuery));

    // 定位引导页（PRD §6.4.4 A/B 态）：隐私已同意、未跳过、且权限为 A/B 时，
    // 全屏引导页取代地图。C 态（已授权但取点失败）不出引导页，走 §6.8 兜底。
    final phase = ref.watch(locationPermissionProvider);
    final guideDismissed = ref.watch(locationGuideDismissedProvider);
    if (consent == PrivacyConsentStatus.agreed &&
        !guideDismissed &&
        (phase == LocationPermissionPhase.neverGranted ||
            phase == LocationPermissionPhase.revoked)) {
      return const LocationGuide();
    }

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
          // 数据态：加载中/失败时 pinList 为空，底图照常渲染（不阻塞），
          // 状态另行以角标提示（见下方 _PinsStatusChip）。
          final pinList = pinsAsync.asData?.value.pins ?? const <MapPinDto>[];
          // pins 派生量按**引用**记忆化，避免随每一帧重算（见 [_PinsDerived]）。
          final derived = _derivedFor(pinList);
          // Marker 走「拖动中降级渲染」：能复用就只平移，超出余量才精算。
          final frame = _markerLayerFrame(pinList, projection, derived);
          final markers = frame.markers;
          final supplyDemandById = derived.supplyDemandById;
          // G-138-1：有 pin 却全部投影在视口外 → 提示「视野外还有 N 条」。
          // 用「pinList 非空 + 无可见 marker」而非「total > 0」：mode=cluster 时
          // 服务端回 clusters[]、pinList 为空，此时不是「屏外有点」而是「还没接
          // cluster 渲染」（[126] 遗留），不该弹这条提示。
          final int pinsTotal = pinsAsync.asData?.value.total ?? 0;
          // 判据须带上本帧平移量：Marker 坐标属于「精算视口」（比屏每边大一圈余量），
          // 不补平移会把余量里那些**屏外**的点误判成可见，使该出的角标不出。
          final bool hasVisibleMarker = markers.any(
            (m) =>
                m.x + frame.offset.dx >= 0 &&
                m.x + frame.offset.dx <= constraints.maxWidth &&
                m.y + frame.offset.dy >= 0 &&
                m.y + frame.offset.dy <= constraints.maxHeight,
          );
          final bool allOffScreen =
              pinsAsync.asData != null && pinList.isNotEmpty && !hasVisibleMarker;

          return Stack(
            children: [
              _buildMapBody(
                consent,
                projection,
                markers,
                supplyDemandById,
                frame.offset,
                frame.layerSize,
              ),
              // 定位前骨架屏（PRD §6.7 `:1305`）：已授权但尚未取到点 → 遮罩 + 提示。
              if (phase == LocationPermissionPhase.granted &&
                  !_located &&
                  _locateFailCount < NfrLocation.locateFailThreshold)
                const Positioned.fill(child: _LocatingSkeleton()),
              // C 态降级提示（PRD §6.8 / §6.4.4 C）：连续取点失败 ≥ 阈值 →
              // 保持默认中心 + 顶部提示 + 手动选城市（不出引导页）。
              if (_locateFailCount >= NfrLocation.locateFailThreshold)
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  child: _LocateFailedBanner(onManualCity: _showManualCity),
                ),
              const Positioned(
                left: AppSpacing.lg,
                top: AppSpacing.md,
                child: _FilterSummaryChip(),
              ),
              // 探索数据态（[126]）：加载中/失败必须可见 —— 否则「附近没有信息」
              // 与「数据没回来」在用户眼里完全同形，而两者的处置方式相反。
              if (pinsAsync.isLoading || pinsAsync.hasError)
                Positioned(
                  left: AppSpacing.lg,
                  top: AppSpacing.md + 40,
                  child: _PinsStatusChip(
                    text: pinsAsync.hasError ? '加载失败 · 点击重试' : '正在加载附近信息…',
                    onTap: pinsAsync.hasError
                        ? () => ref.invalidate(pinsProvider(pinsQuery))
                        : null,
                  ),
                )
              else if (allOffScreen)
                Positioned(
                  left: AppSpacing.lg,
                  top: AppSpacing.md + 40,
                  child: _PinsStatusChip(
                    text: '视野外还有 $pinsTotal 条，缩小地图查看',
                    onTap: () => _zoomOutToShowAll(
                      viewportWidth: constraints.maxWidth,
                      viewportHeight: constraints.maxHeight,
                      pins: pinList,
                    ),
                  ),
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
                    // 选中态存的是 Marker 层的 String 标识（§10.4.3），
                    // 拉详情要 int —— 解析收敛在此一处（与 detail 路由同一口径）。
                    listingId: int.tryParse(_selectedListingId!) ?? -1,
                    centerLat: _centerLat,
                    centerLng: _centerLng,
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
  ///
  /// 参数：
  /// - [consent]：隐私协议状态（决定能否初始化高德原生 SDK）；
  /// - [projection]：屏幕视口投影（底图用）；
  /// - [markers]：本帧要画的 Marker（坐标属于精算视口，见 [_markerLayerFrame]）；
  /// - [supplyDemandById]：Marker 供需查表；
  /// - [markerOffset]：Marker 坐标 → 屏幕坐标的平移量；
  /// - [markerLayerSize]：Marker 坐标系画布尺寸（= 精算视口尺寸）。
  Widget _buildMapBody(
    PrivacyConsentStatus consent,
    MapProjection projection,
    List<MapMarker> markers,
    Map<String, SupplyDemand> supplyDemandById,
    Offset markerOffset,
    Size markerLayerSize,
  ) {
    // 🔴 上架驳回点：构建 AMapWidget 即触发高德原生 SDK 初始化。
    // 未同意隐私协议时走到这一步就是违规，判据见 amap_init_guard.dart 文件头。
    //
    // 这里补写一次同意声明：守卫的 _consentApplied 是进程内静态量，冷启动归零，
    // 而 applyConsent 此前只在协议门点「同意」那一刻被调用 —— 结果「本次会话点过同意」
    // 能渲染真地图，「上次会话已同意、这次冷启动直接进首页」却永远拿不到真地图。
    // applyConsent 自身对非 agreed 直接返回且幂等（_consentApplied 短路），
    // 故在此重复调用无副作用，也不会让未同意的用户碰到 updatePrivacyAgree。
    AMapInitGuard.applyConsent(consent);

    // 真地图需要三件事同时成立：已同意 + 声明已写入 SDK + 构建期注入了 Key。
    // 缺 Key 时必须退回降级底图：没有 Key 时构建 `AMapWidget` 是**白屏**，而白屏与
    // 「声明没写」在真机上完全同形（见 amap_init_guard.dart 文件头），
    // 退回降级底图能让故障可读。
    final bool useRealMap =
        AMapInitGuard.canRenderMap(consent) &&
        AMapInitGuard.ensureSdkInitialized(context);

    return Stack(
      fit: StackFit.expand,
      children: [
        if (useRealMap)
          _buildAmap()
        else
          // 手动手势只挂在降级底图上：降级底图没有原生相机，拖动/缩放得由 Dart
          // 自己换算。真地图由高德原生接管手势，再套这层会让 Flutter 先截获手势，
          // 与原生相机互相打架（表现为拖动一顿一顿、缩放回弹）。
          GestureDetector(
            onScaleStart: (_) => _scaleStartMetersPerPixel = _metersPerPixel,
            onScaleUpdate: (details) => _onScaleUpdate(details, projection),
            // 降级底图没有原生相机，故没有 onCameraMoveEnd；若不同步，这条路
            // 仍会退化成「每帧一个请求」的老问题。
            onScaleEnd: (_) => _syncFetchViewport(),
            child: FallbackMapCanvas(
              projection: projection,
              // 两种降级原因的文案分开：已同意却只看到「示意底图」时，
              // 排查者会去怀疑隐私门，而真实原因是没注入 Key。
              notice: consent == PrivacyConsentStatus.agreed
                  ? '高德地图 Key 未配置，当前为示意底图'
                  : '示意底图 · 位置为相对分布，不代表真实地理位置',
            ),
          ),
        // 拖动中降级渲染（见 [_markerLayerFrame]）：
        // - 精算层坐标原点在「屏左上角 − margin」，故整体按 [markerOffset] 平移；
        // - 尺寸须用 [markerLayerSize]（比屏每边大一圈余量）。若留成 Stack 的紧约束，
        //   会被夹回屏大小，余量里的 Pin 直接被裁掉 —— 表现为拖动时屏边缺 Pin；
        // - 超出屏幕的部分由 Stack 默认的 `Clip.hardEdge` 裁掉，无需另加 ClipRect。
        //
        // `RepaintBoundary` **必须夹在 Transform 之内**：这样拖动中只有 Transform 变化时
        // 子树不重画（`tool/poc_b_transform_reuse_probe.dart` 实测 30 帧只画 1 次，
        // 每帧 6.76ms → 0.89ms）。挪到 Transform 之外，这层优化立刻失效。
        Positioned(
          left: 0,
          top: 0,
          width: markerLayerSize.width,
          height: markerLayerSize.height,
          child: Transform.translate(
            offset: markerOffset,
            child: RepaintBoundary(
              child: MarkerLayer(
                markers: markers,
                supplyDemandById: supplyDemandById,
                selectedListingId: _selectedListingId,
                onTapMarker: _onTapMarker,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 高德原生地图（Key 已注入且已同意时）。
  ///
  /// **Pin 不交给高德的 Marker**：说明文档 §2119 已定「投影自持、不等异步
  /// `toScreenLocation`」—— 聚合要在每帧布局时同步出坐标，而那个转换走
  /// platform channel，异步返回会让 Pin 晚一帧、拖动时明显拖影。故本方法只管两件事：
  /// ① 把 Dart 侧状态换算成初始相机；② 由 [_onCameraMove] 把相机变化同步回状态，
  /// 供 [MarkerLayer] 复用同一套投影。
  ///
  /// 返回：[Widget] 高德地图控件。
  Widget _buildAmap() {
    // 只有已授权才启用定位（蓝点 + 取点回调）。A/B 态被引导页取代、手动选城市
    // 跳过时权限仍非 granted，此时不启蓝点也不听取点回调，避免无权限时白等。
    final locationGranted =
        ref.watch(locationPermissionProvider) == LocationPermissionPhase.granted;

    return AMapWidget(
      // 只在创建平台视图时生效（插件的 `didUpdateWidget` 只更 options，不重设相机），
      // 故这里传当前状态不会与 onCameraMove 形成「回调 → 重建 → 再设相机」的回环。
      initialCameraPosition: CameraPosition(
        target: LatLng(_centerLat, _centerLng),
        zoom: MapProjection.zoomForMetersPerPixel(_centerLat, _metersPerPixel),
      ),
      // 与降级底图共用同一对缩放上下限，避免两条分支能到的范围不一致。
      minMaxZoomPreference: MinMaxZoomPreference(
        MapProjection.zoomForMetersPerPixel(_centerLat, _kMaxMetersPerPixel),
        MapProjection.zoomForMetersPerPixel(_centerLat, _kMinMetersPerPixel),
      ),
      // 位置蓝点（PRD §6.4.1「位置 Marker 🟢（自己）」）：交给高德原生绘制，
      // 不在 Dart 侧自绘 —— 自绘蓝点要跟相机每帧换算坐标，与 Marker 投影同一套
      // 异步 toScreenLocation 问题。
      myLocationStyleOptions: MyLocationStyleOptions(locationGranted),
      onLocationChanged: locationGranted ? _onLocationChanged : null,
      onMapCreated: (controller) => _amapController = controller,
      onCameraMove: _onCameraMove,
      // 手势结束才同步请求视口 → 一次拖动只发一次请求。
      // 用插件原生回调而非自写 debounce 计时器：不引入「多久算停」的魔法时长。
      onCameraMoveEnd: _onCameraMoveEnd,
      // 罗盘默认在左上角，会与筛选摘要胶囊叠在一起，故关掉。
      compassEnabled: false,
      // 比例尺交给高德自己画：降级底图那条自绘比例尺属 FallbackMapCanvas，
      // 这条分支不走那个控件，不显式开启就没有比例尺。
      scaleEnabled: true,
    );
  }

  /// 高德定位取点回调（`onLocationChanged`）。
  ///
  /// 三件事：
  /// 1. 无效定位 → 失败计数 +1，达到 [NfrLocation.locateFailThreshold] 进入 C 态
  ///    （§6.8：保持默认中心 + 顶部提示 + 手动选城市，不出引导页）；
  /// 2. 有效定位 → 写 `location_granted_once` 标记 + 移动共享参考中心
  ///    （经 [locationCenterProvider]，由 build() 中的 ref.listen 同步视口）；
  /// 3. 成功后清空失败计数。
  ///
  /// 有效性由 [isUsableLocationFix] 判定 —— **不用插件 `amap_map` 的
  /// `isLocationValid`**：后者只判「范围内 + accuracy ≥ 0」，会把定位不可用时回传的
  /// `(0, 0)` 当成有效定位（后果详见该函数注释）。
  ///
  /// 参数：
  /// - [location]：高德回传的定位信息。
  void _onLocationChanged(AMapLocation location) {
    if (!isUsableLocationFix(
      lat: location.latLng.latitude,
      lng: location.latLng.longitude,
      accuracy: location.accuracy,
    )) {
      _locateFailCount++;
      if (_locateFailCount >= NfrLocation.locateFailThreshold) {
        setState(() => _located = false);
      }
      return;
    }
    // 只有首个有效点写入参考中心（口径：2026-10-08 裁定「仅首点居中一次」）。
    // 若每个点都写，参考中心会以 5–8s 的节奏变化，经 build() 中的 ref.listen 把
    // 用户拖动后的视角反复拽回定位点。代价是数据层中心冻结在首点上 —— 可接受，
    // 因为首点已足以判定「用户所在城市/商圈」，后续精度提升对 5km 筛选无实质影响。
    final isFirstFix = !_located;
    setState(() {
      _locateFailCount = 0;
      _located = true;
    });
    ref.read(locationPermissionProvider.notifier).markGrantedOnce();
    if (isFirstFix) {
      ref.read(locationCenterProvider.notifier).moveTo(
            location.latLng.latitude,
            location.latLng.longitude,
          );
    }
  }

  /// C 态「手动选城市」出口：弹出城市选择，选中后移动参考中心。
  ///
  /// 返回：选择完成（取消则无操作）。
  Future<void> _showManualCity() async {
    final city = await showCitySelectorSheet(context);
    if (city == null) return;
    ref.read(locationCenterProvider.notifier).moveTo(city.lat, city.lng);
  }

  /// 相机变化 → 同步回 Dart 侧状态。
  ///
  /// 不在此处回推相机（那会与回调形成回环）：只有「点聚合圈放大」这类程序化改视角
  /// 的场景需要推，见 [_pushCameraToAmap]。
  ///
  /// 参数：
  /// - [camera]：高德回传的相机位置。
  void _onCameraMove(CameraPosition camera) {
    setState(() {
      _centerLat = camera.target.latitude;
      _centerLng = camera.target.longitude;
      // 上下限交给 `MinMaxZoomPreference`（原生相机越不出那个范围），这里不再夹取：
      // 两侧各夹一次，边界处会出现「状态已到边界、底图还能再走」的错位。
      _metersPerPixel = MapProjection.metersPerPixelForZoom(
        _centerLat,
        camera.zoom,
      );
    });
  }

  /// 相机静止后同步请求视口，触发一次 `/map/pins`。
  ///
  /// 参数：[camera] 高德回传的静止相机位置。
  void _onCameraMoveEnd(CameraPosition camera) {
    setState(() {
      _fetchLat = camera.target.latitude;
      _fetchLng = camera.target.longitude;
      _fetchMetersPerPixel = MapProjection.metersPerPixelForZoom(
        _fetchLat,
        camera.zoom,
      );
    });
  }

  /// 把当前渲染视口同步为请求视口（降级底图手势结束、定位居中时调用）。
  void _syncFetchViewport() {
    setState(() {
      _fetchLat = _centerLat;
      _fetchLng = _centerLng;
      _fetchMetersPerPixel = _metersPerPixel;
    });
  }

  /// 把 Dart 侧状态推给高德原生相机。
  ///
  /// 只在**程序化改视角**时调用（当前唯一场景：点聚合圈放大 2 倍）。不能在 build 里
  /// 无条件推 —— 那会与 [onCameraMove] 形成「推 → 回调 → 重建 → 再推」的回环。
  void _pushCameraToAmap() {
    _amapController?.moveCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(_centerLat, _centerLng),
        MapProjection.zoomForMetersPerPixel(_centerLat, _metersPerPixel),
      ),
    );
  }

  /// 缩小视野到覆盖当前半径档（G-138-1 角标的点击出口）。
  ///
  /// 半径档（1/3/5/10 km）把半径圆直径装进视口较短边；全城档无半径概念，
  /// 改为把返回 pin 的外接框装进视口（中心移到外接框中心）。两者都只改
  /// [_metersPerPixel]（及全城档的中心），不触筛选态 —— 缩小视野不等于改筛选。
  ///
  /// 上限夹在 [NfrPerf.clusterModeSwitchMetersPerPixel]（pin 模式上限）而非
  /// [_kMaxMetersPerPixel]：超过它服务端回 `mode=cluster`，而地图当前不渲染
  /// `clusters[]`（[126] 遗留），缩过头会直接空图 —— 比「看不到点」更糟。
  /// 代价是 10km/全城只能缩到 pin 上限、可能仍有屏外点，由角标文案承担告知。
  void _zoomOutToShowAll({
    required double viewportWidth,
    required double viewportHeight,
    required List<MapPinDto> pins,
  }) {
    final SearchRadius radius = ref.read(discoveryFilterProvider).radius;
    double targetLat = _centerLat;
    double targetLng = _centerLng;
    double targetMetersPerPixel;

    if (radius.km != null) {
      // 半径圆直径（2r）装进较短边：短边方向刚好容纳整个圆。
      final double shortSide = math.min(viewportWidth, viewportHeight);
      targetMetersPerPixel = 2 * radius.km! * 1000 / shortSide;
    } else {
      final bbox = _fitPinsBbox(pins, viewportWidth, viewportHeight);
      targetLat = bbox.lat;
      targetLng = bbox.lng;
      targetMetersPerPixel = bbox.metersPerPixel;
    }

    setState(() {
      _centerLat = targetLat;
      _centerLng = targetLng;
      _metersPerPixel = targetMetersPerPixel.clamp(
        _kMinMetersPerPixel,
        NfrPerf.clusterModeSwitchMetersPerPixel,
      );
      // 同步请求视口：缩小视野后立即按新视野拉一次 pins。
      _fetchLat = _centerLat;
      _fetchLng = _centerLng;
      _fetchMetersPerPixel = _metersPerPixel;
    });
    _pushCameraToAmap();
  }

  /// 计算能装下全部返回 pin 的视口（全城档「缩小视野」用）。
  ///
  /// 返回：(中心纬度, 中心经度, 米/像素)。pin 为空时退化为当前视口（防御分支，
  /// 正常路径由 `allOffScreen` 保证 pin 非空）。
  ({double lat, double lng, double metersPerPixel}) _fitPinsBbox(
    List<MapPinDto> pins,
    double viewportWidth,
    double viewportHeight,
  ) {
    if (pins.isEmpty) {
      return (lat: _centerLat, lng: _centerLng, metersPerPixel: _metersPerPixel);
    }
    double minLat = pins.first.lat;
    double maxLat = pins.first.lat;
    double minLng = pins.first.lng;
    double maxLng = pins.first.lng;
    for (final p in pins) {
      if (p.lat < minLat) minLat = p.lat;
      if (p.lat > maxLat) maxLat = p.lat;
      if (p.lng < minLng) minLng = p.lng;
      if (p.lng > maxLng) maxLng = p.lng;
    }
    final double centerLat = (minLat + maxLat) / 2;
    final double centerLng = (minLng + maxLng) / 2;
    // 纬向跨度（米）与经向跨度（米，乘 cos 纬度）。经向漏乘 cos 会在高纬被高估。
    final double latMeters = (maxLat - minLat) * _kMetersPerDegreeLat;
    final double lngMeters = (maxLng - minLng) *
        _kMetersPerDegreeLat *
        math.cos(centerLat * math.pi / 180);
    final double mppByWidth = viewportWidth > 0 ? lngMeters / viewportWidth : 0;
    final double mppByHeight =
        viewportHeight > 0 ? latMeters / viewportHeight : 0;
    return (
      lat: centerLat,
      lng: centerLng,
      // 取两方向中较严（米/像素更大）的那个，确保外接框整框都装得下。
      metersPerPixel: math.max(mppByWidth, mppByHeight),
    );
  }

  /// 上一帧**精算**出的 Marker 及其配套信息（拖动降级渲染的复用依据）。
  MapProjection? _renderedProjection;
  List<MapMarker>? _renderedMarkers;
  List<MapPinDto>? _renderedPins;

  /// 每边预精算余量（像素）。
  ///
  /// 参数：[screen] 屏幕视口投影。
  /// 返回：横向、纵向各自外扩的像素数。
  Offset _dragMargin(MapProjection screen) => Offset(
    screen.viewportSize.width * NfrPerf.pinDragMarginViewports,
    screen.viewportSize.height * NfrPerf.pinDragMarginViewports,
  );

  /// 精算视口的尺寸 = 屏 + 每边余量。
  ///
  /// 参数：[screen] 屏幕视口投影。
  /// 返回：Marker 坐标系的画布尺寸。
  Size _expandedSize(MapProjection screen) {
    final Offset margin = _dragMargin(screen);
    return Size(
      screen.viewportSize.width + margin.dx * 2,
      screen.viewportSize.height + margin.dy * 2,
    );
  }

  /// 装配本帧的 Marker 层：能复用就只平移，否则精算一次。
  ///
  /// **为什么可以只平移**：`MapProjection.toPixel` 对经纬度是仿射的，纯拖动时
  /// 每个点的像素位移是同一常量（证明见 [MapProjection.panDeltaTo]），故整层
  /// Marker 平移即等价于重算。POC-B 实测 1 万点拖动帧 P95 = 31.2ms，其中单帧
  /// Dart 四段（建点表 / 聚合 / 建Marker / 重建查表）均 O(n) 且占比均衡 ——
  /// 只平移就把这四段整体省掉，这是「1 万/5 万点达标」唯一可行的路线。
  ///
  /// **精算视口为什么外扩 margin**：外扩一圈后，精算一次即可覆盖「再拖动不超过
  /// margin」的整段过程；位移一旦超出 margin，屏边就会出现本该有却缺失的 Pin，
  /// 故那时必须重算。
  ///
  /// 参数：
  /// - [pins]：当前图钉（引用变化即数据变了，必须重算）；
  /// - [screen]：屏幕视口投影；
  /// - [derived]：pins 派生量（见 [_PinsDerived]）。
  ///
  /// 返回：[_MarkerFrame]。
  _MarkerFrame _markerLayerFrame(
    List<MapPinDto> pins,
    MapProjection screen,
    _PinsDerived derived,
  ) {
    final Offset margin = _dragMargin(screen);
    final MapProjection? rendered = _renderedProjection;
    final Size expanded = _expandedSize(screen);

    // 复用条件：同一批 pins + 同一缩放 + 同一视口尺寸 + 位移仍在余量内。
    // 缩放必须排除：像素尺度变了，平移表达不了（[MapProjection.panDeltaTo] 有 assert）。
    if (rendered != null &&
        identical(_renderedPins, pins) &&
        rendered.metersPerPixel == screen.metersPerPixel &&
        rendered.viewportSize.width == expanded.width &&
        rendered.viewportSize.height == expanded.height) {
      final delta = rendered.panDeltaTo(screen);
      if (delta.dx.abs() <= margin.dx && delta.dy.abs() <= margin.dy) {
        return (
          markers: _renderedMarkers!,
          // 精算层的坐标原点在「屏左上角 − margin」，故先补回 margin，再叠拖动位移。
          offset: Offset(delta.dx - margin.dx, delta.dy - margin.dy),
          layerSize: expanded,
        );
      }
    }

    // 精算：以当前相机为中心、视口外扩 margin，重算一次并记住它。
    final MapProjection expandedProjection = MapProjection(
      centerLat: screen.centerLat,
      centerLng: screen.centerLng,
      metersPerPixel: screen.metersPerPixel,
      viewportSize: (width: expanded.width, height: expanded.height),
    );
    final List<MapMarker> markers = _buildMarkersFor(
      pins,
      expandedProjection,
      derived,
    );
    _renderedProjection = expandedProjection;
    _renderedMarkers = markers;
    _renderedPins = pins;
    return (
      markers: markers,
      offset: Offset(-margin.dx, -margin.dy),
      layerSize: expanded,
    );
  }

  /// 上一帧派生量对应的 `pinList` 引用（引用相同即复用，见 [_derivedFor]）。
  List<MapPinDto>? _derivedPins;
  _PinsDerived? _derivedCache;

  /// 取 pins 的派生量，`pins` 与上次同一引用时直接复用。
  ///
  /// 参数：[pins] 当前图钉列表。
  /// 返回：[_PinsDerived]。
  ///
  /// **为什么按引用而不是按值判**：拖动地图时请求视口刻意不动（见 `_fetchLat`
  /// 注释），故 `pinsProvider` 不重发请求、`pinsAsync` 的数据在整段拖动里是**同一个
  /// List 实例** —— 引用相同即「数据没变」，缓存全程命中。相机停稳后
  /// `_syncFetchViewport` 换视口，引用随之改变，此时重建一次是应当付的成本。
  _PinsDerived _derivedFor(List<MapPinDto> pins) {
    final cached = _derivedCache;
    if (cached != null && identical(_derivedPins, pins)) return cached;

    final topCategoryByLeafId = <int, ListingCategory?>{};
    for (final p in pins) {
      // 用 containsKey 而非「取值为 null 就当没缓存」：大类本身可空
      // （分类树版本落后时查不到，§16.4 属预期内），null 不能区分两者。
      if (!topCategoryByLeafId.containsKey(p.leafCategoryId)) {
        topCategoryByLeafId[p.leafCategoryId] = topCategoryOf(p.leafCategoryId);
      }
    }

    final derived = _PinsDerived(
      ids: List<String>.generate(pins.length, (i) => pins[i].id.toString()),
      // 键用 id 字符串而非 int：Marker 层的标识是 String（§10.4.3），键类型必须与
      // 查表方 `marker.listingId` 一致，否则 `containsKey` 永远为 false ——
      // 而那是个 info 级提示，不报错。
      supplyDemandById: {
        for (final p in pins)
          p.id.toString(): supplyDemandFromCompact(p.typeCode),
      },
      topCategoryByLeafId: topCategoryByLeafId,
    );
    _derivedPins = pins;
    _derivedCache = derived;
    return derived;
  }

  /// 经纬度 → 像素 → 网格聚合 → 阈值判定 → Marker。
  ///
  /// **几何部分每帧重算，派生常量走缓存**：投影一变（拖动/缩放）像素坐标全变，
  /// 缓存命中率接近零，故 [ClusterPoint] 表与聚合必须每帧重算；而「叶子→大类」
  /// 查表与 id 转串**只依赖数据、不依赖相机**，已收进 [_PinsDerived] 按引用缓存。
  List<MapMarker> _buildMarkersFor(
    List<MapPinDto> pins,
    MapProjection projection,
    _PinsDerived derived,
  ) {
    final points = List<ClusterPoint>.generate(pins.length, (i) {
      final p = pins[i];
      final pixel = projection.toPixel(p.lat, p.lng);
      return ClusterPoint(
        // ClusterPoint.id 是本地分桶标识（String），服务端帖子 ID 为 int64；
        // 字符串随 pins 在 [_PinsDerived.ids] 里预计算，不在此逐帧分配。
        id: derived.ids[i],
        x: pixel.x,
        y: pixel.y,
        // 服务端下发的就是叶子类目 ID（`category_id` 列，如 10101）。
        leafCategoryId: p.leafCategoryId,
        // 一级大类由叶子 ID 经分类树查表得出，**不做算术推导**；
        // 查表结果按叶子 ID 去重缓存（见 [_derivedFor]）。
        topCategory: derived.topCategoryByLeafId[p.leafCategoryId],
      );
    }, growable: false);

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
        // 上下限防缩到路网糊成一片或放大到浮点精度失效。
        _metersPerPixel = (_scaleStartMetersPerPixel / details.scale).clamp(
          _kMinMetersPerPixel,
          _kMaxMetersPerPixel,
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
    bool cameraChanged = false;
    setState(() {
      switch (marker) {
        case SinglePointMarker():
          _selectedListingId = marker.listingId;
        case ClusterMarker():
          // 点聚合圈放大地图（PRD §6.4.2）。放大 2 倍而非直接展开列表 ——
          // 展开列表会让用户失去空间上下文，而聚合的意义正是空间聚集。
          _selectedListingId = null;
          _metersPerPixel = (_metersPerPixel / 2).clamp(
            _kMinMetersPerPixel,
            _kMaxMetersPerPixel,
          );
          cameraChanged = true;
      }
    });
    // 真地图分支的视角由原生相机持有，Dart 侧改了缩放必须推给相机，否则点聚合圈
    // 「点了没反应」。降级分支没有控制器，这行为空操作。
    if (cameraChanged) _pushCameraToAmap();
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
///
/// **标题与价格按需拉取**（2026-10-08 用户裁定）：`/map/pins` 是紧凑格式，
/// 按设计只有 id/坐标/类目/供需/完整度，**没有标题与价格**；而 PRD §6.4.2 要求
/// 卡片展示二者。补法是点开时拉一次 `GET /posts/{id}`（与详情页同一数据源），
/// 而不是往紧凑格式里加字段 —— 那会破坏它「压体积」的存在前提。
class _ListingInfoCard extends ConsumerWidget {
  const _ListingInfoCard({
    required this.listingId,
    required this.centerLat,
    required this.centerLng,
    required this.onClose,
  });

  /// 帖子 ID；选中态解析失败为 -1，与 detail 路由同口径（走「信息不存在」）。
  final int listingId;

  /// 距离基准点（当前视口中心）。
  final double centerLat;
  final double centerLng;

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(postDetailProvider(listingId));
    final ListingCategory? category = detailAsync.asData?.value.listing.category;

    return GestureDetector(
      // 整卡可点进详情（PRD §7.5 旅程第 1 步）。整卡而非只给一个小按钮：
      // 卡片本身就是「这条信息」的代表，用户的直觉是点它。
      onTap: () => context.push('/detail/$listingId'),
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
            // 类目未就绪（加载中/失败）时用中性底色 + 通用图钉 —— 不用灰块，
            // 灰块会被读成「图没加载出来」。
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: category?.color ?? Color(AppColors.border),
                shape: BoxShape.circle,
              ),
              child: Icon(
                category?.icon ?? Icons.place,
                size: 20,
                color: Color(AppColors.surface),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(child: _buildBody(detailAsync)),
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

  /// 卡片正文三态（loading / error / data）。
  ///
  /// 返回：(标题, 副标题, 是否显示「查看详情」)。
  Widget _buildBody(AsyncValue<ListingDetail> async) {
    final (String title, String subtitle, bool showHint) = async.when(
      loading: () => ('加载中…', '正在获取该条信息', false),
      error: (error, _) {
        // 41001 = 已下架/不存在，是用户的预期结果而非故障，文案与详情页同口径。
        if (asApiException(error).code == ApiErrorCode.postGone) {
          return ('该信息已下架或不存在', '看看附近其它信息', false);
        }
        return ('信息加载失败', '请稍后重试', false);
      },
      data: (detail) {
        final listing = detail.listing;
        final double meters = distanceInMeters(
          centerLat,
          centerLng,
          listing.latitude,
          listing.longitude,
        );
        // 1km 内用米（取整到 10m）：与列表卡片同一口径，避免两处距离写法不一致。
        final String distance = meters < 1000
            ? '${(meters / 10).round() * 10}m'
            : '${(meters / 1000).toStringAsFixed(1)}km';
        final String price = listing.priceLabel == null
            ? ''
            : ' · ${listing.priceLabel}';
        return (
          listing.title,
          '${listing.supplyDemand.label} · ${listing.category.label} · $distance$price',
          true,
        );
      },
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
        if (showHint) ...[
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
      ],
    );
  }
}

/// 探索数据态角标（[126]）：加载中 / 加载失败（可点重试）。
///
/// 用小角标而非全屏遮罩：底图与已到手的 Pin 仍可用，遮罩会把「还能看」
/// 变成「什么都看不了」，代价大于收益。
class _PinsStatusChip extends StatelessWidget {
  const _PinsStatusChip({required this.text, this.onTap});

  final String text;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1F000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// 一帧的 Marker 层装配结果（见 [_MapScreenState._markerLayerFrame]）。
///
/// - [markers]：要画的 Marker；
/// - [offset]：Marker 坐标 → 屏幕坐标的平移量（含余量偏移与拖动位移）；
/// - [layerSize]：Marker 坐标系的画布尺寸（即精算视口尺寸）。
typedef _MarkerFrame = ({List<MapMarker> markers, Offset offset, Size layerSize});

/// 一帧内反复用到的 pins 派生量（按 `pinList` 引用记忆化）。
///
/// **为什么值得缓存**：POC-B 分项实测（`tool/poc_b_pipeline_benchmark.dart`）显示，
/// 5 万点时单帧 Dart 开销约 25ms，其中「重建供需查表」单独 6.6ms，「建点表」8.8ms
/// 里的大头是 `topCategoryOf` 查表与 `id.toString()` 分配 —— 三者都只依赖 pins、
/// **不依赖相机**，却原本随每一帧重算。拖动时每秒几十帧，这是纯浪费。
class _PinsDerived {
  const _PinsDerived({
    required this.ids,
    required this.supplyDemandById,
    required this.topCategoryByLeafId,
  });

  /// 与 pins 同序的 id 字符串（省掉每帧数万次 `int.toString()` 分配）。
  final List<String> ids;

  /// 供需查表（MarkerLayer 据此画实心/空心图与 ? 角标）。
  final Map<String, SupplyDemand> supplyDemandById;

  /// 叶子类目 ID → 一级大类（查分类树）。
  ///
  /// 按叶子去重后通常只有几条，故缓存的是「叶子→大类」而非逐 pin。
  /// 值可空（查询不到时），判命中须用 `containsKey`。
  final Map<int, ListingCategory?> topCategoryByLeafId;
}

/// 定位前骨架屏（PRD §6.7 `:1305`）。
///
/// 半透明白遮罩 + 居中「正在定位」提示：定位通常在首帧内返回，遮罩只为
/// 避免用户先看到默认中心的底图再突然跳到自己位置（闪跳）。
class _LocatingSkeleton extends StatelessWidget {
  const _LocatingSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(AppColors.background).withValues(alpha: 0.7),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: AppSpacing.md),
          Text(
            '正在获取你的位置…',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

/// C 态降级提示条（PRD §6.8 / §6.4.4 C）。
///
/// 已授权但连续取点失败 ≥ [NfrLocation.locateFailThreshold] 时显示：告知
/// 已切换默认位置，并给「手动选城市」出口 —— 与 §6.4.4「不得做成必须授权
/// 才能继续的硬门禁」一致。
class _LocateFailedBanner extends StatelessWidget {
  const _LocateFailedBanner({required this.onManualCity});

  final VoidCallback onManualCity;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            Icons.location_off,
            size: 18,
            color: const Color(AppColors.textSecondary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '定位失败，已切换到默认位置',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
          TextButton(
            onPressed: onManualCity,
            child: const Text('手动选城市'),
          ),
        ],
      ),
    );
  }
}
