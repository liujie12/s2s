/// city 域仓库（[132] 前端段）：可选城市列表拉取。
///
/// 走真网络而非本地替身：请求经 [dioProvider] 生产同款五拦截器链发出，
/// 后端就绪切 baseUrl 即可。本层只做「发请求 + 交 DTO 解析」，信封由
/// EnvelopeInterceptor 拆、业务错误以 [ApiException] 抛出，本层不吞不改写
/// （编码规范 §1.2）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'city.dart';

/// city 域仓库。
///
/// 无实例状态，故不需要单实例纪律；dio 由构造注入，与 [dioProvider] 同源。
class CityRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（生产经 [cityRepositoryProvider] 注入）。
  CityRepository(this._dio);

  final Dio _dio;

  /// 拉取可选城市列表（`GET /cities`，游客可访问）。
  ///
  /// 参数：
  ///   [interactionId] 交互起点生成的 X-Interaction-Id（详设 §11.2 逐层透传）；
  ///     null 时由 HeaderInterceptor 兜底生成。
  /// 返回：[List]<[CityItem]> 城市列表。
  /// 抛出：[ApiException] 信封业务错误/解析失败（拦截器链与 DTO 抛出）。
  Future<List<CityItem>> fetchCities({String? interactionId}) async {
    final response = await _dio.get<Object?>(
      '/cities',
      options: _interactionOptions(interactionId),
    );
    return CitiesResponse.fromJson(response.data).cities;
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options?]；null 时走 BaseOptions 默认，头由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// city 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final cityRepositoryProvider = Provider<CityRepository>(
  (ref) => CityRepository(ref.watch(dioProvider)),
);
