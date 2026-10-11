/// favorite 域仓库（[B2-11]）：收藏列表 / 收藏 / 取消收藏。
///
/// 与 `PostRepository` 同一模式：真网络走 [dioProvider] 生产同款五拦截器链，
/// 本层只做「发请求 + 交 DTO 解析」。写接口（POST/DELETE）的 Idempotency-Key
/// 由 HeaderInterceptor 按写接口纪律注入，本层不碰该头。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import '../../nfr_constants.dart';
import 'favorite_dto.dart';

/// favorite 域仓库。
class FavoriteRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入）。
  FavoriteRepository(this._dio);

  final Dio _dio;

  /// 查我的收藏列表（`GET /favorites?type=`）。
  ///
  /// 参数：[type] 类型筛选（`resource`/`demand`/`all`，缺省 `all`）；
  ///   [page] 页码；[pageSize] 每页条数；[interactionId] X-Interaction-Id。
  /// 返回：[FavoritesPageDto]（items/total/page/page_size）。
  /// 抛出：[ApiException] 信封业务错误（40001 非法 type）/解析失败/传输错误。
  Future<FavoritesPageDto> fetchFavorites({
    String type = 'all',
    int page = 1,
    int pageSize = NfrApi.pageSizeDefault,
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/favorites',
      queryParameters: <String, Object?>{'type': type, 'page': page, 'page_size': pageSize},
      options: _interactionOptions(interactionId),
    );
    return FavoritesPageDto.fromJson(response.data);
  }

  /// 收藏帖子（`POST /posts/{post_id}/favorite`，幂等）。
  ///
  /// 参数：[postId] 帖子 ID；[interactionId] X-Interaction-Id。
  /// 返回：[FavoriteResultDto]（favorited=true）。
  /// 抛出：[ApiException]（40101 未登录 / 41001 帖子不存在）等。
  Future<FavoriteResultDto> addFavorite(int postId, {String? interactionId}) async {
    final response = await _dio.post<Object?>(
      '/posts/$postId/favorite',
      options: _interactionOptions(interactionId),
    );
    return FavoriteResultDto.fromJson(response.data);
  }

  /// 取消收藏（`DELETE /posts/{post_id}/favorite`，幂等软删）。
  ///
  /// 参数：[postId] 帖子 ID；[interactionId] X-Interaction-Id。
  /// 返回：[FavoriteResultDto]（favorited=false）。
  /// 抛出：[ApiException]（40101 未登录）等。
  Future<FavoriteResultDto> removeFavorite(int postId, {String? interactionId}) async {
    final response = await _dio.delete<Object?>(
      '/posts/$postId/favorite',
      options: _interactionOptions(interactionId),
    );
    return FavoriteResultDto.fromJson(response.data);
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

/// favorite 仓库 Provider（dio 经 [dioProvider] 注入）。
final favoriteRepositoryProvider = Provider<FavoriteRepository>(
  (ref) => FavoriteRepository(ref.watch(dioProvider)),
);
