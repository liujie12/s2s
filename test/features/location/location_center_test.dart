/// 定位中心点 Provider 测试（PRD §6.4.1 / §6.7）。
///
/// 锁定 [locationCenterProvider] 默认中心（杭州）与 [LocationCenterNotifier.moveTo]
/// 的移动语义 —— 4 处基准点（距离过滤/排序/显示/视口中心）都读它，中心点只有一个
/// 来源，测试把它钉住防止漂移。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/location_center.dart';

void main() {
  test('默认中心为杭州', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final center = container.read(locationCenterProvider);

    expect(center.lat, kDefaultCenterLat);
    expect(center.lng, kDefaultCenterLng);
  });

  test('moveTo 更新中心点', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container.read(locationCenterProvider.notifier).moveTo(31.0, 121.0);

    final center = container.read(locationCenterProvider);
    expect(center.lat, 31.0);
    expect(center.lng, 121.0);
  });

  group('isUsableLocationFix（PRD §6.8 无效定位判定）', () {
    test('真实定位回传判为有效', () {
      expect(
        isUsableLocationFix(lat: 31.9038, lng: 117.3294, accuracy: 30),
        isTrue,
      );
    });

    test('零坐标判为无效 —— 定位不可用时高德回传 (0,0)，会致地图跳到几内亚湾并空白',
        () {
      expect(isUsableLocationFix(lat: 0, lng: 0, accuracy: 0), isFalse);
    });

    test('零坐标且带非零精度仍判为无效', () {
      expect(isUsableLocationFix(lat: 0, lng: 0, accuracy: 30), isFalse);
    });

    test('零精度判为无效 —— 没有真实测距结果，不能据此认定取点成功', () {
      expect(isUsableLocationFix(lat: 31.9038, lng: 117.3294, accuracy: 0),
          isFalse);
    });

    test('负精度判为无效', () {
      expect(isUsableLocationFix(lat: 31.9038, lng: 117.3294, accuracy: -1),
          isFalse);
    });

    test('只有「同时为零」才算零坐标：本初子午线上的 (0,120) 有效', () {
      expect(isUsableLocationFix(lat: 0, lng: 120, accuracy: 30), isTrue);
    });

    test('只有「同时为零」才算零坐标：赤道上的 (30,0) 有效', () {
      expect(isUsableLocationFix(lat: 30, lng: 0, accuracy: 30), isTrue);
    });

    test('纬度越界判为无效', () {
      expect(isUsableLocationFix(lat: 91, lng: 120, accuracy: 30), isFalse);
      expect(isUsableLocationFix(lat: -91, lng: 120, accuracy: 30), isFalse);
    });

    test('经度越界判为无效', () {
      expect(isUsableLocationFix(lat: 30, lng: 181, accuracy: 30), isFalse);
      expect(isUsableLocationFix(lat: 30, lng: -181, accuracy: 30), isFalse);
    });
  });
}
