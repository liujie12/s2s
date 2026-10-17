/// 定位中心点（PRD §6.4.1 / §6.7）。
///
/// 首页地图与列表的「距离」统一以此中心为基准（2 处基准点：list_screen
/// 距离显示 / map_screen 视口中心）。定位接入前（[132] 之前）各处硬编码默认
/// 中心；接入后统一读 [locationCenterProvider]，中心点只有一个来源，避免漂移。
///
/// 中心点默认取杭州（[kDefaultCenterLat]/[kDefaultCenterLng]），在定位成功取点
/// 或用户手动选城市后被替换。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 默认地图中心（杭州市中心附近，GCJ-02）。
///
/// 定位权限尚未取得或取点失败时的兜底中心 —— 避免地图开在 (0,0) 的几内亚湾。
/// 与 PRD §6.4.4「基站+商圈兜底（非城市中心假值）」口径一致：这里给出的是
/// 一个确定、可解释的默认城市中心，而非伪造的用户位置。
const double kDefaultCenterLat = 30.2741;
const double kDefaultCenterLng = 120.1551;

/// 地图/列表的距离基准中心点（GCJ-02）。
///
/// 不可变值对象：Riverpod 靠引用相等判断变化，字段可变会让「改中心点但 UI
/// 不刷新」。
class LocationCenter {
  const LocationCenter({required this.lat, required this.lng});

  /// 纬度（GCJ-02）。
  final double lat;

  /// 经度（GCJ-02）。
  final double lng;
}

/// 中心点读写入口。
class LocationCenterNotifier extends Notifier<LocationCenter> {
  @override
  LocationCenter build() =>
      const LocationCenter(lat: kDefaultCenterLat, lng: kDefaultCenterLng);

  /// 把中心点移动到新坐标（定位成功取点或手动选城市后调用）。
  ///
  /// 参数：
  ///   [lat] 纬度（GCJ-02）；
  ///   [lng] 经度（GCJ-02）。
  void moveTo(double lat, double lng) {
    state = LocationCenter(lat: lat, lng: lng);
  }
}

/// 地图/列表共享的基准中心点 Provider。
final locationCenterProvider =
    NotifierProvider<LocationCenterNotifier, LocationCenter>(
      LocationCenterNotifier.new,
    );

/// 本次会话「最优定位点」（发布坐标来源）。
///
/// 为什么与 [locationCenterProvider] 分开：共享中心被 2026-10-08 裁定冻结在
/// **首个有效点**（只居中一次，避免相机被反复拽回），首点常是网络/AGPS 粗定位
/// （30–100m）。若发布直接取它，同一地点在不同会话会落到不同位置，看起来「定位
/// 不准」。本 Provider 持续跟踪**精度最好**的一次有效定位，供发布取点使用，
/// 不参与相机跟随。
class LocationFix {
  const LocationFix({
    required this.lat,
    required this.lng,
    required this.accuracy,
  });

  /// 纬度（GCJ-02）。
  final double lat;

  /// 经度（GCJ-02）。
  final double lng;

  /// 水平精度（米，越小越好）。
  final double accuracy;
}

/// 最优定位点读写入口。
class LocationFixNotifier extends Notifier<LocationFix?> {
  @override
  LocationFix? build() => null;

  /// 记录一次有效定位；仅当精度优于当前最优时才替换。
  ///
  /// 参数：
  /// [lat] 纬度（GCJ-02）；
  /// [lng] 经度（GCJ-02）；
  /// [accuracy] 水平精度（米）。无效定位（见 [isUsableLocationFix]）直接忽略。
  void update({
    required double lat,
    required double lng,
    required double accuracy,
  }) {
    if (!isUsableLocationFix(lat: lat, lng: lng, accuracy: accuracy)) return;
    final current = state;
    if (current == null || accuracy < current.accuracy) {
      state = LocationFix(lat: lat, lng: lng, accuracy: accuracy);
    }
  }
}

/// 本次会话最优定位点 Provider（无有效定位时为 null）。
final locationFixProvider = NotifierProvider<LocationFixNotifier, LocationFix?>(
  LocationFixNotifier.new,
);

/// 取发布用坐标（GCJ-02）：本次会话最优定位点。
///
/// 参数：[ref] 组件引用（发布页 / AI 确认页 / AI 问答页共用）。
/// 返回：含 [lat]/[lng] 的记录；**尚未取到有效定位时返回 null** —— 调用方不得
/// 退化到共享中心，因为那可能是默认城市中心（杭州），不是用户真实位置。
({double lat, double lng})? readPublishCoordinate(WidgetRef ref) {
  final fix = ref.read(locationFixProvider);
  if (fix == null) return null;
  return (lat: fix.lat, lng: fix.lng);
}

/// 判定高德回传的一次定位是否可用（PRD §6.8）。
///
/// **不能用插件 `amap_map` 的 `isLocationValid`**：它的判据只有「经纬度在范围内 +
/// `accuracy >= 0`」，于是定位不可用时回传的 `(0, 0)` 会被判为**有效**。2026-10-08
/// 真机实测的连锁后果：
/// 1. `_located` 被置真 → 取点前骨架屏提前消失；
/// 2. 按「仅首点居中一次」把相机移到 `(0, 0)`（几内亚湾，无瓦片）→ **地图整片空白**；
/// 3. 首点只认一次 ⇒ 后续真实定位**不会**纠正 → 空白不自愈（只能重启 App）；
/// 4. 失败计数不累积 ⇒ **C 态降级永不触发**，与 PRD §6.8「≥3 次失败 → 基站+商圈兜底，
///    不用城市中心假值」且「全程不留空白页」直接冲突。
///
/// 参数：
/// - [lat]：纬度（GCJ-02）；
/// - [lng]：经度（GCJ-02）；
/// - [accuracy]：水平精度（米）。高德以 0 表示「未测到精度」，同样按无效计。
///
/// 返回：true 表示坐标可信，可用于「取点成功」判定与居中。
bool isUsableLocationFix({
  required double lat,
  required double lng,
  required double accuracy,
}) {
  // 零坐标：高德在定位不可用时回传 (0,0)，落点是几内亚湾，不是任何用户的真实位置。
  if (lat == 0 && lng == 0) return false;
  // 零精度：没有真实测距结果，不能据此认定「取点成功」。
  if (accuracy <= 0) return false;
  // 经纬度范围与插件判据保持一致，避免坐标系错乱的脏数据被当成有效点。
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return false;
  return true;
}
