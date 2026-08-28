/// 经纬度 ↔ 屏幕像素的投影（PRD §6.7 聚合在屏幕像素网格上做，故必须有这一层）。
///
/// 为什么自己写而不等高德 SDK 的 `AMapController.toScreenLocation`：
/// ① 该方法是异步的（走 platform channel），而聚合要在每帧布局时同步算出坐标，
///    异步返回会让 Pin 晚一帧、拖动时明显拖影；
/// ② Key 到手前地图走降级底图（PRD:1207），此时根本没有 SDK 可问。
///
/// 精度取舍：在 10km 尺度内用等距圆柱投影（纬度方向等比、经度方向乘 cos(lat)）
/// 而非严格墨卡托。两者在该尺度下的差异远小于 1 像素，而等距投影可逆且无极点奇异。
library;

import 'dart:math' as math;

/// 赤道处每度纬度对应的米数。
const double _metersPerDegreeLat = 111320;

/// 一个视口的投影参数。
///
/// 不可变：投影参数一旦随手可改，就会出现「算 Pin 用的是旧中心、画底图用的是新中心」
/// 这种半帧错位。每次相机变化重建一个新实例。
class MapProjection {
  const MapProjection({
    required this.centerLat,
    required this.centerLng,
    required this.metersPerPixel,
    required this.viewportSize,
  });

  /// 视口中心纬度（GCJ-02）。
  final double centerLat;

  /// 视口中心经度（GCJ-02）。
  final double centerLng;

  /// 缩放比例：一个逻辑像素代表多少米。值越大看得越远。
  final double metersPerPixel;

  /// 视口尺寸（逻辑像素），用于把中心偏移换算成左上角原点坐标。
  final ({double width, double height}) viewportSize;

  /// 经纬度转视口内像素坐标（原点在视口左上角，y 向下）。
  ///
  /// 返回值可能落在视口之外（负值或超出宽高），调用方须自行裁剪 ——
  /// 这里不裁剪是因为聚合需要视口外一圈的点参与，否则边缘簇会在拖动时突然变数字。
  ({double x, double y}) toPixel(double lat, double lng) {
    final double dLatMeters = (lat - centerLat) * _metersPerDegreeLat;
    // 经度方向的实际距离随纬度收窄，须乘 cos(纬度)。漏乘会让东西向距离在
    // 高纬度被高估（北京约高估 25%），表现为 Pin 整体横向拉伸。
    final double dLngMeters =
        (lng - centerLng) *
        _metersPerDegreeLat *
        math.cos(centerLat * math.pi / 180);

    return (
      x: viewportSize.width / 2 + dLngMeters / metersPerPixel,
      // 屏幕 y 轴向下、纬度向北为正，故取负号。
      y: viewportSize.height / 2 - dLatMeters / metersPerPixel,
    );
  }

  /// 按 [metersPerPixel] 换算出的比例尺文案（如「500m」），供底图右下角标注。
  ///
  /// 取一个接近 60 像素宽的「整齐」距离档位 —— 比例尺标的若是 137m 这种数字，
  /// 用户无法用它做心算估距，等于没标。
  ({double pixels, String label}) scaleBar() {
    const List<double> niceMeters = [
      50,
      100,
      200,
      500,
      1000,
      2000,
      5000,
      10000,
    ];
    const double targetPixels = 60;
    final double rawMeters = targetPixels * metersPerPixel;
    final double picked = niceMeters.firstWhere(
      (m) => m >= rawMeters,
      orElse: () => niceMeters.last,
    );
    return (
      pixels: picked / metersPerPixel,
      label: picked >= 1000
          ? '${(picked / 1000).toStringAsFixed(0)}km'
          : '${picked.toStringAsFixed(0)}m',
    );
  }

  /// 值相等。
  ///
  /// 必需而非锦上添花：`CustomPainter.shouldRepaint` 与 Riverpod 的状态比较
  /// 都靠 `==` 判断「变没变」。用默认的引用相等，每次重建都会得到新实例，
  /// 于是每帧全量重绘底图 —— 在低端机上这正是掉帧的来源。
  @override
  bool operator ==(Object other) =>
      other is MapProjection &&
      other.centerLat == centerLat &&
      other.centerLng == centerLng &&
      other.metersPerPixel == metersPerPixel &&
      other.viewportSize == viewportSize;

  @override
  int get hashCode =>
      Object.hash(centerLat, centerLng, metersPerPixel, viewportSize);
}
