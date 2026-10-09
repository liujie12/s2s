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

/// Web 墨卡托在 zoom=0 时赤道处的地面分辨率（米/像素）。
///
/// 高德底图走的是 Web 墨卡托瓦片体系（256px 瓦片、zoom 0 全球一张），故该常数可直接
/// 用于高德 zoom：`米/像素 = 该常数 × cos(纬度) / 2^zoom`。
/// 接入真地图时这层换算是必需的：地图页的状态量是 `metersPerPixel`，而相机回传的是
/// `zoom`，不换算两者就会各说各话（表现为 Pin 与底图随缩放逐渐错位）。
const double _metersPerPixelAtZoom0 = 156543.03392;

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

  /// 高德相机 zoom 的可用下限。
  static const double minZoom = 3;

  /// 高德相机 zoom 的可用上限。
  static const double maxZoom = 20;

  /// 高德 zoom（可为小数）→ 该纬度下的地面分辨率（米/像素）。
  ///
  /// 参数：
  /// - [lat]：纬度（GCJ-02）。地面分辨率随纬度收窄，故必须带上。
  /// - [zoom]：高德相机 zoom。
  ///
  /// 返回：该纬度、该 zoom 下 1 逻辑像素代表的米数。
  static double metersPerPixelForZoom(double lat, double zoom) =>
      _metersPerPixelAtZoom0 *
      math.cos(lat * math.pi / 180) /
      math.pow(2, zoom).toDouble();

  /// 地面分辨率（米/像素）→ 高德 zoom，即上式逆运算。
  ///
  /// 参数：
  /// - [lat]：纬度（GCJ-02）。
  /// - [metersPerPixel]：1 逻辑像素代表的米数，须为正。
  ///
  /// 返回：高德相机 zoom，夹在 [minZoom, maxZoom] 内。
  static double zoomForMetersPerPixel(double lat, double metersPerPixel) {
    final double raw =
        math.log(
          _metersPerPixelAtZoom0 * math.cos(lat * math.pi / 180) /
              metersPerPixel,
        ) /
        math.ln2;
    return raw.clamp(minZoom, maxZoom);
  }

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

  /// 纯拖动时，把本投影下算好的像素坐标平移到 [next] 视口所需的位移。
  ///
  /// **数学依据**：见 [toPixel] 的公式 —— 纬度分量 `(lat − centerLat) × 常数`，
  /// 经度分量 `(lng − centerLng) × 常数`，都是**中心的一阶线性项**。故中心变化时，
  /// 每个点的像素位移是**同一个常量**，整层 Marker 只需平移，不必逐点重算。
  /// 这正是「拖动中降级渲染」的立足点（一次性探针曾实测：复用后每帧 paint 调用
  /// 由 30 次降到 1 次；探针已删，结论见说明文档进度记录）。
  ///
  /// ⚠️ **只在 [metersPerPixel] 相同时成立**：缩放会改变像素尺度，平移无法表达，
  /// 调用方必须改为重算。此约束由 assert 兜住，避免误用后 Pin 与底图错位。
  ///
  /// 经度方向用**本投影**的 `cos(centerLat)` 冻结换算：南北向拖动会让该值微变，
  /// 但一屏位移（约 5km）内的相对误差约 4×10⁻⁴，折到屏边缘不足 1 像素，且下次
  /// 精算即归零，故不值得为此逐点重算。
  ///
  /// 参数：[next] 变化后的投影。
  /// 返回：位移 `(dx, dy)`，加到本投影下的像素坐标上即得 [next] 视口下的坐标。
  ({double dx, double dy}) panDeltaTo(MapProjection next) {
    assert(
      metersPerPixel == next.metersPerPixel,
      '缩放变化时像素尺度也变，不能用平移近似，调用方应重算 Marker',
    );
    final double kLng = _metersPerDegreeLat * math.cos(centerLat * math.pi / 180);
    return (
      dx: (centerLng - next.centerLng) * kLng / metersPerPixel,
      // 屏幕 y 轴向下、纬度向北为正，故与 x 反向（同 [toPixel] 的取负）。
      dy: (next.centerLat - centerLat) * _metersPerDegreeLat / metersPerPixel,
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
