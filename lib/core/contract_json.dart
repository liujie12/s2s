/// 契约 JSON 字段读取助手（[124] B4 从 category_dto.dart 上浮）。
///
/// category 域 DTO 私有解析助手在 post 域 DTO（PrecheckResult/PostDraft）
/// 出现第二处需求后按反冗余纪律（编码规范 §1.1「跨域复用 → lib/core/」）
/// 上浮为唯一实现处；两个 DTO 文件的 fromJson 均引用本文件，不得再私建
/// 副本。
///
/// 统一口径：类型违约一律经 [ApiException.parse] 工厂抛出（守门判据 C：
/// 禁内联 parseError 构造），message 含实际收到值供诊断。
library;

import 'network/api_exception.dart';

/// 取 JSON 对象本体（fromJson 入口校验）。
///
/// 参数：[json] 待解析值；[owner] 契约类型名（诊断用）。
/// 返回：[Map] 字符串键视图。
/// 抛出：[ApiException.parse] 非 JSON 对象时。
Map<String, Object?> requireMap(Object? json, String owner) {
  if (json is! Map) {
    throw ApiException.parse(
      '$owner 应为 JSON 对象，实际类型: ${json.runtimeType}',
    );
  }
  return json.cast<String, Object?>();
}

/// 取必填 String 字段。
///
/// 参数：[map] 父对象；[key] 契约 snake_case 键；[owner] 契约类型名。
/// 返回：[String] 字段值。
/// 抛出：[ApiException.parse] 字段缺失或非 String 时（含实际值）。
String requireString(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value is! String) {
    throw ApiException.parse(
      '$owner.$key 缺失或类型不符（期望 String），实际: $value',
    );
  }
  return value;
}

/// 取必填 int 字段。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[int] 字段值。
/// 抛出：[ApiException.parse] 字段缺失或非 int 时（含实际值）。
int requireInt(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value is! int) {
    throw ApiException.parse(
      '$owner.$key 缺失或类型不符（期望 int），实际: $value',
    );
  }
  return value;
}

/// 取必填 bool 字段。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[bool] 字段值。
/// 抛出：[ApiException.parse] 字段缺失或非 bool 时（含实际值）。
bool requireBool(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value is! bool) {
    throw ApiException.parse(
      '$owner.$key 缺失或类型不符（期望 bool），实际: $value',
    );
  }
  return value;
}

/// 取必填数组字段。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[List] 字段值（元素类型由调用方逐项解析校验）。
/// 抛出：[ApiException.parse] 字段缺失或非数组时（含实际值）。
List<Object?> requireList(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value is! List) {
    throw ApiException.parse(
      '$owner.$key 缺失或类型不符（期望数组），实际: $value',
    );
  }
  return value;
}

/// 取可选 String 字段（缺失/JSON null 均为 null，不用默认值掩盖）。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[String?] 字段值；缺失为 null。
/// 抛出：[ApiException.parse] 出现但非 String 时（服务端违约，含实际值）。
String? optString(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String) {
    throw ApiException.parse(
      '$owner.$key 应为 String 或 null，实际: $value',
    );
  }
  return value;
}

/// 取可选 bool 字段（缺失/JSON null 均为 null）。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[bool?] 字段值；缺失为 null。
/// 抛出：[ApiException.parse] 出现但非 bool 时（含实际值）。
bool? optBool(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value == null) return null;
  if (value is! bool) {
    throw ApiException.parse(
      '$owner.$key 应为 bool 或 null，实际: $value',
    );
  }
  return value;
}

/// 取可选 int 字段（缺失/JSON null 均为 null；[124] B4 precheck
/// completeness_level 首个消费方）。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[int?] 字段值；缺失为 null。
/// 抛出：[ApiException.parse] 出现但非 int 时（含实际值）。
int? optInt(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value == null) return null;
  if (value is! int) {
    throw ApiException.parse(
      '$owner.$key 应为 int 或 null，实际: $value',
    );
  }
  return value;
}

/// 取可选字符串数组字段（缺失/JSON null 均为 null，元素逐个校验）。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[List<String>?] 字段值；缺失为 null。
/// 抛出：[ApiException.parse] 出现但非数组、或元素非 String 时（含实际值）。
List<String>? optStringList(
  Map<String, Object?> map,
  String key,
  String owner,
) {
  final value = map[key];
  if (value == null) return null;
  if (value is! List) {
    throw ApiException.parse(
      '$owner.$key 应为字符串数组或 null，实际: $value',
    );
  }
  return [
    for (final item in value)
      if (item is String)
        item
      else
        throw ApiException.parse(
          '$owner.$key 元素应为 String，实际: $item',
        ),
  ];
}
