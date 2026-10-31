/// 驾车路径摘要（起终点之间的里程与时长，R7 / KTD5 / KTD6）。
///
/// **为什么用驾车而不是直线距离**：用户判断「这条路顺不顺」看的是开过去
/// 多久，直线距离对绕路、过河、上高速的路线没有解释力。
///
/// **失败即隐藏**：未配置 Key、超时、无路径、`status != 1`、JSON 非法一律
/// 返回 null，由页面隐藏距离段（R13）—— 距离是辅助信息，不能弹错也不能
/// 阻断确认。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../nfr_constants.dart';
import 'amap_degrade.dart';
import 'amap_web_service_key.dart';

/// 一段驾车路径的摘要。
class DrivingSummary {
  /// 构造摘要。
  ///
  /// 参数：[distanceM] 里程（米）；[durationS] 时长（秒）。
  const DrivingSummary({required this.distanceM, required this.durationS});

  /// 驾车里程（米）。
  final int distanceM;

  /// 驾车时长（秒）。
  final int durationS;
}

/// 解析高德驾车路径规划响应。
///
/// 参数：[json] `/v3/direction/driving` 的响应体（已 jsonDecode）。
/// 返回：第一条路径的里程与时长；`status != 1`、`paths` 为空或数值缺失时
///   为 null（多方案时取第一条 —— 高德已按其推荐度排序）。
DrivingSummary? parseDrivingSummary(Object? json) {
  if (json is! Map) return null;
  if (json['status']?.toString() != '1') return null;
  final route = json['route'];
  if (route is! Map) return null;
  final paths = route['paths'];
  if (paths is! List || paths.isEmpty) return null;
  final first = paths.first;
  if (first is! Map) return null;

  // 高德真实响应的 distance/duration 是字符串（"3252"），兼容数字类型防契约漂移。
  final distance = num.tryParse('${first['distance']}');
  final duration = num.tryParse('${first['duration']}');
  if (distance == null || duration == null) return null;
  return DrivingSummary(
    distanceM: distance.toInt(),
    durationS: duration.toInt(),
  );
}

/// 请求两点之间的驾车里程与时长。
///
/// 参数：
/// - [originLng]/[originLat] 起点坐标（GCJ-02）；
/// - [destinationLng]/[destinationLat] 终点坐标（GCJ-02）；
/// - [client] 可注入的 HTTP 客户端（测试用）；传入时由调用方负责关闭；
/// - [onDegraded] 降级回调（只报原因枚举，页面据此上报 `amap_degraded` 埋点）。
///
/// 返回：路径摘要；未配置 Key、超时或任何失败时为 null，**不抛异常**。
Future<DrivingSummary?> fetchDrivingSummary({
  required double originLng,
  required double originLat,
  required double destinationLng,
  required double destinationLat,
  HttpClient? client,
  void Function(AmapDegradeReason reason)? onDegraded,
}) async {
  if (!amapWebServiceKeyConfigured) {
    onDegraded?.call(AmapDegradeReason.noKey);
    return null;
  }

  final ownClient = client == null;
  final http = client ??
      (HttpClient()
        ..connectionTimeout = const Duration(
          milliseconds: NfrLocation.drivingRouteTimeoutMs,
        ));
  try {
    final uri = Uri.https('restapi.amap.com', '/v3/direction/driving', {
      'key': amapWebServiceKey,
      // 高德要求「经度,纬度」顺序。
      'origin': '$originLng,$originLat',
      'destination': '$destinationLng,$destinationLat',
      'extensions': 'base',
      'strategy': '0',
    });
    final request = await http.getUrl(uri);
    final response = await request.close().timeout(
      const Duration(milliseconds: NfrLocation.drivingRouteTimeoutMs),
    );
    if (response.statusCode != HttpStatus.ok) {
      // 只记录状态码：URL 含 Key，消息体也可能带 Key，都不能进日志。
      if (kDebugMode) debugPrint('[DRIVING-ROUTE] http=${response.statusCode}');
      onDegraded?.call(AmapDegradeReason.httpError);
      return null;
    }
    // 响应体也要有上限：只给 request.close() 加超时时，体流停住会永久挂起。
    final body = await utf8.decoder
        .bind(response)
        .join()
        .timeout(const Duration(milliseconds: NfrLocation.drivingRouteTimeoutMs));
    return parseDrivingSummary(jsonDecode(body));
  } catch (e) {
    // 含超时、连接失败与 JSON 解析失败：距离段静默隐藏（R13）。
    // 只打原因枚举，不打 message —— 它可能带上含 Key 的 URL。
    final reason = amapDegradeReasonOf(e);
    if (kDebugMode) debugPrint('[DRIVING-ROUTE] degraded: ${reason.wire}');
    onDegraded?.call(reason);
    return null;
  } finally {
    if (ownClient) http.close(force: true);
  }
}
