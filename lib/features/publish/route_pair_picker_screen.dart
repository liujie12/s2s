/// 起终点选择页（计划 U3；R1–R15 / KTD5–KTD8）。
///
/// **为什么新建一页而不是复用发现侧的 [MapSelectorScreen]**：本页要一次收到
/// 两个点、给出两点之间的驾车距离、并支持一键对调；发现侧选点页是「单点 +
/// 半径」的语义，两边合并会让同一个页面出现两套互斥的底部面板。本期两边并存，
/// 收敛留到二期（R2）。
///
/// **三形态而非多页面**：列表（搜索优先）↔ 候选（某行输入中）↔ 地图（页内
/// 切换）。地图不是默认形态，进入地图也不 push 新页面 —— 退出成本只有一次
/// 返回（R8 / KTD7）。
///
/// **失败一律降级**：定位不可用 → 起点留空（R12）；候选为空 → 列表空态；
/// 距离失败 → 隐藏距离段（R13）。三种情况都不弹错误、不阻断确认。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../../core/text/route_label.dart';
import '../../core/track/track_event.dart';
import '../../design_tokens.dart';
import '../../domain/route_pair.dart';
import '../../nfr_constants.dart';
import '../location/amap_degrade.dart';
import '../location/driving_route.dart';
import '../location/high_accuracy_locator.dart';
import '../location/location_center.dart';
import '../location/poi_search.dart';
import '../location/reverse_geocode.dart';
import '../location/route_services.dart';
import '../map/amap_init_guard.dart';
import '../privacy/privacy_consent.dart';
import '../track/track_wiring.dart';
import 'route_pair_map_mode.dart';

/// 当前聚焦的是哪一行（决定候选回填、快捷项与地图落针的目标）。
enum _RouteRow { origin, destination }

/// 起终点选择页。
class RoutePairPickerScreen extends ConsumerStatefulWidget {
  /// 构造选择页。
  ///
  /// 参数：[initial] 进入前的起终点（可空；有值时回填两行）。
  const RoutePairPickerScreen({super.key, this.initial});

  /// 进入前的起终点值（取消时原样保留在表单里，R14）。
  final RoutePair? initial;

  @override
  ConsumerState<RoutePairPickerScreen> createState() =>
      _RoutePairPickerScreenState();
}

