/// 坐标系转换测试（PRD §6.4.1：全工程统一 GCJ-02）。
///
/// 系统定位（geolocator）返回 WGS-84 → [wgs84ToGcj02] 入表；写错会造成
/// 约 500m 偏移。逆地理走高德 Web 服务（GCJ-02 原生），不吃这里的结果。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/coordinate_transform.dart';

void main() {
  group('wgs84ToGcj02', () {
    test('境外坐标原样返回', () {
      final tokyo = wgs84ToGcj02(lat: 35.6762, lng: 139.6503);
      expect(tokyo.lat, 35.6762);
      expect(tokyo.lng, 139.6503);
    });

    test('北京天安门：偏移方向与量级符合 GCJ-02', () {
      // 常用对照点：WGS-84 (39.908692, 116.397477) → GCJ-02 约 (39.910051, 116.403671)
      final gcj = wgs84ToGcj02(lat: 39.908692, lng: 116.397477);
      expect(gcj.lat, closeTo(39.910051, 1e-3));
      expect(gcj.lng, closeTo(116.403671, 1e-3));
      // 偏移量级应在数百米（约 0.005~0.01 度），过大/过小都说明公式有误。
      expect((gcj.lat - 39.908692).abs(), inInclusiveRange(0.001, 0.02));
      expect((gcj.lng - 116.397477).abs(), inInclusiveRange(0.001, 0.02));
    });

    test('杭州：经度向东偏移、纬度偏移量在数百米量级', () {
      final gcj = wgs84ToGcj02(lat: 30.2741, lng: 120.1551);
      expect(gcj.lng, greaterThan(120.1551));
      expect((gcj.lat - 30.2741).abs(), inInclusiveRange(0.001, 0.02));
    });
  });
}
