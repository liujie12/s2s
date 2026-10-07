/// 城市契约 DTO（openapi.yaml `CityItem`/`CitiesResponse` 的逐字段手写映射，
/// 详设 §10.3）。
///
/// 定位兜底「手动选城市」出口的数据模型：{@code adcode} 为行政区划代码
/// （稳定标识），{@code lat}/{@code lng} 为城市中心坐标（GCJ-02），仅用于
/// 确定地图中心，不在客户端做行政区过滤（DEC-24）。
library;

import 'package:zhaoyazhao/core/contract_json.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

/// 城市条目 DTO（openapi.yaml `CityItem`：required = adcode/name/lat/lng）。
class CityItem {
  /// 构造城市条目 DTO。
  const CityItem({
    required this.adcode,
    required this.name,
    required this.lat,
    required this.lng,
  });

  /// 由信封 data 内的城市对象构造。
  ///
  /// 参数：[json] 信封 data 数组中的单个城市对象。
  /// 返回：[CityItem]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory CityItem.fromJson(Object? json) {
    final map = requireMap(json, 'CityItem');
    final lat = map['lat'];
    final lng = map['lng'];
    // lat/lng 是契约 format:double 的必填字段，但 JSON 整数值反序列化后是
    // int，须以 num 承接再转 double（同 contract_json 里 optDouble 的口径）。
    if (lat is! num || lng is! num) {
      throw ApiException.parse(
        'CityItem.lat/lng 应为 number，实际 lat=$lat, lng=$lng',
      );
    }
    return CityItem(
      adcode: requireString(map, 'adcode', 'CityItem'),
      name: requireString(map, 'name', 'CityItem'),
      lat: lat.toDouble(),
      lng: lng.toDouble(),
    );
  }

  /// 行政区划代码（稳定标识）。
  final String adcode;

  /// 城市名称。
  final String name;

  /// 城市中心纬度（GCJ-02）。
  final double lat;

  /// 城市中心经度（GCJ-02）。
  final double lng;
}

/// 可选城市列表 DTO（openapi.yaml `CitiesResponse`：required = cities）。
class CitiesResponse {
  /// 构造城市列表 DTO。
  const CitiesResponse({required this.cities});

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data。
  /// 返回：[CitiesResponse]。
  /// 抛出：[ApiException.parse] `cities` 缺失/非数组或任一元素解析失败时。
  factory CitiesResponse.fromJson(Object? json) {
    final map = requireMap(json, 'CitiesResponse');
    return CitiesResponse(
      cities: [
        for (final item in requireList(map, 'cities', 'CitiesResponse'))
          CityItem.fromJson(item),
      ],
    );
  }

  /// 城市列表。
  final List<CityItem> cities;
}
