/// 探索页仓库（[126] 前端段）：地图图钉与列表检索两个接口。
///
/// 与 `CategoryRepository`/`PostRepository` 同一模式：真网络走 [dioProvider]
/// 生产同款五拦截器链；本层只做「发请求 + 交 DTO 解析」，信封由
/// EnvelopeInterceptor 拆、业务错误以 [ApiException] 抛出，本层不吞不改写。
///
/// 两个接口**共用同一套筛选参数**（契约 `/posts/search` description 明写），
/// 故五个缓存键要素（category_ids / post_type / radius / grid_id /
/// category_version）在此以同一形状透传，避免两处各写一份而漂移。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'map_dto.dart';

/// 探索页仓库。
///
/// 无实例状态，不需要单实例纪律；dio 由构造注入，与 [dioProvider] 生产装配同源。
class MapRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness
  ///   注入，生产经 [mapRepositoryProvider] 注入）。
  MapRepository(this._dio);

  final Dio _dio;

  /// 拉取地图图钉集合（`GET /map/pins`，读超时收紧至 3s）。
  ///
  /// 参数：
  ///   [categoryIds]       叶子类目 ID 列表（缓存键要素 1，**至少一个**；
  ///                       契约 `minItems: 1`，缺项服务端回 40001）；
  ///   [postType]          供需态（缓存键要素 2，`resource`/`demand`）；
  ///   [radius]            半径档（缓存键要素 3，`1`/`3`/`5`/`10`/`city`）；
  ///   [gridId]            约 500m 网格（缓存键要素 4，`gx_gy`）；
  ///   [categoryVersion]   分类树版本号（缓存键要素 5）；
  ///   [lng]、[lat]        视野中心（GCJ-02）；
  ///   [zoom]              地图缩放级别（决定 cluster/pin 模式切换）。
  ///   [interactionId]     交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[PinsCompactDto]（紧凑数组已按 schema 解析）。
  /// 抛出：[ApiException] 信封业务错误（含 40001 五要素缺失）/解析失败。
  Future<PinsCompactDto> fetchPins({
    required List<int> categoryIds,
    required String postType,
    required String radius,
    required String gridId,
    required String categoryVersion,
    required double lng,
    required double lat,
    required double zoom,
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/map/pins',
      queryParameters: <String, Object?>{
        // 契约 style=form + explode=false：数组序列化为**单个逗号连接参数**
        // （`category_ids=10101,10102`），不是重复同名参数。dio 对 List 的默认
        // 序列化是后者，故此处显式 join，交由 URL 编码即可。
        'category_ids': categoryIds.join(','),
        'post_type': postType,
        'radius': radius,
        'grid_id': gridId,
        'category_version': categoryVersion,
        'lng': lng,
        'lat': lat,
        'zoom': zoom,
      },
      options: _pinsOptions(interactionId),
    );
    return PinsCompactDto.fromJson(response.data);
  }

  /// 列表检索（`GET /posts/search`，与地图同源筛选条件）。
  ///
  /// 参数同 [fetchPins]，另加：
  ///   [keyword]  关键词（可空；长度上限由契约 maxLength 32 约束）；
  ///   [sort]     排序（`distance`/`publish_time`/`completeness`，缺省 distance）；
  ///   [page]     页码（从 1 起）；
  ///   [pageSize] 每页条数（契约默认 20、上限 50）。
  /// 返回：[SearchPostsPageDto]。
  /// 抛出：[ApiException] 信封业务错误/解析失败。
  Future<SearchPostsPageDto> searchPosts({
    required List<int> categoryIds,
    required String postType,
    required String radius,
    required String gridId,
    required String categoryVersion,
    required double lng,
    required double lat,
    String? keyword,
    String? sort,
    int? page,
    int? pageSize,
    String? interactionId,
  }) async {
    final query = <String, Object?>{
      'category_ids': categoryIds.join(','),
      'post_type': postType,
      'radius': radius,
      'grid_id': gridId,
      'category_version': categoryVersion,
      'lng': lng,
      'lat': lat,
      // 可选项缺省即不传：传空串会被服务端判非法值。
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
      'sort': ?sort,
      'page': ?page,
      'page_size': ?pageSize,
    };
    final response = await _dio.get<Object?>(
      '/posts/search',
      queryParameters: query,
      options: _interactionOptions(interactionId),
    );
    return SearchPostsPageDto.fromJson(response.data);
  }

  /// 组装 `/map/pins` 的按请求选项（在 3s 读超时之上叠加交互头）。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值（由拦截器兜底生成）。
  /// 返回：[Options] 含 [mapPinsOptions] 的收紧读超时。
  Options _pinsOptions(String? interactionId) {
    final base = mapPinsOptions();
    if (interactionId == null) return base;
    return base.copyWith(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }

  /// 组装携带 X-Interaction-Id 的按请求选项（头注入走「containsKey 才写」纪律）。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options?]；null 走 BaseOptions 默认。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// 探索页仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final mapRepositoryProvider = Provider<MapRepository>(
  (ref) => MapRepository(ref.watch(dioProvider)),
);
