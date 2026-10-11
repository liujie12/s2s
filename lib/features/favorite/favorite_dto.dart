/// favorite 域契约 DTO（[B2-11]）：openapi.yaml `FavoriteItem` /
/// `FavoritesResponse` / `FavoriteResult` 的逐字段手写映射。
///
/// 卡片所需字段（post_id/type/title/price/封面/状态）在此；类目路径与距离
/// 客户端另经分类树与定位补，不属本 DTO（契约无对应字段）。
library;

import 'package:zhaoyazhao/core/contract_json.dart';

/// 我的收藏列表项 DTO（openapi `FavoriteItem`）。
///
/// 视角为收藏者（非帖主）：`cover_media` 只可能是 `audit_status=pass` 的项，
/// 故只取 `url` 供卡片展示。
class FavoriteItemDto {
  /// 构造收藏项 DTO。
  const FavoriteItemDto({
    required this.postId,
    required this.type,
    required this.title,
    required this.completenessLevel,
    required this.status,
    required this.favoriteAt,
    this.leafCategoryId,
    this.l2CategoryId,
    this.categoryPath,
    this.price,
    this.priceUnit,
    this.coverUrl,
    this.publishAt,
  });

  /// 由信封 data 内的 `items[]` 元素构造。
  ///
  /// 参数：[json] `GET /favorites` 的 data.items 元素。
  /// 返回：[FavoriteItemDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory FavoriteItemDto.fromJson(Object? json) {
    final map = requireMap(json, 'FavoriteItem');
    return FavoriteItemDto(
      postId: requireInt(map, 'post_id', 'FavoriteItem'),
      type: requireString(map, 'type', 'FavoriteItem'),
      title: requireString(map, 'title', 'FavoriteItem'),
      completenessLevel: requireInt(map, 'completeness_level', 'FavoriteItem'),
      status: requireString(map, 'status', 'FavoriteItem'),
      favoriteAt: requireDateTime(map, 'favorite_at', 'FavoriteItem'),
      leafCategoryId: optInt(map, 'leaf_category_id', 'FavoriteItem'),
      l2CategoryId: optInt(map, 'l2_category_id', 'FavoriteItem'),
      categoryPath: optStringList(map, 'category_path', 'FavoriteItem'),
      price: optDouble(map, 'price', 'FavoriteItem'),
      priceUnit: optString(map, 'price_unit', 'FavoriteItem'),
      coverUrl: _coverUrl(map),
      publishAt: optDateTime(map, 'publish_at', 'FavoriteItem'),
    );
  }

  /// 帖子 ID。
  final int postId;

  /// 供需态（`resource`/`demand`）。
  final String type;

  /// 标题。
  final String title;

  /// 完整度档位（0/1/2）。
  final int completenessLevel;

  /// 状态（API 值：active/offline/expired/archived）。
  final String status;

  /// 收藏时间（列表排序键）。
  final DateTime favoriteAt;

  /// 叶子类目 ID（可空）。
  final int? leafCategoryId;

  /// 二级类目 ID（可空）。
  final int? l2CategoryId;

  /// 类目面包屑名称（L1 → L2 → L3；可空＝未知类目），用于卡片副标题。
  final List<String>? categoryPath;

  /// 价格（元；null=面议）。
  final double? price;

  /// 价格单位（price 为 null 时无意义）。
  final String? priceUnit;

  /// 封面图 URL（可空＝无过审媒体）。
  final String? coverUrl;

  /// 发布时间（可空）。
  final DateTime? publishAt;

  /// 从 `cover_media` 子对象取封面 `url`（他人视角只出 pass 项）。
  ///
  /// 参数：[map] FavoriteItem 对象。
  /// 返回：String? 封面 URL；`cover_media` 缺失或为 null 时返回 null。
  /// 抛出：[ApiException.parse] `cover_media` 出现但非对象时。
  static String? _coverUrl(Map<String, Object?> map) {
    final cover = map['cover_media'];
    if (cover == null) return null;
    return optString(requireMap(cover, 'MediaItem'), 'url', 'MediaItem');
  }
}

/// 我的收藏分页响应 DTO（openapi `FavoritesResponse`）。
class FavoritesPageDto {
  /// 构造分页 DTO。
  const FavoritesPageDto({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET /favorites` 的 data 字段）。
  /// 返回：[FavoritesPageDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory FavoritesPageDto.fromJson(Object? json) {
    final map = requireMap(json, 'FavoritesResponse');
    return FavoritesPageDto(
      items: [
        for (final item in requireList(map, 'items', 'FavoritesResponse'))
          FavoriteItemDto.fromJson(item),
      ],
      total: requireInt(map, 'total', 'FavoritesResponse'),
      page: requireInt(map, 'page', 'FavoritesResponse'),
      pageSize: requireInt(map, 'page_size', 'FavoritesResponse'),
    );
  }

  /// 当前页收藏项。
  final List<FavoriteItemDto> items;

  /// 符合条件的总条数。
  final int total;

  /// 当前页码。
  final int page;

  /// 每页条数。
  final int pageSize;
}

/// 收藏/取消收藏结果 DTO（openapi `FavoriteResult`）。
class FavoriteResultDto {
  /// 构造结果 DTO。
  const FavoriteResultDto({required this.favorited});

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（收藏/取消端点的 data 字段）。
  /// 返回：[FavoriteResultDto]。
  /// 抛出：[ApiException.parse] `favorited` 缺失/非 bool 时。
  factory FavoriteResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'FavoriteResult');
    return FavoriteResultDto(favorited: requireBool(map, 'favorited', 'FavoriteResult'));
  }

  /// 操作后状态（true=已收藏，false=已取消）。
  final bool favorited;
}
