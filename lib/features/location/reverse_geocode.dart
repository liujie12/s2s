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

import 'package:flutter/foundation.dart';

import '../../nfr_constants.dart';
import 'amap_degrade.dart';
import 'amap_web_service_key.dart';

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
  void Function(AmapDegradeReason reason)? onDegraded,
}) async {
  if (!amapWebServiceKeyConfigured) {
    onDegraded?.call(AmapDegradeReason.noKey);
    return '';
  }

  final client = HttpClient()
    ..connectionTimeout = const Duration(
      milliseconds: NfrLocation.reverseGeocodeTimeoutMs,
    );
  try {
    final uri = Uri.https('restapi.amap.com', '/v3/geocode/regeo', {
      'key': amapWebServiceKey,
      // 高德要求「经度,纬度」顺序。
      'location': '$lng,$lat',
      'radius': '${NfrLocation.reverseGeocodeRadiusMeters}',
      'extensions': 'base',
    });
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(
      const Duration(milliseconds: NfrLocation.reverseGeocodeTimeoutMs),
    );
    if (response.statusCode != HttpStatus.ok) {
      // 只记录状态码：URL 含 Key，消息体也可能带 Key，都不能进日志。
      if (kDebugMode) debugPrint('[REGEO] http=${response.statusCode}');
      onDegraded?.call(AmapDegradeReason.httpError);
      return '';
    }
    // 响应体也要有上限：只给 request.close() 加超时时，体流停住会永久挂起。
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(milliseconds: NfrLocation.reverseGeocodeTimeoutMs));
    final json = jsonDecode(body);
    if (json is! Map) return '';
    if (json['status']?.toString() != '1') return '';
    final regeocode = json['regeocode'];
    if (regeocode is! Map) return '';
    return (regeocode['formatted_address'] ?? '').toString().trim();
  } catch (e) {
    // 只打原因枚举，不打 message —— 它可能带上含 Key 的 URL。
    final reason = amapDegradeReasonOf(e);
    if (kDebugMode) debugPrint('[REGEO] degraded: ${reason.wire}');
    onDegraded?.call(reason);
    return '';
  } finally {
    client.close(force: true);
  }
}
