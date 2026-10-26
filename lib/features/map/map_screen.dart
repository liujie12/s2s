/// 丫圈首页 · 地图页（PRD §6.4.1 / §6.4.2）。
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
import '../discovery/condition_band.dart';
import '../discovery/condition_editor.dart';
import '../discovery/discovery_filter.dart';
import '../discovery/discovery_providers.dart';
import '../discovery/discovery_query.dart';
import '../discovery/effective_filter_provider.dart';
import '../discovery/filter_panel.dart';
import '../discovery/map_dto.dart';
import '../discovery/search_conditions.dart';
import '../discovery/search_intent.dart';
import '../discovery/voice_search_sheet.dart';
import '../location/location_center.dart';
import '../location/location_guide.dart';
import '../location/location_permission.dart';
import '../perf/layer_switch_recorder.dart';
import '../perf/perf_panel.dart';
import '../privacy/privacy_consent.dart';
import '../publish/ai_entry_sheet.dart';
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

/// 触发投影比例重校的纬度变化（度）。
///
/// 高德实际比例与公式的系数随纬度近似按 1/cos² 变化，跨城市或长距离拖动后
/// 需要重校；0.05° ≈ 5.5km，日常城区内拖动不会触发。
const double _kRecalibrateLatDelta = 0.05;

/// 相机中心离开「我的位置」超过视口短边的多少比例后，显示回位按钮。
///
/// 取 0.2：拖动几像素不会让按钮闪烁，而用户明显移开视野（城区内约一两百米）
/// 时能及时出现。用比例而非固定像素，平板/小屏的手感一致。
const double _kRecenterShowDistanceRatio = 0.2;

