/// settings 域契约 DTO（[B2-11]）：openapi.yaml `SettingsResponse` /
/// `SettingsUpdateRequest` 的逐字段手写映射。
library;

import 'package:zhaoyazhao/core/contract_json.dart';

/// 通知开关 DTO（openapi `SettingsResponse.notify`）。
class NotifySwitchesDto {
  /// 构造通知开关 DTO。
  const NotifySwitchesDto({
    required this.enabled,
    required this.system,
    required this.interaction,
    required this.cert,
  });

  /// 由 `notify` 子对象构造。
  ///
  /// 参数：[json] `notify` 对象。
  /// 返回：[NotifySwitchesDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory NotifySwitchesDto.fromJson(Object? json) {
    final map = requireMap(json, 'SettingsResponse.notify');
    return NotifySwitchesDto(
      enabled: requireBool(map, 'enabled', 'SettingsResponse.notify'),
      system: requireBool(map, 'system', 'SettingsResponse.notify'),
      interaction: requireBool(map, 'interaction', 'SettingsResponse.notify'),
      cert: requireBool(map, 'cert', 'SettingsResponse.notify'),
    );
  }

  /// 消息通知总开关。
  final bool enabled;

  /// 系统通知分通道。
  final bool system;

  /// 互动通知分通道。
  final bool interaction;

  /// 认证通知分通道。
  final bool cert;
}

/// 我的设置 DTO（openapi `SettingsResponse`）。
class SettingsDto {
  /// 构造设置 DTO。
  const SettingsDto({
    required this.notify,
    required this.defaultRadius,
    required this.contactDisplay,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET/PATCH /settings` 的 data 字段）。
  /// 返回：[SettingsDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory SettingsDto.fromJson(Object? json) {
    final map = requireMap(json, 'SettingsResponse');
    final privacy = requireMap(map['privacy'], 'SettingsResponse.privacy');
    return SettingsDto(
      notify: NotifySwitchesDto.fromJson(map['notify']),
      defaultRadius: requireString(map, 'default_radius', 'SettingsResponse'),
      contactDisplay: requireString(privacy, 'contact_display', 'SettingsResponse.privacy'),
    );
  }

  /// 通知开关。
  final NotifySwitchesDto notify;

  /// 默认检索半径档位（`1`/`3`/`5`/`10`/`city`）。
  final String defaultRadius;

  /// 联系方式展示策略（恒 `transit_only`，只读）。
  final String contactDisplay;
}
