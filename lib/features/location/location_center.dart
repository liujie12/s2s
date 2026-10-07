/// 定位中心点（PRD §6.4.1 / §6.7）。
///
/// 首页地图与列表的「距离」统一以此中心为基准（4 处基准点：listing_repository
/// 距离过滤 / listing_sort 排序 / list_screen 距离显示 / map_screen 视口中心）。
/// 定位接入前（[132] 之前）这 4 处各自硬编码默认中心；接入后统一读
/// [locationCenterProvider]，中心点只有一个来源，避免四处漂移。
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
