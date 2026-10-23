/// settings 域仓库（[B2-11]）：`GET/PATCH /settings`。
///
/// 与 `PostRepository` 同一模式：真网络走 [dioProvider] 生产同款五拦截器链，
/// 本层只做「发请求 + 交 DTO 解析」。PATCH 为局部更新：只为**非 null 入参**
/// 组装请求体字段（`null`＝不动）；隐私项中仅 `personalized_recommend` 可写。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'settings_dto.dart';

/// settings 域仓库。
class SettingsRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入）。
  SettingsRepository(this._dio);

  final Dio _dio;

  /// 读我的设置（`GET /settings`，强制登录态）。
  ///
  /// 参数：[interactionId] X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[SettingsDto]。
  /// 抛出：[ApiException]（40101 未登录）/解析失败/传输错误。
  Future<SettingsDto> fetchSettings({String? interactionId}) async {
    final response = await _dio.get<Object?>(
      '/settings',
      options: _interactionOptions(interactionId),
    );
    return SettingsDto.fromJson(response.data);
  }

  /// 局部更新我的设置（`PATCH /settings`）。
  ///
  /// 参数：各通知开关、[defaultRadius]、[personalizedRecommend] 与 [aiImprove]
  ///   均为「null＝不动」；[interactionId] X-Interaction-Id。
  /// 返回：[SettingsDto] 更新后的完整设置。
  /// 抛出：[ApiException]（40001 default_radius 非法 / 40101 未登录）等。
  Future<SettingsDto> updateSettings({
    bool? notifyEnabled,
    bool? notifySystem,
    bool? notifyInteraction,
    bool? notifyCert,
    String? defaultRadius,
    bool? personalizedRecommend,
    bool? aiImprove,
    String? interactionId,
  }) async {
    final notify = <String, Object?>{
      'enabled': ?notifyEnabled,
      'system': ?notifySystem,
      'interaction': ?notifyInteraction,
      'cert': ?notifyCert,
    };
    final privacy = <String, Object?>{
      'personalized_recommend': ?personalizedRecommend,
      'ai_improve': ?aiImprove,
    };
    final body = <String, Object?>{
      if (notify.isNotEmpty) 'notify': notify,
      'default_radius': ?defaultRadius,
      if (privacy.isNotEmpty) 'privacy': privacy,
    };
    final response = await _dio.patch<Object?>(
      '/settings',
      data: body,
      options: _interactionOptions(interactionId),
    );
    return SettingsDto.fromJson(response.data);
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options]；null 时由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// settings 仓库 Provider（dio 经 [dioProvider] 注入）。
final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(dioProvider)),
);
