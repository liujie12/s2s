/// 逆地理：GCJ-02 坐标 → 可读地址文案。
///
/// 用途是**展示**（让发布用户核对选点是否正确），不作为落库地址
/// （`post.address` 的公开口径尚未裁定）。
///
/// **只用高德 Web 服务**（`AMAP_WEBSERVICE_KEY`，构建期注入）：
/// - 与地图同一数据源、原生 GCJ-02，结果与准星一致；
/// - **跨机型一致** —— 系统 `Geocoder` 的道路库由 ROM 决定（2026-10-17 真机：
///   准星在北城世纪城，小米系统返回「阜公路」），保留它会让不同手机显示不同
///   地址，故**刻意不做系统兜底**；不可用时明确显示「无法获取位置名称」。
library;

import 'dart:convert';
import 'dart:io';

import '../../nfr_constants.dart';

/// 高德 Web 服务 Key 的 `--dart-define` 变量名（全工程唯一真源）。
///
/// 与地图 Android Key 不同链路：它是 Web 服务（逆地理/POI）凭证，
/// 只经构建期注入，不入仓库。
const String kAmapWebServiceKeyDefine = 'AMAP_WEBSERVICE_KEY';

/// 构建期注入的高德 Web 服务 Key（未注入时为空串 → 逆地理不可用）。
const String _kAmapWebServiceKey = String.fromEnvironment(
  kAmapWebServiceKeyDefine,
);

/// 把坐标逆地理成一行可读地址。
///
/// 参数：
/// - [lat] 纬度（**GCJ-02**，与工程内其余坐标一致）；
/// - [lng] 经度（GCJ-02）。
///
/// 返回：`formatted_address`；未注入 Key、请求失败、超时或返回失败码时为空串
/// （调用方展示「暂时无法获取位置名称」）。
Future<String> reverseGeocodeLabel({
  required double lat,
  required double lng,
}) async {
  if (_kAmapWebServiceKey.isEmpty) return '';

  final client = HttpClient()
    ..connectionTimeout = const Duration(
      milliseconds: NfrLocation.reverseGeocodeTimeoutMs,
    );
  try {
    final uri = Uri.https('restapi.amap.com', '/v3/geocode/regeo', {
      'key': _kAmapWebServiceKey,
      // 高德要求「经度,纬度」顺序。
      'location': '$lng,$lat',
      'radius': '${NfrLocation.reverseGeocodeRadiusMeters}',
      'extensions': 'base',
    });
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(
      const Duration(milliseconds: NfrLocation.reverseGeocodeTimeoutMs),
    );
    if (response.statusCode != HttpStatus.ok) return '';
    final body = await utf8.decoder.bind(response).join();
    final json = jsonDecode(body);
    if (json is! Map) return '';
    if (json['status']?.toString() != '1') return '';
    final regeocode = json['regeocode'];
    if (regeocode is! Map) return '';
    return (regeocode['formatted_address'] ?? '').toString().trim();
  } catch (_) {
    return '';
  } finally {
    client.close(force: true);
  }
}
