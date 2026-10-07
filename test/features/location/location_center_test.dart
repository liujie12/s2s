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
}
