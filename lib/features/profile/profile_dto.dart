/// profile 域契约 DTO（[B2-11]）：openapi.yaml `MyProfile`（`GET /users/me`）
/// 的逐字段手写映射。
///
/// 与 post_dto 同构的分工：只承载传输形态（snake_case 键、可空性与 schema
/// `required` 逐字对齐），字段读取助手引用 `core/contract_json.dart` 唯一实现处。
library;

import 'package:zhaoyazhao/core/contract_json.dart';

/// 本人资料 DTO（openapi `MyProfile`：required = id/nickname/realname_status）。
///
/// 该接口为**本人视角**，故含 `phone_mask` 与 `default_radius`（他人视角白名单
/// 不含这两项，见契约 description）。`real_name_enc`/`id_card_hash` 等敏感列
/// 永不出现在响应中，故 DTO 不设对应字段。
class MyProfileDto {
  /// 构造本人资料 DTO。
  const MyProfileDto({
    required this.id,
    required this.nickname,
    required this.realnameStatus,
    this.avatarUrl,
    this.qualificationBadges,
    this.defaultRadius,
    this.phoneMask,
    this.phoneBound = true,
    this.wechatBound = false,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET /users/me` 的 data 字段）。
  /// 返回：[MyProfileDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory MyProfileDto.fromJson(Object? json) {
    final map = requireMap(json, 'MyProfile');
    return MyProfileDto(
      id: requireInt(map, 'id', 'MyProfile'),
      nickname: requireString(map, 'nickname', 'MyProfile'),
      realnameStatus: requireString(map, 'realname_status', 'MyProfile'),
      avatarUrl: optString(map, 'avatar_url', 'MyProfile'),
      qualificationBadges: optStringList(map, 'qualification_badges', 'MyProfile'),
      defaultRadius: optString(map, 'default_radius', 'MyProfile'),
      phoneMask: optString(map, 'phone_mask', 'MyProfile'),
      // 老服务端/测试夹具缺这两个键时：历史用户只可能来自手机号登录，故默认 true
      phoneBound: optBool(map, 'phone_bound', 'MyProfile') ?? true,
      wechatBound: optBool(map, 'wechat_bound', 'MyProfile') ?? false,
    );
  }

  /// 用户 ID。
  final int id;

  /// 昵称。
  final String nickname;

  /// 实名状态（契约枚举 `none`/`pending`/`passed`/`rejected`）。
  final String realnameStatus;

  /// 头像 URL（可空：未设置）。
  final String? avatarUrl;

  /// 已通过的资质徽章标识列表（可空）。
  final List<String>? qualificationBadges;

  /// 默认检索半径档位（可空；本人视角才下发）。
  final String? defaultRadius;

  /// 脱敏手机号（可空；本人视角才下发），如 `138****8000`。
  final String? phoneMask;

  /// 是否已绑定手机号（B2-6a；懒绑定下微信用户可能为 false）。
  final bool phoneBound;

  /// 是否已绑定微信（B2-6a；设置页「绑定微信」状态）。
  final bool wechatBound;

  /// 是否已实名通过（`passed`）。页面据此显示「已实名」标或引导去完善。
  ///
  /// 参数：无。
  /// 返回：bool。
  bool get isRealnamePassed => realnameStatus == 'passed';
}
