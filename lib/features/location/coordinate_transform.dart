/// WGS-84 → GCJ-02 坐标转换（唯一实现处）。
///
/// 系统定位（`geolocator`）返回 WGS-84，工程统一 GCJ-02（PRD §6.4.1），
/// 取点入表前必须转换；逆地理走高德 Web 服务，天然是 GCJ-02，无需反算。
///
/// 只做中国境内偏移（境外原样返回）。
library;

import 'dart:math' as math;

/// 坐标系转换的椭球参数（克拉索夫斯基椭球，GCJ-02 算法固定值）。
const double _gcjSemiMajorAxis = 6378245.0;
const double _gcjEccentricitySquared = 0.00669342162296594323;

/// WGS-84 → GCJ-02 坐标转换。
///
/// 参数：
/// - [lat] WGS-84 纬度；
/// - [lng] WGS-84 经度。
///
/// 返回：GCJ-02 纬度/经度；境外坐标原样返回。
({double lat, double lng}) wgs84ToGcj02({
  required double lat,
  required double lng,
}) {
  if (_outOfChina(lat: lat, lng: lng)) {
    return (lat: lat, lng: lng);
  }
  var dLat = _transformLat(x: lng - 105.0, y: lat - 35.0);
  var dLng = _transformLng(x: lng - 105.0, y: lat - 35.0);
  final radLat = lat / 180.0 * math.pi;
  final sinLat = math.sin(radLat);
  final magic = 1 - _gcjEccentricitySquared * sinLat * sinLat;
  final sqrtMagic = math.sqrt(magic);
  dLat = (dLat * 180.0) /
      ((_gcjSemiMajorAxis * (1 - _gcjEccentricitySquared)) /
          (magic * sqrtMagic) *
          math.pi);
  dLng = (dLng * 180.0) /
      (_gcjSemiMajorAxis / sqrtMagic * math.cos(radLat) * math.pi);
  return (lat: lat + dLat, lng: lng + dLng);
}

/// 判断坐标是否在中国境外（GCJ-02 偏移只在中国境内生效）。
///
/// 参数：
/// - [lat] 纬度；
/// - [lng] 经度。
///
/// 返回：true 表示境外。
bool _outOfChina({required double lat, required double lng}) {
  return lng < 72.004 || lng > 137.8347 || lat < 0.8293 || lat > 55.8271;
}

/// GCJ-02 纬度偏移量的中间量。
///
/// 参数：
/// - [x] 经度 - 105；
/// - [y] 纬度 - 35。
///
/// 返回：未经椭球修正的纬度偏移量。
double _transformLat({required double x, required double y}) {
  var ret = -100.0 +
      2.0 * x +
      3.0 * y +
      0.2 * y * y +
      0.1 * x * y +
      0.2 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(y * math.pi) +
          40.0 * math.sin(y / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (160.0 * math.sin(y / 12.0 * math.pi) +
          320 * math.sin(y * math.pi / 30.0)) *
      2.0 /
      3.0;
  return ret;
}

/// GCJ-02 经度偏移量的中间量。
///
/// 参数：
/// - [x] 经度 - 105；
/// - [y] 纬度 - 35。
///
/// 返回：未经椭球修正的经度偏移量。
double _transformLng({required double x, required double y}) {
  var ret = 300.0 +
      x +
      2.0 * y +
      0.1 * x * x +
      0.1 * x * y +
      0.1 * math.sqrt(x.abs());
  ret += (20.0 * math.sin(6.0 * x * math.pi) +
          20.0 * math.sin(2.0 * x * math.pi)) *
      2.0 /
      3.0;
  ret += (20.0 * math.sin(x * math.pi) +
          40.0 * math.sin(x / 3.0 * math.pi)) *
      2.0 /
      3.0;
  ret += (150.0 * math.sin(x / 12.0 * math.pi) +
          300.0 * math.sin(x / 30.0 * math.pi)) *
      2.0 /
      3.0;
  return ret;
}
