/// 城市契约 DTO 解析测试（[132] 前端段）。
///
/// 锁定 [CityItem.fromJson]/[CitiesResponse.fromJson] 的字段映射与可空性纪律：
/// required 字段缺失/类型不符抛 [ApiException.parse]，整数值坐标（JSON 反序列化
/// 后是 int）须正确转 double。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/city/city.dart';

void main() {
  group('CityItem.fromJson', () {
    test('解析完整字段（adcode/name/lat/lng）', () {
      final city = CityItem.fromJson({
        'adcode': '330100',
        'name': '杭州',
        'lat': 30.2741,
        'lng': 120.1551,
      });

      expect(city.adcode, '330100');
      expect(city.name, '杭州');
      expect(city.lat, 30.2741);
      expect(city.lng, 120.1551);
    });

    test('整数值坐标转 double（JSON 整数值反序列化后是 int，须以 num 承接）', () {
      final city = CityItem.fromJson({
        'adcode': '110000',
        'name': '北京',
        'lat': 39,
        'lng': 116,
      });

      expect(city.lat, 39.0);
      expect(city.lng, 116.0);
    });

    test('lat/lng 缺失抛 ApiException（required 不掩盖）', () {
      expect(
        () => CityItem.fromJson({'adcode': '330100', 'name': '杭州', 'lng': 120.0}),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => CityItem.fromJson({'adcode': '330100', 'name': '杭州', 'lat': 30.0}),
        throwsA(isA<ApiException>()),
      );
    });

    test('name 非字符串抛 ApiException（含实际值）', () {
      expect(
        () => CityItem.fromJson({
          'adcode': '330100',
          'name': 123,
          'lat': 30.0,
          'lng': 120.0,
        }),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('CitiesResponse.fromJson', () {
    test('解析城市列表', () {
      final resp = CitiesResponse.fromJson({
        'cities': [
          {'adcode': '330100', 'name': '杭州', 'lat': 30.27, 'lng': 120.15},
          {'adcode': '110000', 'name': '北京', 'lat': 39.90, 'lng': 116.39},
        ],
      });

      expect(resp.cities, hasLength(2));
      expect(resp.cities.first.name, '杭州');
      expect(resp.cities.last.adcode, '110000');
    });

    test('cities 缺失抛 ApiException', () {
      expect(() => CitiesResponse.fromJson({}), throwsA(isA<ApiException>()));
    });
  });
}