/// 「回到当前位置」按钮距地图底边的距离。
///
/// 排在 AI FAB（默认 bottom = md + 56）正上方，留出一个按钮高度与间距，
/// 两个圆形入口不会叠在一起。筛选面板展开或信息卡出现时该按钮不渲染
/// （见 build 中的显隐条件），故无需再避让。
const double _kRecenterButtonBottom =
    AppSpacing.md + 56 + 44 + AppSpacing.md;

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
  /// 用于程序化改视角（点聚合圈放大、回到当前位置）。
  AMapController? _amapController;

  /// 是否已取得过有效定位（首屏骨架屏判定）。
  bool _located = false;

  /// 连续取点失败次数（§6.8「≥ [NfrLocation.locateFailThreshold] 次 → C 态降级」）。
  int _locateFailCount = 0;

  /// AI FAB 的左上角位置（相对地图 Stack）。null = 默认右下角。
  ///
  /// 允许拖动的原因：筛选面板展开后占满底部，FAB 固定在右下会压住分类胶囊，
  /// 导致「全部/工作/房屋」点不到（2026-10-17 真机反馈）。
  Offset? _aiFabPosition;

  /// FAB 与地图 Stack 的 key：拖动时用两者换算当前位置并做边界夹取。
  final GlobalKey _aiFabKey = GlobalKey();
  final GlobalKey _mapStackKey = GlobalKey();

  /// 筛选面板 key：展开时测量其顶边，用于把 FAB 自动抬到面板上方。
  final GlobalKey _filterPanelKey = GlobalKey();

  /// 是否已排过「FAB 避让筛选面板」的帧后校正（防重复调度）。
  bool _fabAvoidScheduled = false;

  /// 条件带 key 与实测高度。
  ///
  /// 用途：条件带常驻，右上角按钮列必须始终让开它；高度取实测值而非写死，
  /// 跟随字号/换行变化（KTD11）。
  final GlobalKey _conditionBandKey = GlobalKey();
  double _conditionBandHeight = 0;
  bool _conditionBandMeasureScheduled = false;

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
    // 语义搜索结果变化 → 有地点锚点时把相机移过去（文本回显由条件带自己读门面）。
    // 与 locationCenter 监听分开：搜索锚点是**一次性**的，不能写回共享参考中心，
    // 否则撤销搜索后地图仍停在被搜索出来的地名上。
    ref.listen(searchIntentProvider, (previous, next) {
      final intent = next.intent;
      if (intent == null) return;
      final lat = intent.anchorLat;
      final lng = intent.anchorLng;
      if (lat != null && lng != null && (lat != _centerLat || lng != _centerLng)) {
        // 地址/小区筛选命中 → 相机直接跳到目标区域（2026-10-25 用户裁定）。
        // 有半径档时顺带把直径装进短边，落到目标区域就能看全筛选范围；
        // 无半径档则保持当前缩放（不擅自改变用户视野尺度）。
        final int? radiusMeters = intent.radiusMeters;
        setState(() {
          _centerLat = lat;
          _centerLng = lng;
          if (radiusMeters != null) {
            final size = MediaQuery.sizeOf(context);
            final double shortSide = math.min(
              size.width,
              size.height - kToolbarHeight - MediaQuery.paddingOf(context).top,
            );
            if (shortSide > 0) {
              _metersPerPixel = (2 * radiusMeters / shortSide).clamp(
                _kMinMetersPerPixel,
                _kMaxMetersPerPixel,
              );
            }
          }
        });
        _pushCameraToAmap();
        _syncFetchViewport();
      }
    });
    final consent = ref.watch(privacyConsentProvider);
    // 探索数据源：真后端 `/map/pins`（[126] 前端段切入；此前读的是本地 mock 样例，
    // 而详情页读真后端 —— 两者 ID 空间不通，正是「详情看不了」的根因）。
    // 五要素随筛选态与视口变化；`PinsQuery` 实现值相等，故同一组合只发一次。
    // 当前生效条件：唯一来源是投影，页面不再自己逐槽位回落。
    final effective = ref.watch(effectiveFilterProvider);
    final double queryLat = effective.anchorLat ?? _fetchLat;
    final double queryLng = effective.anchorLng ?? _fetchLng;
    final pinsQuery = PinsQuery(
      leafCategoryIds: effective.leafCategoryIds,
      postTypes: postTypesFor(effective.supplyDemand),
      radius: toApiRadius(effective.radius),
      gridId: gridIdOf(queryLng, queryLat),
      // 分类树版本号取本地常量真源（随包发布，与服务端不一致时契约只回 stale 标记、
      // 不报错，故落后是降级而非故障）。
      categoryVersion: categoryTreeVersion,
      // lng/lat/zoom 取**请求视口**而非渲染视口，见 `_fetchLat` 的注释。
      lng: queryLng,
      lat: queryLat,
      zoom: MapProjection.zoomForMetersPerPixel(queryLat, _fetchMetersPerPixel),
      // 契约的价格参数是 double；本地筛选用 int 元。
      priceMin: effective.priceMin?.toDouble(),
      priceMax: effective.priceMax?.toDouble(),
      // 口语地址命中的小区：等值过滤「只看这个小区」，与价格/半径叠加。
      communityId: effective.communityId,
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
          // 「回到当前位置」显隐：以本次会话最优定位点为准（不是冻结的共享中心），
          // 相机中心偏离它超过视口短边的 [_kRecenterShowDistanceRatio] 才显示。
          final LocationFix? currentFix = ref.watch(locationFixProvider);
          final bool showRecenter = currentFix != null &&
              projection.isAwayFromCenter(
                currentFix.lat,
                currentFix.lng,
                thresholdPx: math.min(
                      constraints.maxWidth,
                      constraints.maxHeight,
                    ) *
                    _kRecenterShowDistanceRatio,
              );
          // 数据态：加载中/失败时 pinList/clusterList 为空，底图照常渲染（不阻塞），
          // 状态另行以角标提示（见下方 _PinsStatusChip）。
          final merged = pinsAsync.asData?.value;
          final bool clusterMode = merged?.mode == 'cluster';
          final rawPins = merged?.pins ?? const <MapPinDto>[];
          // 搜索圈内精裁（R10）：服务端按网格档位扩圈，边缘会多出圈外点；
          // 客户端按**真实米数**再过一遍，保证「圈内只显示圈内」。
          final int? searchRadiusMeters = effective.radiusMeters;
          final double circleLat = effective.anchorLat ?? queryLat;
          final double circleLng = effective.anchorLng ?? queryLng;
          final bool cropByCircle = searchRadiusMeters != null &&
              effective.radius != SearchRadius.city;
          final pinList = cropByCircle
              ? rawPins
                    .where(
                      (pin) =>
                          _distanceMeters(circleLat, circleLng, pin.lat, pin.lng) <=
                          searchRadiusMeters,
                    )
                    .toList()
              : rawPins;
          final clusterList = merged?.clusters ?? const <MapClusterDto>[];
          // pins/簇派生量按**引用**记忆化，避免随每一帧重算（见 [_PinsDerived]）。
          final derived = _derivedFor(pinList, clusterList);
          // Marker 走「拖动中降级渲染」：能复用就只平移，超出余量才精算。
          final frame = _markerLayerFrame(
            pinList,
            clusterList,
            clusterMode,
            projection,
            derived,
          );
          final markers = frame.markers;
          // 图层切换耗时（[140]）：必须在 markers 算好之后调用 —— 渲染段的起点
          // 是「新分类的 Pin 已排好、这一帧即将绘制」。
          _measureLayerSwitchRender(pinsAsync);
          final supplyDemandById = derived.supplyDemandById;
          // G-138-1：有 pin 却全部投影在视口外 → 提示「视野外还有 N 条」。
          // 用「pinList 非空 + 无可见 marker」而非「total > 0」：mode=cluster 时
          // 服务端回 clusters[]、pinList 为空，簇由服务端按当前视野预聚合，本就在
          // 屏内，不存在「屏外有点」的情况，不该弹这条提示。
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

          final bool panelExpanded = ref.watch(filterPanelExpandedProvider);
          // 面板展开时排一次帧后避让，让 FAB 抬到面板上方（入口保持可见）。
          if (panelExpanded) _avoidFilterPanel();
          // 条件带高度随字号/换行变化，实测后驱动右上角按钮列下移。
          _measureConditionBand();

          return Stack(
            key: _mapStackKey,
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
              // 顶部浮层：两行条件带 + 其下的数据态角标。
              Positioned(
                left: AppSpacing.lg,
                right: AppSpacing.lg,
                top: AppSpacing.md,
                child: Column(
                  key: _conditionBandKey,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ConditionBand(
                      countLabel: pinsAsync.asData == null ? null : '$pinsTotal 条',
                      onVoice: () => showVoiceSearchSheet(
                        context,
                        anchorLat: _centerLat,
                        anchorLng: _centerLng,
                      ),
                      onEditChip: (chip) => showConditionEditor(context, ref, chip),
                      onAddCondition: () => showAddConditionSheet(context, ref),
                      onRetry: () => ref.read(searchConditionsProvider.notifier).submit(
                            text: ref.read(searchConditionsProvider).queryText,
                          ),
                    ),
                    // 探索数据态（[126]）：加载中/失败必须可见 —— 否则「附近没有信息」
                    // 与「数据没回来」在用户眼里完全同形，而两者的处置方式相反。
                    if (pinsAsync.isLoading || pinsAsync.hasError) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _PinsStatusChip(
                        text: pinsAsync.hasError ? '加载失败 · 点击重试' : '正在加载附近信息…',
                        onTap: pinsAsync.hasError
                            ? () => ref.invalidate(pinsProvider(pinsQuery))
                            : null,
                      ),
                    ] else if (allOffScreen) ...[
                      const SizedBox(height: AppSpacing.sm),
                      _PinsStatusChip(
                        text: '视野外还有 $pinsTotal 条，缩小地图查看',
                        onTap: () => _zoomOutToShowAll(
                          viewportWidth: constraints.maxWidth,
                          viewportHeight: constraints.maxHeight,
                          pins: pinList,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 右上角按钮列：始终让开条件带（条件带常驻，不再按有无回执判断）。
              Positioned(
                right: AppSpacing.lg,
                top: AppSpacing.md + _conditionBandHeight,
                child: const _FilterEntryButton(),
              ),
              // 列表视图入口（PRD §10.1：地图与列表是同层级的两个视图）。
              // 放在筛选入口正下方而非底部中央：底部要留给筛选面板与信息卡，
              // 三者叠在一起会互相遮挡。
              Positioned(
                right: AppSpacing.lg,
                top: AppSpacing.md + _conditionBandHeight + 44 + AppSpacing.sm,
                child: const _ListViewEntryButton(),
              ),
              // 「回到当前位置」：相机被拖离定位点后出现，点击把视口移回用户位置。
              // 底部有筛选面板或信息卡时不渲染，避免三者叠在一起互相遮挡。
              if (showRecenter && !panelExpanded && _selectedListingId == null)
                Positioned(
                  right: AppSpacing.lg,
                  bottom: _kRecenterButtonBottom,
                  child: _RecenterButton(onTap: _recenterToCurrentLocation),
                ),
              if (panelExpanded)
                Positioned(
                  left: AppSpacing.md,
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  // 只有地图页把分类切换计为图层切换耗时（[140]）：列表页复用同一
                  // 控件但没有 Pin 渲染终点，量不出这条链路（见 FilterPanel 的注释）。
                  child: FilterPanel(
                    key: _filterPanelKey,
                    measureLayerSwitch: true,
                  ),
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
              // 「AI 帮我发」FAB（PRD §6.13 T6-①）：悬浮于首页右下，唤起四模式。
              // 可拖动；筛选面板展开时自动抬到面板上方（不隐藏，保证入口始终可见）。
              _buildAiFab(constraints),
            ],
          );
        },
      ),
    );
  }

  /// 构建可拖动的「AI 帮我发」FAB。
  ///
  /// 未拖动过时仍用右下角定位（`right/bottom`），拖动过一次后改用
  /// 左上角坐标（[_aiFabPosition]），让按钮停在用户放下的位置。
  ///
  /// 参数：[constraints] 地图 Stack 的尺寸约束（拖动边界夹取用）。
  ///
  /// 返回：定位好的 FAB 控件。
  Widget _buildAiFab(BoxConstraints constraints) {
    final position = _aiFabPosition;
    final fab = GestureDetector(
      key: _aiFabKey,
      // 只接管拖动；点击仍由内部 InkWell 处理（位移小于 slop 时两个手势不冲突）。
      onPanUpdate: (details) => _moveAiFab(details.delta, constraints),
      child: AiPublishFab(onTap: () => startAiPublish(context, ref)),
    );
    if (position == null) {
      return Positioned(
        right: AppSpacing.md,
        bottom: AppSpacing.md + 56,
        child: fab,
      );
    }
    return Positioned(left: position.dx, top: position.dy, child: fab);
  }

  /// 按拖动增量移动 FAB，并把左上角夹在 Stack 可见范围内。
  ///
  /// 参数：
  /// - [delta] 本次拖动位移；
  /// - [constraints] Stack 尺寸约束。
  ///
  /// 返回：void。
  void _moveAiFab(Offset delta, BoxConstraints constraints) {
    final fabBox = _aiFabKey.currentContext?.findRenderObject() as RenderBox?;
    final stackBox =
        _mapStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (fabBox == null || stackBox == null) return;
    // 当前位置从渲染树读：无论此刻由 right/bottom 还是 left/top 定位都成立。
    final current = fabBox.localToGlobal(Offset.zero, ancestor: stackBox);
    final next = Offset(
      (current.dx + delta.dx).clamp(
        0.0,
        math.max(0.0, constraints.maxWidth - fabBox.size.width),
      ),
      (current.dy + delta.dy).clamp(
        0.0,
        math.max(0.0, constraints.maxHeight - fabBox.size.height),
      ),
    );
    setState(() => _aiFabPosition = next);
  }

  /// 筛选面板展开后，把 FAB 抬到面板顶边之上（帧后测量，避免遮挡分类胶囊）。
  ///
  /// **不隐藏 FAB**：它是发布主入口之一，展开筛选时消失会让用户以为功能没了
  /// （2026-10-17 真机反馈）。只做位置避让，入口始终可见。
  ///
  /// 参数：无。
  ///
  /// 返回：void（实际移动在帧后回调里完成）。
  void _avoidFilterPanel() {
    if (_fabAvoidScheduled) return;
    _fabAvoidScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fabAvoidScheduled = false;
      if (!mounted) return;
      final fabBox = _aiFabKey.currentContext?.findRenderObject() as RenderBox?;
      final stackBox =
          _mapStackKey.currentContext?.findRenderObject() as RenderBox?;
      final panelBox =
          _filterPanelKey.currentContext?.findRenderObject() as RenderBox?;
      if (fabBox == null || stackBox == null || panelBox == null) return;
      final panelTop =
          panelBox.localToGlobal(Offset.zero, ancestor: stackBox).dy;
      final fabTopLeft = fabBox.localToGlobal(Offset.zero, ancestor: stackBox);
      final gap = AppSpacing.md.toDouble();
      // 已经在面板上方（含安全间距）就不动，避免每帧抖动。
      if (fabTopLeft.dy + fabBox.size.height + gap <= panelTop) return;
      final nextTop = math.max(0.0, panelTop - fabBox.size.height - gap);
      setState(() => _aiFabPosition = Offset(fabTopLeft.dx, nextTop));
    });
  }

  /// 测量条件带高度，供右上角按钮列下移避让。
  ///
  /// 参数：无。
  /// 返回：void（实际测量在帧后回调完成；同帧只调度一次）。
  void _measureConditionBand() {
    if (_conditionBandMeasureScheduled) return;
    _conditionBandMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _conditionBandMeasureScheduled = false;
      if (!mounted) return;
      final box = _conditionBandKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null) return;
      // 条与按钮之间留一个最小间距，避免贴死。
      final double measured = box.size.height + AppSpacing.sm;
      if ((measured - _conditionBandHeight).abs() < 0.5) return;
      setState(() => _conditionBandHeight = measured);
    });
  }

  /// 导航栏（PRD §6.4.1）。
  ///
  /// 搜索输入已移入条件带第一行：两处都放输入框会出现两个 controller、
  /// 两份文本，正是本轮要消灭的双源问题。
  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      toolbarHeight: 48,
      backgroundColor: Color(AppColors.surface),
      elevation: 0,
      titleSpacing: AppSpacing.md,
      title: Text(
        '丫圈',
        style: TextStyle(
          fontSize: AppTypeScale.h2.size,
          fontWeight: FontWeight.w600,
          color: Color(AppColors.textPrimary),
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
  ///
  /// 不再绘制搜索圈（2026-10-25 用户裁定）：半径只用于**过滤** Pin，
  /// 圈形遮罩会额外压暗地图、干扰看图。
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
            // 降级底图没有原生相机，长按取点由本层把像素换算成经纬度。
            onLongPressStart: (details) {
              final point = projection.toLatLng(
                details.localPosition.dx,
                details.localPosition.dy,
              );
              showVoiceSearchSheet(
                context,
                anchorLat: point.lat,
                anchorLng: point.lng,
              );
            },
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
        // 子树不重画（一次性探针实测 30 帧只画 1 次、每帧 6.76→0.89ms；
        // 探针已删、结论见说明文档），挪到 Transform 之外这层优化立刻失效。
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
      onMapCreated: (controller) {
        _amapController = controller;
        // 初始相机由原生侧在创建时应用，其 onCameraMove 早于 Dart 订阅，拿不到
        // 真实 zoom；不回读会让投影尺度与底图不一致（见 [_syncCameraFromNative]）。
        _syncCameraFromNative();
      },
      onCameraMove: _onCameraMove,
      // 长按地图任意点 → 以该点为空间锚点唤起语音搜索（R1「按压点即空间锚点」）。
      onLongPress: (latLng) => showVoiceSearchSheet(
        context,
        anchorLat: latLng.latitude,
        anchorLng: latLng.longitude,
      ),
      // 手势结束才同步请求视口 → 一次拖动只发一次请求。
      // 用插件原生回调而非自写 debounce 计时器：不引入「多久算停」的魔法时长。
      onCameraMoveEnd: _onCameraMoveEnd,
      // 自持投影只支持「正北 + 俯视」：Pin 坐标按经纬度线性换算，不含 bearing/tilt。
      // 放开旋转/倾斜手势后，底图会转/倾斜而 Pin 不跟，表现为拖动后点位整体漂移。
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
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
    // 记录本次会话「最优定位点」：发布取点用它（首点常是粗定位）。
    // 不写共享中心 —— 那会触发相机跟随，违背「仅首点居中一次」。
    ref.read(locationFixProvider.notifier).update(
          lat: location.latLng.latitude,
          lng: location.latLng.longitude,
          accuracy: location.accuracy,
        );
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
      //
      // 乘 [_amapScaleFactor]：高德实际渲染比例与 Web 墨卡托公式存在恒定偏差
      // （真机实测 1.36–1.39，随纬度约等于 1/cos²），偏差由启动时
      // [_calibrateAmapScale] 用原生投影实测得出，不写死常数。
      _metersPerPixel = MapProjection.metersPerPixelForZoom(
        _centerLat,
        camera.zoom,
      ) * _amapScaleFactor;
    });
  }

  /// 高德实际渲染比例 / Web 墨卡托公式比例（启动时实测，见 [_calibrateAmapScale]）。
  ///
  /// 默认 1 表示「未校准」；校准成功后为真机实测值（本机约 1.36–1.39）。
  double _amapScaleFactor = 1;

  /// 上次校准所在的纬度（`null` = 尚未校准）。
  ///
  /// 该系数与纬度相关（约 1/cos²），跨城市/长距离拖动后须重校；
  /// 阈值见 [_kRecalibrateLatDelta] 的注释。
  double? _calibratedLat;

  /// 地图创建后从原生相机回读一次真实视角，并校准投影比例。
  ///
  /// **为什么必须回读**：初始相机由原生侧在创建时应用，那次 `onCameraMove` 早于
  /// Dart 侧订阅，拿不到真实 zoom；不回读会直接用「字段默认值」投影。
  ///
  /// 实现走插件原生的 `map#update`：它应用 options 后返回当前相机，传空 options
  /// 即「只读相机」。插件未暴露读取相机的公开方法，故直接经 controller 的
  /// 通道调用（用后即弃，不依赖返回值之外的任何行为）。
  Future<void> _syncCameraFromNative() async {
    final controller = _amapController;
    if (controller == null) return;
    try {
      // 插件把 channel 标为 @visibleForTesting，但读取相机没有公开替代。
      // ignore: invalid_use_of_visible_for_testing_member
      final raw = await controller.channel.invokeMethod<dynamic>(
        'map#update',
        <String, dynamic>{'options': <String, dynamic>{}},
      );
      final camera = CameraPosition.fromMap(raw);
      if (camera == null || !mounted) return;
      setState(() {
        _centerLat = camera.target.latitude;
        _centerLng = camera.target.longitude;
        _metersPerPixel = MapProjection.metersPerPixelForZoom(
          _centerLat,
          camera.zoom,
        ) * _amapScaleFactor;
        // 初始请求尚未发出时一并校正，避免用旧尺度算出与实际视野不符的 zoom。
        _fetchLat = _centerLat;
        _fetchLng = _centerLng;
        _fetchMetersPerPixel = _metersPerPixel;
      });
      await _calibrateAmapScale(camera);
    } catch (_) {
      // 读取失败不阻断首屏：保持现有状态（最坏情况是仍按旧尺度投影）。
    }
  }

  /// 用原生投影实测「米/逻辑像素」，校准 [MapProjection] 与高德底图的尺度差。
  ///
  /// **背景**：高德相机回传的 zoom 与 Web 墨卡托公式换算出的比例尺不一致（真机
  /// 实测恒定偏大 1.36–1.39 倍，量级随纬度约等于 1/cos²）。若直接按公式投影，
  /// 纯拖动时 Pin 的像素位移是底图的 1.36 倍，表现为「越拖越偏」。
  ///
  /// **做法**：取当前中心与正北/正东各约 100 逻辑像素的两个点，调原生
  /// `toScreenCoordinate` 得到真实像素差，反算实际比例与公式比例之比。
  /// 不写死任何魔法常数，换机型/换 SDK 版本自动适配。
  ///
  /// 参数：[camera] 原生相机位置（提供中心与 zoom）。
  Future<void> _calibrateAmapScale(CameraPosition camera) async {
    final controller = _amapController;
    if (controller == null) return;
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final double lat0 = camera.target.latitude;
    final double lng0 = camera.target.longitude;
    final double formulaMpp = MapProjection.metersPerPixelForZoom(lat0, camera.zoom);
    if (formulaMpp <= 0) return;
    // 偏移量按「约 100 逻辑像素」取，保证在任意缩放下都落在视野附近且像素差足够大。
    final double dLat = formulaMpp * 100 / _kMetersPerDegreeLat;
    final double dLng =
        dLat / math.cos(lat0 * math.pi / 180);
    try {
      final p0 = await controller.toScreenCoordinate(LatLng(lat0, lng0));
      final pLat =
          await controller.toScreenCoordinate(LatLng(lat0 + dLat, lng0));
      final pLng =
          await controller.toScreenCoordinate(LatLng(lat0, lng0 + dLng));
      if (!mounted) return;
      final double dy = (pLat.y - p0.y).abs().toDouble();
      final double dx = (pLng.x - p0.x).abs().toDouble();
      if (dy <= 0 || dx <= 0) return;
      // 原生坐标是物理像素，换算成「米/逻辑像素」需乘 dpr。
      final double mppLat = dLat * _kMetersPerDegreeLat / dy * dpr;
      final double mppLng =
          dLng * _kMetersPerDegreeLat * math.cos(lat0 * math.pi / 180) / dx * dpr;
      final double actualMpp = (mppLat + mppLng) / 2;
      final double factor = actualMpp / formulaMpp;
      if (!factor.isFinite || factor <= 0) return;
      setState(() {
        _amapScaleFactor = factor;
        _calibratedLat = lat0;
        _metersPerPixel = actualMpp;
        _fetchMetersPerPixel = actualMpp;
      });
    } catch (_) {
      // 校准失败不阻断首屏：保持公式值（最坏情况是拖动仍有偏差）。
    }
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
      ) * _amapScaleFactor;
    });
    // 纬度变化超过阈值（跨城市/长距离拖动）时重校比例系数：
    // 该系数随纬度约按 1/cos² 变化，旧值会让 Pin 在新纬度上重新出现拖偏。
    final double? calibratedLat = _calibratedLat;
    if (calibratedLat == null ||
        (camera.target.latitude - calibratedLat).abs() > _kRecalibrateLatDelta) {
      _calibrateAmapScale(camera);
    }
  }

  /// 把当前渲染视口同步为请求视口（降级底图手势结束、定位居中时调用）。
  void _syncFetchViewport() {
    setState(() {
      _fetchLat = _centerLat;
      _fetchLng = _centerLng;
      _fetchMetersPerPixel = _metersPerPixel;
    });
  }

  /// 把相机移回「我的位置」（「回到当前位置」按钮的点击出口）。
  ///
  /// 取本次会话最优定位点（[locationFixProvider]），而不是共享参考中心 ——
  /// 后者按 2026-10-08 裁定冻结在首个有效点上，首点常是粗定位。
  ///
  /// 保持当前缩放级别：用户只是把视野拖开了，没有表达换缩放的意图，
  /// 顺手改 zoom 会让画面突然跳变。中心变化后同步请求视口，立即按新中心拉 pin。
  ///
  /// 返回：void。无有效定位时静默返回（按钮本身不会在无定位时渲染）。
  void _recenterToCurrentLocation() {
    final fix = ref.read(locationFixProvider);
    if (fix == null) return;
    setState(() {
      _centerLat = fix.lat;
      _centerLng = fix.lng;
      _fetchLat = fix.lat;
      _fetchLng = fix.lng;
      _fetchMetersPerPixel = _metersPerPixel;
    });
    _pushCameraToAmap();
  }

  /// 把 Dart 侧状态推给高德原生相机。
  ///
  /// 只在**程序化改视角**时调用（点聚合圈放大 2 倍、回到当前位置）。不能在 build 里
  /// 无条件推 —— 那会与 [onCameraMove] 形成「推 → 回调 → 重建 → 再推」的回环。
  void _pushCameraToAmap() {
    _amapController?.moveCamera(
      CameraUpdate.newLatLngZoom(
        LatLng(_centerLat, _centerLng),
        // 目标 mpp 是「实际米/逻辑像素」，而 zoom 与 mpp 的公式关系是高德的
        // 相机口径（偏大 [_amapScaleFactor] 倍），故换算前先除掉该系数。
        MapProjection.zoomForMetersPerPixel(
          _centerLat,
          _metersPerPixel / _amapScaleFactor,
        ),
      ),
    );
  }

  /// 缩小视野到覆盖当前半径档（G-138-1 角标的点击出口）。
  ///
  /// 半径档（1/3/5/10 km）把半径圆直径装进视口较短边；全城档无半径概念，
  /// 改为把返回 pin 的外接框装进视口（中心移到外接框中心）。两者都只改
  /// [_metersPerPixel]（及全城档的中心），不触筛选态 —— 缩小视野不等于改筛选。
  ///
  /// 上限用 [_kMaxMetersPerPixel]（与手势缩放同一对边界）。跨过
  /// [NfrPerf.clusterModeSwitchMetersPerPixel] 后服务端改回 `mode=cluster`，
  /// 地图按 `clusters[]` 渲染，因此不再需要为「缩过头会空图」而提前夹断 ——
  /// 10km 档也能把整个半径圆装进视口。
  void _zoomOutToShowAll({
    required double viewportWidth,
    required double viewportHeight,
    required List<MapPinDto> pins,
  }) {
    final SearchRadius radius = ref.read(effectiveFilterProvider).radius;
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
        _kMaxMetersPerPixel,
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
  List<MapClusterDto>? _renderedClusters;
  bool? _renderedClusterMode;

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
  /// - [clusters]：服务端预聚合簇（cluster 模式下与 pins 二选一）；
  /// - [clusterMode]：当前响应是否为 `mode=cluster`；
  /// - [screen]：屏幕视口投影；
  /// - [derived]：pins/簇派生量（见 [_PinsDerived]）。
  ///
  /// 返回：[_MarkerFrame]。
  _MarkerFrame _markerLayerFrame(
    List<MapPinDto> pins,
    List<MapClusterDto> clusters,
    bool clusterMode,
    MapProjection screen,
    _PinsDerived derived,
  ) {
    final Offset margin = _dragMargin(screen);
    final MapProjection? rendered = _renderedProjection;
    final Size expanded = _expandedSize(screen);

    // 复用条件：同一批 pins/簇 + 同一模式 + 同一缩放 + 同一视口尺寸 + 位移仍在余量内。
    // 缩放必须排除：像素尺度变了，平移表达不了（[MapProjection.panDeltaTo] 有 assert）。
    if (rendered != null &&
        identical(_renderedPins, pins) &&
        identical(_renderedClusters, clusters) &&
        _renderedClusterMode == clusterMode &&
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
    // 图层切换耗时的聚合段（[140] / PRD §6.10）：只属于「新数据首次聚合」。
    // 拖动中每帧都会走到这里（像素尺度变了必须重算），但 recorder 对一个会话
    // 只记第一次，故后续帧的重算不会把聚合段越拉越长。
    final recorder = ref.read(layerSwitchRecorderProvider);
    recorder.beginAgg();
    final List<MapMarker> markers = clusterMode
        ? _buildClusterMarkersFor(clusters, expandedProjection, derived)
        : _buildMarkersFor(pins, expandedProjection, derived);
    recorder.endAgg();
    _renderedProjection = expandedProjection;
    _renderedMarkers = markers;
    _renderedPins = pins;
    _renderedClusters = clusters;
    _renderedClusterMode = clusterMode;
    return (
      markers: markers,
      offset: Offset(-margin.dx, -margin.dy),
      layerSize: expanded,
    );
  }

  /// 图层切换耗时的渲染段与收尾（[140] / PRD §6.10）。
  ///
  /// **两个口径要点**：
  /// - 终点是「Pin **首屏绘制完成**」而非「build 结束」，故收尾放进
  ///   `addPostFrameCallback` —— 它在该帧绘制结束后才跑；
  /// - 只有「新数据首次上屏」那一帧才算：`pinsProvider` 在会话期间处于
  ///   loading（新 family 键 → 新 provider 实例），故 `hasValue` 首次为真的那一帧
  ///   正是本次切换的数据到达帧。`markRenderStart` 与 `finish` 都按会话只生效一次。
  ///
  /// 无活跃会话时（拖动结束触发的视口重取）整个方法直接返回。
  ///
  /// 参数：[pinsAsync] 当前图钉异步态。
  void _measureLayerSwitchRender(AsyncValue<MergedPins> pinsAsync) {
    final recorder = ref.read(layerSwitchRecorderProvider);
    final int? sessionId = recorder.activeSessionId;
    if (sessionId == null) return;

    if (pinsAsync.hasError) {
      // 数据没回来：本次切换未走完。不记渲染段（没有可绘制的 Pin）。
      recorder.finish(
        sessionId: sessionId,
        outcome: LayerSwitchOutcome.failed,
      );
      return;
    }
    // 仍在加载：等数据到达的那一帧。
    if (!pinsAsync.hasValue) return;

    recorder.markRenderStart();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 跨帧后会话可能已被新切换取代 —— finish 会按 sessionId 自行作废。
      recorder.finish(
        sessionId: sessionId,
        outcome: LayerSwitchOutcome.success,
      );
    });
  }

  /// 上一帧派生量对应的 `pinList` / `clusters` 引用（引用相同即复用，见 [_derivedFor]）。
  List<MapPinDto>? _derivedPins;
  List<MapClusterDto>? _derivedClusters;
  _PinsDerived? _derivedCache;

  /// 取 pins/簇的派生量，两个列表都与上次同一引用时直接复用。
  ///
  /// 参数：
  /// - [pins] 当前图钉列表；
  /// - [clusters] 当前服务端预聚合簇列表。
  /// 返回：[_PinsDerived]。
  ///
  /// **为什么按引用而不是按值判**：拖动地图时请求视口刻意不动（见 `_fetchLat`
  /// 注释），故 `pinsProvider` 不重发请求、`pinsAsync` 的数据在整段拖动里是**同一个
  /// List 实例** —— 引用相同即「数据没变」，缓存全程命中。相机停稳后
  /// `_syncFetchViewport` 换视口，引用随之改变，此时重建一次是应当付的成本。
  _PinsDerived _derivedFor(
    List<MapPinDto> pins,
    List<MapClusterDto> clusters,
  ) {
    final cached = _derivedCache;
    if (cached != null &&
        identical(_derivedPins, pins) &&
        identical(_derivedClusters, clusters)) {
      return cached;
    }

    final topCategoryByLeafId = <int, ListingCategory?>{};
    for (final p in pins) {
      // 用 containsKey 而非「取值为 null 就当没缓存」：大类本身可空
      // （分类树版本落后时查不到，§16.4 属预期内），null 不能区分两者。
      if (!topCategoryByLeafId.containsKey(p.leafCategoryId)) {
        topCategoryByLeafId[p.leafCategoryId] = topCategoryOf(p.leafCategoryId);
      }
    }
    // 服务端簇的 category_id 是叶子类目（可空）。当前后端 toCluster 恒回 null，
    // 但契约允许下发，故按同一张表预查，避免以后接通时再改一遍渲染层。
    for (final c in clusters) {
      final leafId = c.categoryId;
      if (leafId != null && !topCategoryByLeafId.containsKey(leafId)) {
        topCategoryByLeafId[leafId] = topCategoryOf(leafId);
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
    _derivedClusters = clusters;
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

  /// 服务端预聚合簇 → 可渲染的 [ClusterMarker]。
  ///
  /// 远景（米/像素 > 阈值）服务端只回 `clusters[]`，本方法把每簇的经纬度投影成
  /// 屏幕坐标，并复用 [ClusterMarker] 的「圆圈 + 数量」绘制。簇内成员 ID 服务端
  /// 不下发，点击语义是「放大 2 倍」而非展开列表，故 [ClusterMarker.memberIds] 传空。
  ///
  /// 参数：
  /// - [clusters] 服务端预聚合簇；
  /// - [projection] 当前精算视口投影；
  /// - [derived] 叶子类目 → 一级大类查表。
  /// 返回：[ClusterMarker] 列表。
  List<MapMarker> _buildClusterMarkersFor(
    List<MapClusterDto> clusters,
    MapProjection projection,
    _PinsDerived derived,
  ) {
    final markers = <MapMarker>[];
    for (final c in clusters) {
      final pixel = projection.toPixel(c.lat, c.lng);
      final leafId = c.categoryId;
      markers.add(
        ClusterMarker(
          x: pixel.x,
          y: pixel.y,
          // 后端当前恒回 null（toCluster 不取类目），渲染层按中性配色处理；
          // 契约允许下发时这里已能按叶子 ID 查到一级大类。
          topCategory: leafId == null
              ? null
              : derived.topCategoryByLeafId[leafId],
          count: c.count,
          memberIds: const [],
        ),
      );
    }
    return markers;
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

/// 「回到当前位置」按钮（相机离开定位点后出现）。
///
/// 尺寸与样式对齐右上角的筛选/列表入口：44×44 白色圆形 + 阴影，
/// 保证地图上三个悬浮入口看起来是同一套控件。
class _RecenterButton extends StatelessWidget {
  const _RecenterButton({required this.onTap});

  /// 点击回调：把相机移回用户当前位置。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
          Icons.my_location,
          color: Color(AppColors.primary),
        ),
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

/// 两点间球面距离（米），Haversine。
///
/// 参数：
/// - [lat1]/[lng1] 起点纬度/经度；
/// - [lat2]/[lng2] 终点纬度/经度。
/// 返回：球面距离（米）。
double _distanceMeters(double lat1, double lng1, double lat2, double lng2) {
  const earthRadiusMeters = 6371000.0;
  final dLat = (lat2 - lat1) * math.pi / 180;
  final dLng = (lng2 - lng1) * math.pi / 180;
  final a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * math.pi / 180) *
          math.cos(lat2 * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadiusMeters * math.asin(math.min(1, math.sqrt(a)));
}

