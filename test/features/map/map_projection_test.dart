/// 高德 zoom ↔ 地面分辨率（米/像素）换算测试。
///
/// 为什么这条换算必须锁：地图页的状态量是 `metersPerPixel`（降级底图自绘路网、
/// Pin 投影都用它），而高德相机回传的是 `zoom`。接入真地图后两者每帧互转，
/// 换算错了不会报错，只会表现为「Pin 与底图随缩放逐渐错位」—— 肉眼要放大到
/// 一定程度才发现，且极易被误判成聚合精度问题。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/map/map_projection.dart';

void main() {
  /// 上海人民广场附近纬度，与地图页默认中心同量级。
  const double kLat = 31.2304;

  test('zoom 3 / 20 是插件允许的边界（MinMaxZoomPreference 会夹到这一区间）', () {
    expect(MapProjection.minZoom, 3);
    expect(MapProjection.maxZoom, 20);
  });

  test('zoom 0 且赤道处：分辨率为 Web 墨卡托常数本身', () {
    expect(
      MapProjection.metersPerPixelForZoom(0, 0),
      closeTo(156543.03392, 1e-6),
    );
  });

  test('分辨率随纬度收窄：cos(纬度) 因子未漏乘', () {
    final double atEquator = MapProjection.metersPerPixelForZoom(0, 12);
    final double atLat = MapProjection.metersPerPixelForZoom(kLat, 12);

    expect(atLat, lessThan(atEquator), reason: '高纬度的地面分辨率应更小');
    expect(
      atLat,
      closeTo(atEquator * math.cos(kLat * math.pi / 180), 1e-9),
      reason: '收窄比例必须正好是 cos(纬度)',
    );
  });

  test('zoom 每 +1，分辨率减半', () {
    final double z12 = MapProjection.metersPerPixelForZoom(kLat, 12);
    final double z13 = MapProjection.metersPerPixelForZoom(kLat, 13);

    expect(z13, closeTo(z12 / 2, 1e-9));
  });

  test('往返一致：米/像素 → zoom → 米/像素 回到原值', () {
    // 覆盖地图页可用的整段范围（默认 12，上下限 1 / 200）及其内部取值。
    for (final double mpp in <double>[1, 4, 12, 50, 200]) {
      final double zoom = MapProjection.zoomForMetersPerPixel(kLat, mpp);
      expect(
        MapProjection.metersPerPixelForZoom(kLat, zoom),
        closeTo(mpp, 1e-6),
        reason: 'mpp=$mpp 往返后应回到原值（zoom=$zoom）',
      );
    }
  });

  test('默认初始缩放落在可用的 zoom 区间内（不是越界后被夹平）', () {
    // 12 m/px 是地图页的初始值；若它对应的 zoom 越界，初始视野会被夹到边界，
    // 表现为「一进首页就贴着最近/最远档」。
    final double zoom = MapProjection.zoomForMetersPerPixel(kLat, 12);

    expect(zoom, greaterThan(MapProjection.minZoom));
    expect(zoom, lessThan(MapProjection.maxZoom));
  });

  test('越界的分辨率被夹到 [3, 20]，不会抛出也不会返回非法 zoom', () {
    expect(MapProjection.zoomForMetersPerPixel(kLat, 1e-6), 20);
    expect(MapProjection.zoomForMetersPerPixel(kLat, 1e9), 3);
  });

  /// 与地图页一致的屏幕视口（逻辑像素）。
  const ({double width, double height}) kViewport = (width: 390, height: 780);

  test('同一投影之间位移为零', () {
    const MapProjection p = MapProjection(
      centerLat: kLat,
      centerLng: 121.4737,
      metersPerPixel: 12,
      viewportSize: kViewport,
    );
    final d = p.panDeltaTo(p);
    expect(d.dx, 0);
    expect(d.dy, 0);
  });

  test('纯拖动时「平移 ≡ 重算」：拖动中降级渲染的立足点', () {
    // 精算视口比屏幕每边大一圈余量（NfrPerf.pinDragMarginViewports = 0.5）。
    const MapProjection rendered = MapProjection(
      centerLat: kLat,
      centerLng: 121.4737,
      metersPerPixel: 12,
      viewportSize: (width: 780, height: 1560),
    );
    // 相机向东北各平移约半屏：经度按 cos(纬度) 折算，否则东西向会有系统性偏差。
    const double dLatMeters = 4000;
    const double dLngMeters = 3000;
    final MapProjection current = MapProjection(
      centerLat: kLat + dLatMeters / 111320,
      centerLng:
          121.4737 +
          dLngMeters / (111320 * math.cos(kLat * math.pi / 180)),
      metersPerPixel: 12,
      viewportSize: kViewport,
    );

    final d = rendered.panDeltaTo(current);

    // 精算视口的原点与屏幕原点相差一个「余量」：`panDeltaTo` 只算相机变化带来的
    // 位移，视口尺寸差异要另外补。精算层坐标 + (d − margin) 才是屏幕坐标 ——
    // 这正是 `_markerLayerFrame` 返回的 offset，漏补这一项 Pin 会整体偏半个余量。
    final double marginX =
        (rendered.viewportSize.width - current.viewportSize.width) / 2;
    final double marginY =
        (rendered.viewportSize.height - current.viewportSize.height) / 2;
    final double offsetX = d.dx - marginX;
    final double offsetY = d.dy - marginY;

    // 取精算视口的四角与中心做样本：这是位移误差可能最大的位置。
    for (final ({double lat, double lng}) sample in [
      (lat: kLat, lng: 121.4737),
      (
        lat: kLat + 4000 / 111320,
        lng: 121.4737 + 3000 / (111320 * math.cos(kLat * math.pi / 180)),
      ),
      (lat: kLat - 4000 / 111320, lng: 121.4737),
      (
        lat: kLat,
        lng: 121.4737 - 3000 / (111320 * math.cos(kLat * math.pi / 180)),
      ),
    ]) {
      final a = rendered.toPixel(sample.lat, sample.lng);
      final b = current.toPixel(sample.lat, sample.lng);
      // y 分量是严格常量位移，应当精确相等。
      expect(a.y + offsetY, closeTo(b.y, 1e-9));
      // x 分量冻结了精算时的 cos(纬度)，南北向拖动会有微漂。按最坏情况
      // （点位于精算视口边缘、约 390px 处）估算应远小于 1 像素 ——
      // 这正是 panDeltaTo 文档承诺的界；超了说明冻结策略需要改。
      expect(a.x + offsetX, closeTo(b.x, 0.5));
    }
  });

  test('缩放变化时禁用平移近似：误用会被 assert 拦下', () {
    const MapProjection p = MapProjection(
      centerLat: kLat,
      centerLng: 121.4737,
      metersPerPixel: 12,
      viewportSize: kViewport,
    );
    const MapProjection zoomed = MapProjection(
      centerLat: kLat,
      centerLng: 121.4737,
      metersPerPixel: 6,
      viewportSize: kViewport,
    );
    expect(() => p.panDeltaTo(zoomed), throwsAssertionError);
  });
}
