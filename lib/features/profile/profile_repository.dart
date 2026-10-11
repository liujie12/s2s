/// profile 域仓库（[B2-11]）：`GET /users/me` 本人资料。
///
/// 与 `PostRepository` 同一模式：真网络走 [dioProvider] 生产同款五拦截器链，
/// 本层只做「发请求 + 交 DTO 解析」，信封由 EnvelopeInterceptor 拆、业务错误
/// 以 ApiException 抛出，本层不吞不改写（编码规范 §1.2）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'profile_dto.dart';

/// profile 域仓库。
class ProfileRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入）。
  ProfileRepository(this._dio);

  final Dio _dio;

  /// 查本人资料（`GET /users/me`，强制登录态）。
  ///
  /// 参数：[interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[MyProfileDto] 本人资料。
  /// 抛出：[ApiException] 信封业务错误（40101 未登录）/解析失败/传输错误归一后的异常。
  Future<MyProfileDto> fetchMyProfile({String? interactionId}) async {
    final response = await _dio.get<Object?>(
      '/users/me',
      options: _interactionOptions(interactionId),
    );
    return MyProfileDto.fromJson(response.data);
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

/// profile 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => ProfileRepository(ref.watch(dioProvider)),
);