class _RoutePairPickerScreenState
    extends ConsumerState<RoutePairPickerScreen> {
  late final TextEditingController _originCtrl;
  late final TextEditingController _destCtrl;
  final FocusNode _originFocus = FocusNode();
  final FocusNode _destFocus = FocusNode();

  /// 已选起点/终点（null = 该行尚未选定）。
  RoutePlace? _origin;
  RoutePlace? _destination;

  /// 当前聚焦行；null = 尚未聚焦（进入时键盘不自动弹起）。
  _RouteRow? _focus;

  /// 是否处于地图形态。
  bool _mapMode = false;

  /// 当前候选列表、发起该列表的行与请求序号（防抖后只接受最后一次结果）。
  ///
  /// [_suggestionRow] 是候选的归属行：用户在终点输入后立刻改点起点时，候选
  /// 仍属于终点 —— 少了它就会把终点搜出来的地点写进起点。
  List<PoiSuggestion> _suggestions = const <PoiSuggestion>[];
  _RouteRow? _suggestionRow;
  int _searchSeq = 0;
  Timer? _debounce;

  /// 驾车摘要与请求序号（换点/交换后只接受最后一次结果）。
  DrivingSummary? _distance;
  bool _distanceLoading = false;
  int _distanceSeq = 0;

  /// 进入地图态时的初始准星（形态内部自管坐标，见 route_pair_map_mode.dart）。
  LatLng _mapTarget = const LatLng(kDefaultCenterLat, kDefaultCenterLng);

  /// 本次进页的交互标识（埋点去重键成员，进页生成一次后冻结）。
  final String _interactionId = const Uuid().v4();

  /// 是否已上报过 `amap_degraded`（每次进页最多一条，见事件定义）。
  bool _degradeReported = false;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _origin = initial?.origin;
    _destination = initial?.destination;
    _originCtrl = TextEditingController(text: _origin?.name ?? '');
    _destCtrl = TextEditingController(text: _destination?.name ?? '');
    // 地图态初始中心：起点 → 终点 → 会话最优点 → 默认城市中心。
    final anchor = _origin?.isLocated == true
        ? _origin
        : (_destination?.isLocated == true ? _destination : null);
    if (anchor != null) {
      _mapTarget = LatLng(anchor.lat!, anchor.lng!);
    } else {
      final fix = ref.read(locationFixProvider);
      if (fix != null) _mapTarget = LatLng(fix.lat, fix.lng);
    }
    // 首帧后：起点为空则补一次「我的位置」（KTD8 / R3）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_origin == null) {
        unawaited(_fillWithCurrentLocation(_RouteRow.origin));
      } else {
        unawaited(_refreshDistance());
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _originCtrl.dispose();
    _destCtrl.dispose();
    _originFocus.dispose();
    _destFocus.dispose();
    super.dispose();
  }

  /// 当前是否已同意隐私协议（候选与路径请求的前置条件，KTD5）。
  bool get _consented =>
      ref.read(privacyConsentProvider) == PrivacyConsentStatus.agreed;

  /// 上报一次高德降级事件（每次进入本页最多一条）。
  ///
  /// 参数：[reason] 降级原因（不带坐标、关键词与含 Key 的 URL）。
  /// 返回：void。埋点控制器未就绪时静默跳过。
  void _reportDegrade(AmapDegradeReason reason) {
    if (_degradeReported) return;
    _degradeReported = true;
    final controller = ref.read(trackControllerProvider);
    if (controller == null) return;
    unawaited(
      controller.enqueue(
        TrackEvent(
          event: TrackEventName.amapDegraded,
          ts: DateTime.now(),
          interactionId: _interactionId,
          props: <String, Object?>{'reason': reason.wire},
        ),
      ),
    );
  }

  /// 把一次定位结果写进指定行（「我的位置」，KTD8）。
  ///
  /// 参数：[row] 目标行。
  /// 返回：Future，定位与逆地理完成（成功或失败）后结束。失败时该行留空，
  ///   不阻断页面其余交互（R12）。
  ///
  /// **未同意隐私协议时不取点**：设备定位同样属于个人信息采集，与 KTD5
  /// 「未同意不出网」同一口径；此时该行保持空态，页面已有同意提示。
  Future<void> _fillWithCurrentLocation(_RouteRow row) async {
    if (!_consented) return;
    final localized = await locateForPublish(ref);
    if (!mounted) return;
    final coordinate = localized != null
        ? (lat: localized.lat, lng: localized.lng)
        : readPublishCoordinate(ref);
    if (coordinate == null) {
      // 定位不可用：该行保持/回到空态，由占位文案「选择起点」承担提示
      //（R12）—— 不弹错误，进入页面本身不能被定位失败阻断。
      _clearRow(row);
      return;
    }

    // 逆地理只用于副文与 address；未同意隐私协议时不发这次出网（KTD5）。
    final label = _consented
        ? await reverseGeocodeLabel(
            lat: coordinate.lat,
            lng: coordinate.lng,
            onDegraded: _reportDegrade,
          )
        : '';
    if (!mounted) return;
    _setRow(
      row,
      RoutePlace(
        name: '我的位置',
        address: label,
        lng: coordinate.lng,
        lat: coordinate.lat,
      ),
    );
  }

  /// 把某一行设为给定地点并同步输入框、收起候选、重算距离。
  ///
  /// 参数：[row] 目标行；[place] 地点值。
  /// 返回：void。
  void _setRow(_RouteRow row, RoutePlace place) {
    // 已选定就作废在途候选：否则上一条关键词的结果会在选点后又弹回来。
    _debounce?.cancel();
    ++_searchSeq;
    setState(() {
      if (row == _RouteRow.origin) {
        _origin = place;
        _originCtrl.text = place.name;
      } else {
        _destination = place;
        _destCtrl.text = place.name;
      }
      _suggestions = const <PoiSuggestion>[];
      _suggestionRow = null;
      _focus = row;
    });
    unawaited(_refreshDistance());
  }

  /// 清空某一行（定位失败时回到空态）。
  ///
  /// 参数：[row] 目标行。返回：void。
  void _clearRow(_RouteRow row) {
    _debounce?.cancel();
    ++_searchSeq;
    setState(() {
      if (row == _RouteRow.origin) {
        _origin = null;
        _originCtrl.clear();
      } else {
        _destination = null;
        _destCtrl.clear();
      }
      _suggestions = const <PoiSuggestion>[];
      _suggestionRow = null;
    });
    unawaited(_refreshDistance());
  }

  /// 某行关键词变化：清掉该行已选值并按防抖搜索候选。
  ///
  /// 参数：[row] 行；[value] 当前输入。
  /// 返回：void。
  void _onKeywordChanged(_RouteRow row, String value) {
    setState(() {
      _focus = row;
      if (row == _RouteRow.origin) {
        _origin = null;
      } else {
        _destination = null;
      }
    });
    // 输入过程中不请求距离（KTD6）：两端齐备才发。
    unawaited(_refreshDistance());

    _debounce?.cancel();
    final keyword = value.trim();
    if (keyword.length < NfrLocation.poiSearchMinKeywordLength) {
      setState(() {
        _suggestions = const <PoiSuggestion>[];
        _suggestionRow = null;
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: NfrLocation.poiSearchDebounceMs),
      () => unawaited(_searchSuggestions(keyword, row)),
    );
  }

  /// 聚焦某一行：取消防抖、作废在途搜索并清空上一条候选。
  ///
  /// 参数：[row] 被聚焦或点按的行。
  /// 返回：void。候选只在发起它的那一行上有效，换行时旧候选必须一起作废，
  ///   否则点选会把另一行搜出来的地点写进这一行。
  void _focusRow(_RouteRow row) {
    _debounce?.cancel();
    ++_searchSeq;
    setState(() {
      _focus = row;
      _suggestions = const <PoiSuggestion>[];
      _suggestionRow = null;
    });
  }

  /// 按关键词请求候选（只接受最后一次请求的结果）。
  ///
  /// 参数：[keyword] 已去空白的关键词；[row] 发起这次搜索的行。
  /// 返回：Future，请求完成（成功或失败）后结束。
  Future<void> _searchSuggestions(String keyword, _RouteRow row) async {
    if (!_consented) return;
    final seq = ++_searchSeq;
    final fix = _origin?.isLocated == true ? _origin : null;
    final results = await ref.read(poiSearchFnProvider)(
      keywords: keyword,
      lng: fix?.lng,
      lat: fix?.lat,
      onDegraded: _reportDegrade,
    );
    if (!mounted || seq != _searchSeq) return;
    setState(() {
      _suggestions = results;
      _suggestionRow = row;
    });
  }

  /// 点选一条候选：回填发起该候选的行并收起列表（R6）。
  ///
  /// 参数：[suggestion] 被点选的候选。返回：void。
  void _pickSuggestion(PoiSuggestion suggestion) {
    // 回填到「发起这次搜索的行」，而不是当前焦点行（两者可能已被用户切换）。
    final row = _suggestionRow ?? _focus ?? _RouteRow.origin;
    _setRow(
      row,
      RoutePlace(
        name: suggestion.name,
        address: suggestion.address,
        lng: suggestion.lng,
        lat: suggestion.lat,
      ),
    );
  }

  /// 交换起点与终点（R4）。
  ///
  /// 返回：void。两行互换后清空旧距离并重新请求（反向路线数值不同）。
  void _swap() {
    final origin = _origin;
    final destination = _destination;
    _debounce?.cancel();
    ++_searchSeq;
    setState(() {
      _origin = destination;
      _destination = origin;
      _originCtrl.text = destination?.name ?? '';
      _destCtrl.text = origin?.name ?? '';
      _suggestions = const <PoiSuggestion>[];
      _suggestionRow = null;
      _distance = null;
    });
    unawaited(_refreshDistance());
  }

  /// 两端齐备时请求驾车里程与时长（换点、交换、进入页面都走这里，KTD6）。
  ///
  /// 返回：Future，请求完成（成功或失败）后结束。失败时 [DrivingSummary] 为
  ///   null，距离段静默隐藏（R13）。
  Future<void> _refreshDistance() async {
    final origin = _origin;
    final destination = _destination;
    final ready = origin != null &&
        destination != null &&
        origin.isLocated &&
        destination.isLocated;

    if (!ready || !_consented) {
      // 作废在途请求：否则端点在途被清空后，旧响应仍会通过序号校验写回 _distance。
      ++_distanceSeq;
      if (_distance != null || _distanceLoading) {
        setState(() {
          _distance = null;
          _distanceLoading = false;
        });
      }
      return;
    }

    final seq = ++_distanceSeq;
    setState(() {
      _distanceLoading = true;
      _distance = null;
    });
    final summary = await ref.read(drivingSummaryFnProvider)(
      originLng: origin.lng!,
      originLat: origin.lat!,
      destinationLng: destination.lng!,
      destinationLat: destination.lat!,
      onDegraded: _reportDegrade,
    );
    if (!mounted || seq != _distanceSeq) return;
    setState(() {
      _distance = summary;
      _distanceLoading = false;
    });
  }

  /// 确认选择：两端齐备时把结果回传调用方（R11）。
  ///
  /// 返回：void。
  void _confirm() {
    final origin = _origin;
    final destination = _destination;
    if (origin == null ||
        destination == null ||
        !origin.isLocated ||
        !destination.isLocated) {
      return;
    }
    Navigator.of(context).pop(
      RoutePair(
        origin: origin,
        destination: destination,
        distanceM: _distance?.distanceM,
        durationS: _distance?.durationS,
      ),
    );
  }

  /// 取消：丢弃页面内改动并退出，表单保留进入前的值（R14）。
  ///
  /// 返回：void。
  void _cancel() => Navigator.of(context).pop();

  /// 进入地图形态（目标行 = 当前聚焦行，无聚焦时为起点）。
  ///
  /// 返回：void。
  void _enterMap() {
    final row = _focus ?? _RouteRow.origin;
    final place = row == _RouteRow.origin ? _origin : _destination;
    setState(() {
      _focus = row;
      _mapMode = true;
      if (place?.isLocated == true) {
        _mapTarget = LatLng(place!.lat!, place.lng!);
      }
    });
  }

  /// 退出地图形态回到列表（不提交落针）。
  ///
  /// 返回：void。
  void _exitMap() => setState(() => _mapMode = false);

  /// 地图落针后的回填：写进当前聚焦行并回到列表（R8）。
  ///
  /// 参数：[label] 逆地理得到的地点名（可空串）；[lng]/[lat] GCJ-02 坐标。
  /// 返回：void。地址名缺失时主值退回「地图选点」，坐标仍然回填。
  void _onMapPicked(String label, double lng, double lat) {
    final row = _focus ?? _RouteRow.origin;
    _setRow(
      row,
      RoutePlace(
        name: label.isEmpty ? '地图选点' : label,
        address: label,
        lng: lng,
        lat: lat,
      ),
    );
    setState(() => _mapMode = false);
  }

  /// 主按钮是否可用（两端都已定位，R11）。
  bool get _canConfirm =>
      _origin?.isLocated == true && _destination?.isLocated == true;

  /// 还缺哪一端（可用时为空串）。
  String get _missingHint {
    if (_origin?.isLocated != true) return '还差起点';
    if (_destination?.isLocated != true) return '还差终点';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    // 合规闸门与地图页同源：未同意或未注入 Key 时不构建 AMapWidget。
    final consent = ref.watch(privacyConsentProvider);
    AMapInitGuard.applyConsent(consent);
    final mapUsable = AMapInitGuard.canRenderMap(consent) &&
        AMapInitGuard.ensureSdkInitialized(context);

    return PopScope(
      // 地图态下的系统返回只回列表，不退出整页（R14）。
      canPop: !_mapMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _mapMode) setState(() => _mapMode = false);
      },
      child: Scaffold(
        backgroundColor: const Color(AppColors.background),
        appBar: _mapMode
            ? _buildMapAppBar()
            : _buildListAppBar(consent: consent),
        body: _mapMode
            ? RoutePairMapMode(
                initialTarget: _mapTarget,
                consented: consent == PrivacyConsentStatus.agreed,
                mapUsable: mapUsable,
                targetLabel: _focus == _RouteRow.destination ? '终点' : '起点',
                onDegraded: _reportDegrade,
                onPicked: _onMapPicked,
              )
            : _buildListBody(consent: consent),
      ),
    );
  }

  /// 列表态顶部栏：取消 / 标题 / 确认。
  ///
  /// 参数：[consent] 当前隐私同意态（决定确认按钮是否可点）。
  /// 返回：AppBar。
  AppBar _buildListAppBar({required PrivacyConsentStatus consent}) {
    return AppBar(
      toolbarHeight: 48,
      backgroundColor: const Color(AppColors.surface),
      elevation: 0,
      leading: TextButton(
        onPressed: _cancel,
        child: Text(
          '取消',
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
      ),
      leadingWidth: 64,
      centerTitle: true,
      title: Text(
        '选择起终点',
        style: TextStyle(
          fontSize: AppTypeScale.h3.size,
          fontWeight: FontWeight.w600,
          color: const Color(AppColors.textPrimary),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _canConfirm ? _confirm : null,
          child: Text(
            '确认',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              fontWeight: FontWeight.w600,
              color: _canConfirm
                  ? const Color(AppColors.primary)
                  : const Color(AppColors.textPlaceholder),
            ),
          ),
        ),
      ],
    );
  }

  /// 地图态顶部栏：返回列表 / 标题 / 取消退出整页（R14）。
  ///
  /// 返回：AppBar。
  AppBar _buildMapAppBar() {
    return AppBar(
      toolbarHeight: 48,
      backgroundColor: const Color(AppColors.surface),
      elevation: 0,
      leading: TextButton(
        onPressed: _exitMap,
        child: Text(
          '返回',
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            color: const Color(AppColors.textSecondary),
          ),
        ),
      ),
      leadingWidth: 64,
      centerTitle: true,
      title: Text(
        '地图选点',
        style: TextStyle(
          fontSize: AppTypeScale.h3.size,
          fontWeight: FontWeight.w600,
          color: const Color(AppColors.textPrimary),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _cancel,
          child: Text(
            '取消',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }

  /// 列表态主体：两行卡片 → 距离/缺口提示 → 快捷项 → 候选或空态 → 告知。
  ///
  /// 参数：[consent] 当前隐私同意态。
  /// 返回：页面主体。
  Widget _buildListBody({required PrivacyConsentStatus consent}) {
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _buildPairCard(),
        const SizedBox(height: AppSpacing.sm),
        _buildStatusLine(consent: consent),
        const SizedBox(height: AppSpacing.sm),
        _buildQuickActions(),
        const SizedBox(height: AppSpacing.sm),
        if (_suggestions.isNotEmpty) _buildSuggestionList(),
        if (_suggestions.isEmpty && _focus != null) _buildEmptyState(),
        if (consent != PrivacyConsentStatus.agreed) _buildConsentHint(),
        const SizedBox(height: AppSpacing.md),
        // 🔴 PIPL 告知（R15）：起终点与地图选点页的门牌号告知同一口径。
        Text(
          '起点与终点将对所有看到这条信息的人可见',
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: const Color(AppColors.primaryDark),
          ),
        ),
      ],
    );
  }

  /// 两行卡片：起点行、终点行与中间的交换按钮（R3 / R4）。
  ///
  /// 返回：卡片控件。
  Widget _buildPairCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              _buildRow(
                label: '起点',
                row: _RouteRow.origin,
                place: _origin,
                controller: _originCtrl,
                focusNode: _originFocus,
                hint: '选择起点',
              ),
              const Divider(height: 1, color: Color(AppColors.border)),
              _buildRow(
                label: '终点',
                row: _RouteRow.destination,
                place: _destination,
                controller: _destCtrl,
                focusNode: _destFocus,
                hint: '输入关键词搜索终点',
              ),
            ],
          ),
          Positioned(
            right: AppSpacing.xs,
            top: 0,
            bottom: 0,
            child: Center(
              child: IconButton(
                onPressed: _swap,
                tooltip: '交换起终点',
                icon: const Icon(Icons.swap_vert, size: 20),
                color: const Color(AppColors.primary),
                // IconButton 默认 48×48，满足热区 ≥44 的要求。
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 单行（起点或终点）：标签 + 可输入的主值 + 地址副文。
  ///
  /// 参数：[label] 行标签；[row] 行标识；[place] 已选地点（可空）；
  /// [controller] 输入控制器；[focusNode] 焦点节点；[hint] 占位文案。
  /// 返回：行控件。
  Widget _buildRow({
    required String label,
    required _RouteRow row,
    required RoutePlace? place,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String hint,
  }) {
    return Semantics(
      label: label,
      container: true,
      child: InkWell(
        onTap: () => focusNode.requestFocus(),
        child: Padding(
          // 右侧留出交换按钮的宽度，避免长地名压在按钮下。
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.sm,
            AppSpacing.xl + AppSpacing.md,
            AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: 2),
              TextField(
                controller: controller,
                focusNode: focusNode,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: const Color(AppColors.textPrimary),
                ),
                decoration: InputDecoration.collapsed(
                  hintText: hint,
                  hintStyle: const TextStyle(
                    color: Color(AppColors.textPlaceholder),
                  ),
                ),
                onTap: () => _focusRow(row),
                onChanged: (value) => _onKeywordChanged(row, value),
              ),
              if (place != null && place.address.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    place.address,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 距离行 / 缺口提示行（固定高度，避免加载与失败之间跳动，KTD6）。
  ///
  /// 参数：[consent] 当前隐私同意态。
  /// 返回：状态行控件。
  Widget _buildStatusLine({required PrivacyConsentStatus consent}) {
    final bothLocated = _canConfirm;
    final String text;
    if (bothLocated) {
      if (_distanceLoading) {
        text = '计算中…';
      } else if (_distance != null) {
        // 与详情页共用同一份取整规则（route_label.dart），不在此手拼。
        text = routeDistanceText(
          _distance!.distanceM,
          _distance!.durationS,
        );
      } else {
        // 距离失败：整段隐藏（R13），但保持行高不让版面跳动。
        text = '';
      }
    } else if (consent != PrivacyConsentStatus.agreed) {
      text = '';
    } else {
      text = _missingHint;
    }

    return SizedBox(
      height: 20,
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTypeScale.small.size,
          color: bothLocated && _distance != null
              ? const Color(AppColors.primaryDark)
              : const Color(AppColors.textSecondary),
        ),
      ),
    );
  }

  /// 快捷项：我的位置 / 地图选点（R5，作用于当前聚焦行）。
  ///
  /// 返回：快捷项行控件。
  Widget _buildQuickActions() {
    return Row(
      children: [
        _quickAction(
          icon: Icons.my_location,
          label: '我的位置',
          onTap: () => unawaited(
            _fillWithCurrentLocation(_focus ?? _RouteRow.origin),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _quickAction(
          icon: Icons.map_outlined,
          label: '地图选点',
          onTap: _enterMap,
        ),
      ],
    );
  }

  /// 单个快捷项胶囊（热区 ≥44）。
  ///
  /// 参数：[icon] 图标；[label] 文案；[onTap] 回调。
  /// 返回：胶囊控件。
  Widget _quickAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: TextStyle(fontSize: AppTypeScale.small.size)),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: Color(AppColors.primary)),
        foregroundColor: const Color(AppColors.primary),
        shape: const StadiumBorder(),
      ),
    );
  }

  /// POI 候选列表（R6）。
  ///
  /// 返回：候选列表控件。
  Widget _buildSuggestionList() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        children: [
          for (final suggestion in _suggestions)
            ListTile(
              dense: true,
              leading: const Icon(
                Icons.place_outlined,
                size: 18,
                color: Color(AppColors.textSecondary),
              ),
              title: Text(
                suggestion.name,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
              subtitle: suggestion.address.isEmpty
                  ? null
                  : Text(
                      suggestion.address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: AppTypeScale.caption.size,
                        color: const Color(AppColors.textSecondary),
                      ),
                    ),
              onTap: () => _pickSuggestion(suggestion),
            ),
        ],
      ),
    );
  }

  /// 候选为空时的空态引导（未选齐时提示先搜终点，选齐后确认已定位）。
  ///
  /// 返回：空态文案控件。
  Widget _buildEmptyState() {
    final text = _canConfirm
        ? '起终点都已定位，可以确认返回'
        : '输入关键词搜索，或直接在地图上选点';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTypeScale.small.size,
          color: const Color(AppColors.textSecondary),
        ),
      ),
    );
  }

  /// 未同意隐私协议时的降级提示（候选与距离都不出网，KTD5）。
  ///
  /// 返回：提示控件。
  Widget _buildConsentHint() {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Text(
        '未同意隐私协议，候选与距离暂不可用；仍可手动输入或在地图上选点',
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          color: const Color(AppColors.textSecondary),
        ),
      ),
    );
  }
}
