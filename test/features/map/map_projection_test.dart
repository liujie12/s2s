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
}
