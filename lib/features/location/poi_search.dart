/// POI 输入提示（起终点选择页的候选列表，R6 / KTD5）。
///
/// **为什么端内直连高德**：与逆地理同源同 Key，失败降级口径一致；走服务端
/// 代理要多一张契约与一层限流，而候选只是输入的辅助。若日后配额或 Key 治理
/// 不允许端内直连，改走代理时只替换本文件，UI 不变。
///
/// **失败即空**：未配置 Key、超时、非 200、`status != 1`、JSON 非法、字段
/// 类型不符，一律返回空列表而不抛错 —— 候选为空时用户仍可手打完整名称或用
/// 地图选点，发布链路不该被一个提示接口拖死。
library;

import 'dart:convert';
import 'dart:io';

import '../../nfr_constants.dart';
import 'amap_web_service_key.dart';

/// 一条 POI 候选。
class PoiSuggestion {
  /// 构造候选。
  ///
  /// 参数：[id] 高德 POI ID（用于去重与埋点标识）；[name] 名称（主值）；
  /// [address] 地址描述（副文，可能为空串）；[lng]/[lat] GCJ-02 坐标。
  const PoiSuggestion({
    required this.id,
    required this.name,
    required this.address,
    required this.lng,
    required this.lat,
  });

  /// 高德 POI ID。
  final String id;

  /// 地点名称（回填到起/终点行的主值）。
  final String name;

  /// 地址描述（回填到副文与 `address` 字段）。
  final String address;

  /// 经度（GCJ-02）。
  final double lng;

  /// 纬度（GCJ-02）。
  final double lat;
}

/// 解析高德输入提示响应。
///
/// 参数：[json] `/v3/assistant/inputtips` 的响应体（已 jsonDecode）。
/// 返回：候选列表；`status != 1` 或结构不符时为空列表。缺 `id`、缺名称或缺
///   `location` 的条目直接跳过（回填不了坐标的候选没有意义），其余保留，
///   最多 [NfrLocation.poiSearchMaxResults] 条。
List<PoiSuggestion> parseInputTips(Object? json) {
  if (json is! Map) return const <PoiSuggestion>[];
  if (json['status']?.toString() != '1') return const <PoiSuggestion>[];
  final tips = json['tips'];
  if (tips is! List) return const <PoiSuggestion>[];

  final result = <PoiSuggestion>[];
  for (final tip in tips) {
    if (result.length >= NfrLocation.poiSearchMaxResults) break;
    if (tip is! Map) continue;
    final id = _stringOf(tip['id']);
    final name = _stringOf(tip['name']);
    final coordinate = _parseLocation(tip['location']);
    if (id.isEmpty || name.isEmpty || coordinate == null) continue;

    // `address` 在高德响应里可能是字符串，也可能是空数组（无地址时）。
    // 空则退回 district（区县名），让每条候选都有一句可读的位置描述。
    final address = _stringOf(tip['address']);
    result.add(
      PoiSuggestion(
        id: id,
        name: name,
        address: address.isEmpty ? _stringOf(tip['district']) : address,
        lng: coordinate.lng,
        lat: coordinate.lat,
      ),
    );
  }
  return result;
}

/// 按关键词搜索 POI 候选。
///
/// 参数：
/// - [keywords] 用户输入的关键词（空白串不发请求）；
/// - [lng]/[lat] 当前位置，作为排序偏置（有则带、无则全省，不影响结果可用性）；
/// - [client] 可注入的 HTTP 客户端（测试用）；传入时由调用方负责关闭。
///
/// 返回：候选列表；未配置 Key、关键词过短、超时或任何失败时为空列表，
///   **不抛异常**。
Future<List<PoiSuggestion>> searchPoiSuggestions({
  required String keywords,
  double? lng,
  double? lat,
  HttpClient? client,
}) async {
  final trimmed = keywords.trim();
  if (!amapWebServiceKeyConfigured) return const <PoiSuggestion>[];
  if (trimmed.length < NfrLocation.poiSearchMinKeywordLength) {
    return const <PoiSuggestion>[];
  }

  final ownClient = client == null;
  final http = client ??
      (HttpClient()
        ..connectionTimeout = const Duration(
          milliseconds: NfrLocation.poiSearchTimeoutMs,
        ));
  try {
    final query = <String, String>{
      'key': amapWebServiceKey,
      'keywords': trimmed,
      'output': 'json',
    };
    // 位置偏置：高德要求「经度,纬度」顺序；只有两端都齐备才带。
    if (lng != null && lat != null) {
      query['location'] = '$lng,$lat';
    }
    final uri = Uri.https('restapi.amap.com', '/v3/assistant/inputtips', query);
    final request = await http.getUrl(uri);
    final response = await request.close().timeout(
      const Duration(milliseconds: NfrLocation.poiSearchTimeoutMs),
    );
    if (response.statusCode != HttpStatus.ok) return const <PoiSuggestion>[];
    final body = await utf8.decoder.bind(response).join();
    return parseInputTips(jsonDecode(body));
  } catch (_) {
    // 含超时、连接失败与 JSON 解析失败：候选是辅助信息，静默降级为空列表。
    return const <PoiSuggestion>[];
  } finally {
    if (ownClient) http.close(force: true);
  }
}

/// 读取字符串字段（非字符串一律空串，避免 `null` 文案漏进 UI）。
///
/// 参数：[value] 原始值。返回：去空白后的字符串。
String _stringOf(Object? value) => value is String ? value.trim() : '';

/// 解析高德 `location` 字段（格式 `"经度,纬度"`）。
///
/// 参数：[raw] 原始值（字符串或列表，高德两种都出现过）。
/// 返回：坐标；缺失或不是两个数值时为 null。
({double lng, double lat})? _parseLocation(Object? raw) {
  final parts = switch (raw) {
    String s => s.split(','),
    List<Object?> list when list.length == 2 => list,
    _ => null,
  };
  if (parts == null || parts.length != 2) return null;
  final lng = double.tryParse(parts[0].toString().trim());
  final lat = double.tryParse(parts[1].toString().trim());
  if (lng == null || lat == null) return null;
  return (lng: lng, lat: lat);
}
