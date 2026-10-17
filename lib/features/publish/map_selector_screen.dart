/// 地图选点页（PRD §5.4.1 / §7.9 / §10.1 `map-selector`）。
///
/// **交互口径**：地图中心固定一枚准星，**拖动地图 = 移动选点**（与发布页提示
/// 「拖图微调」一致）；点按地图也会把准星移过去。确认后把 GCJ-02 坐标回传发布页。
///
/// **为什么不做逆地理编码**：本期没有可用的门牌级逆地理服务，`address` 也不上送
/// （见 `publish_form_state.dart` 的 `postDraftPayload` 注释）。因此门牌号按
/// PRD §9.8 的兜底口径「允许手填自由文本」提供输入框，并在页内给出 PIPL 要求的
/// 告知语「门牌号将对所有看到这条信息的人可见」（安全方案 §642）。
library;

import 'package:amap_map/amap_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:x_amap_base/x_amap_base.dart';

import '../../design_tokens.dart';
import '../location/location_center.dart';
import '../location/location_permission.dart';
import '../location/reverse_geocode.dart';
import '../map/amap_init_guard.dart';
import '../privacy/privacy_consent.dart';

/// 打开地图选点页的入参。
class MapSelectorArgs {
  const MapSelectorArgs({this.lat, this.lng, this.doorNumber = ''});

  /// 已选位置纬度（GCJ-02）；null 表示尚未选点。
  final double? lat;

  /// 已选位置经度（GCJ-02）；null 表示尚未选点。
  final double? lng;

  /// 已填门牌号（回填输入框）。
  final String doorNumber;
}

/// 地图选点结果。
class MapPickResult {
  const MapPickResult({
    required this.lat,
    required this.lng,
    required this.doorNumber,
    this.address = '',
  });

  /// 选点纬度（GCJ-02）。
  final double lat;

  /// 选点经度（GCJ-02）。
  final double lng;

  /// 门牌号（可空串，§9.8「位置到门牌号」）。
  final String doorNumber;

  /// 逆地理得到的地址文案（可能为空：系统逆地理不可用）。
  final String address;
}

/// 选点页缩放级别：门牌级微调，过大看不到参照物、过小对不准楼栋。
const double _kPickerZoom = 17;

/// 地图选点页（全屏模态）。
class MapSelectorScreen extends ConsumerStatefulWidget {
  const MapSelectorScreen({super.key, this.initialLat, this.initialLng, this.initialDoorNumber = ''});

  /// 打开时的初始纬度（GCJ-02），null 时退回会话最优点/默认中心。
  final double? initialLat;

  /// 打开时的初始经度（GCJ-02）。
  final double? initialLng;

  /// 打开时回填的门牌号。
  final String initialDoorNumber;

  @override
  ConsumerState<MapSelectorScreen> createState() => _MapSelectorScreenState();
}

class _MapSelectorScreenState extends ConsumerState<MapSelectorScreen> {
  /// 当前选点（准星所在位置，GCJ-02）。
  late LatLng _selected;

  /// 门牌号输入控制器。
  late final TextEditingController _doorCtrl;

  /// 原生地图控制器（点按地图时移动相机用）。
  AMapController? _controller;

  /// 逆地理得到的地址文案（空串 = 尚未取到/不可用）。
  String _addressLabel = '';

  /// 是否正在逆地理（用于展示「正在获取位置信息…」）。
  bool _resolvingAddress = false;

  /// 逆地理请求序号：拖动地图会连续触发，只接受最后一次的结果。
  int _addressSeq = 0;

  @override
  void initState() {
    super.initState();
    _doorCtrl = TextEditingController(text: widget.initialDoorNumber);
    _selected = _initialTarget();
    // 首帧后取一次地址，让用户一进来就能核对该点是否正确。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshAddress());
  }

  /// 计算初始准星位置：入参坐标 → 会话最优点 → 默认城市中心。
  ///
  /// 参数：无。
  ///
  /// 返回：初始选点坐标（GCJ-02）。
  LatLng _initialTarget() {
    if (widget.initialLat != null && widget.initialLng != null) {
      return LatLng(widget.initialLat!, widget.initialLng!);
    }
    final fix = ref.read(locationFixProvider);
    if (fix != null) return LatLng(fix.lat, fix.lng);
    return const LatLng(kDefaultCenterLat, kDefaultCenterLng);
  }

  @override
  void dispose() {
    _doorCtrl.dispose();
    super.dispose();
  }

  /// 确认选点并把结果回传发布页。
  ///
  /// 参数：无。
  ///
  /// 返回：void（通过 [GoRouter.pop] 回传 [MapPickResult]）。
  void _confirm() {
    context.pop(
      MapPickResult(
        lat: _selected.latitude,
        lng: _selected.longitude,
        doorNumber: _doorCtrl.text.trim(),
        address: _addressLabel,
      ),
    );
  }

  /// 对当前准星位置做一次逆地理，更新展示用地址文案。
  ///
  /// 参数：无。
  ///
  /// 返回：Future，逆地理完成（成功或失败）后结束。
  ///
  /// 用系统 `Geocoder` 而非高德 Web 服务：客户端没有 Web 服务 Key，
  /// 且拖图时的高频调用走系统服务不占出网配额。
  Future<void> _refreshAddress() async {
    final seq = ++_addressSeq;
    setState(() => _resolvingAddress = true);
    final label = await reverseGeocodeLabel(
      lat: _selected.latitude,
      lng: _selected.longitude,
    );
    // 拖动会连续触发；只接受最后一次请求的结果，避免地址与准星错位。
    if (!mounted || seq != _addressSeq) return;
    setState(() {
      _addressLabel = label;
      _resolvingAddress = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    // 与地图页同一合规闸门：构建 AMapWidget 即触发原生 SDK 初始化，
    // 故未同意隐私协议时必须走降级分支（见 amap_init_guard.dart 头注）。
    final consent = ref.watch(privacyConsentProvider);
    AMapInitGuard.applyConsent(consent);
    final useRealMap =
        AMapInitGuard.canRenderMap(consent) &&
        AMapInitGuard.ensureSdkInitialized(context);
    final locationGranted =
        ref.watch(locationPermissionProvider) == LocationPermissionPhase.granted;

    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: const Color(AppColors.surface),
        elevation: 0,
        leading: TextButton(
          onPressed: () => context.pop(),
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
          '选择位置',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          TextButton(
            // 没有真地图时坐标未经用户确认，不允许直接回传。
            onPressed: useRealMap ? _confirm : null,
            child: Text(
              '确认',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                fontWeight: FontWeight.w600,
                color: useRealMap
                    ? const Color(AppColors.primary)
                    : const Color(AppColors.textPlaceholder),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (useRealMap)
                  AMapWidget(
                    initialCameraPosition: CameraPosition(
                      target: _selected,
                      zoom: _kPickerZoom,
                    ),
                    // 蓝点只在已授权时启用；未授权时开启会让地图等一个永不到来的定位。
                    myLocationStyleOptions: MyLocationStyleOptions(
                      locationGranted,
                    ),
                    onMapCreated: (controller) => _controller = controller,
                    // 拖图/缩放结束后，准星位置以相机中心为准。
                    onCameraMoveEnd: (camera) {
                      setState(() => _selected = camera.target);
                      _refreshAddress();
                    },
                    // 点按地图：把准星移过去，省一次手动拖动。
                    onTap: (target) {
                      setState(() => _selected = target);
                      _controller?.moveCamera(CameraUpdate.newLatLng(target));
                      _refreshAddress();
                    },
                    compassEnabled: false,
                    scaleEnabled: true,
                  )
                else
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        consent == PrivacyConsentStatus.agreed
                            ? '高德地图 Key 未配置，地图选点不可用'
                            : '请先同意隐私协议后再使用地图选点',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          color: const Color(AppColors.textSecondary),
                        ),
                      ),
                    ),
                  ),
                // 中心准星：图标底尖对准屏幕中心，即相机 target。
                if (useRealMap)
                  IgnorePointer(
                    child: Align(
                      alignment: Alignment.center,
                      child: Transform.translate(
                        offset: const Offset(0, -18),
                        child: Icon(
                          Icons.place,
                          size: 40,
                          color: const Color(AppColors.primary),
                          shadows: const [
                            Shadow(color: Colors.black26, blurRadius: 4),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _buildBottomPanel(useRealMap: useRealMap),
        ],
      ),
    );
  }

  /// 底部信息面板：门牌号输入 + 位置告知 + 操作提示。
  ///
  /// 参数：
  /// - [useRealMap]：是否可回传选点（false 时提示地图不可用）。
  ///
  /// 返回：面板控件。
  Widget _buildBottomPanel({required bool useRealMap}) {
    return Container(
      width: double.infinity,
      color: const Color(AppColors.surface),
      padding: EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            useRealMap ? '拖动地图，把准星对准你要发布的位置' : '地图不可用，暂时无法选点',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          if (useRealMap) ...[
            const SizedBox(height: AppSpacing.xs),
            // 位置名称是用户核对「选得对不对」的唯一依据，必须显式展示；
            // 逆地理不可用时明确说明原因，而不是留一行空白。
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.location_on_outlined,
                  size: 18,
                  color: Color(AppColors.primary),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    _resolvingAddress
                        ? '正在获取位置信息…'
                        : (_addressLabel.isEmpty
                              ? '暂时无法获取位置名称，可填写门牌号'
                              : _addressLabel),
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                      color: _addressLabel.isEmpty && !_resolvingAddress
                          ? const Color(AppColors.textSecondary)
                          : const Color(AppColors.textPrimary),
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _doorCtrl,
            decoration: InputDecoration(
              hintText: '门牌号（选填，如 3 号楼 2 单元 501）',
              hintStyle: const TextStyle(
                color: Color(AppColors.textPlaceholder),
              ),
              filled: true,
              fillColor: const Color(AppColors.background),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: const BorderSide(color: Color(AppColors.border)),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          // 🔴 PIPL 告知：安全方案 §642 要求地图选点页显式告知门牌号公开可见。
          Text(
            '门牌号将对所有看到这条信息的人可见',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.primaryDark),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '可见范围默认 5km',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
