/// 探索页契约 DTO（[126] 前端段）：openapi.yaml `PinsCompactResponse`、
/// `/posts/search` 响应与 `PostCard` 的逐字段手写映射。
///
/// 为什么地图与列表的 DTO 同放一个文件：两者共用同一套筛选参数与
/// `category_version` 协商机制（契约 `/posts/search` description 明写
/// 「与 /map/pins 共用同一套筛选参数」），放一起便于对照两侧列名与可空性，
/// 避免只改一侧导致「地图有点、列表没有」这类口径漂移。
///
/// 字段读取助手引用 `core/contract_json.dart` 唯一实现处（禁私建副本）。
library;

import '../../core/contract_json.dart';
import '../../core/network/api_exception.dart';

/// pins 紧凑数组的契约固定列序（`PinsCompactResponse` description）。
///
/// 服务端 `schema` 字段会显式声明列序，客户端**以 schema 为准**解析；
/// 本常量是 schema 缺失时的兜底列序（契约 `required` 只列了 mode/total，
/// schema 理论可缺，但列序在 description 中是定死的，故兜底不是猜值）。
const List<String> kPinsSchemaDefault = <String>[
  'id',
  'lng',
  'lat',
  'category_id',
  'type',
  'completeness_level',
];

/// 地图图钉响应 DTO（openapi.yaml `PinsCompactResponse`；required = mode/total）。
///
/// 为压体积采用「schema + 二维数组」的紧凑格式（非常规对象数组）：
/// `pins` 每行按 `schema` 声明的列序排列，客户端据此解析，**不得按位置硬编码**。
class PinsCompactDto {
  /// 构造图钉响应 DTO。
  const PinsCompactDto({
    required this.mode,
    required this.total,
    required this.pins,
    required this.clusters,
    required this.categoryVersionStale,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET /map/pins` 的 data 字段）。
  /// 返回：[PinsCompactDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符、或 pins 行列数不足时。
  factory PinsCompactDto.fromJson(Object? json) {
    final map = requireMap(json, 'PinsCompactResponse');
    final schema =
        optStringList(map, 'schema', 'PinsCompactResponse') ?? kPinsSchemaDefault;
    final pinsRaw = map['pins'];
    final clustersRaw = map['clusters'];
    return PinsCompactDto(
      mode: requireString(map, 'mode', 'PinsCompactResponse'),
      total: requireInt(map, 'total', 'PinsCompactResponse'),
      // mode=cluster 时 pins 缺失；不造空数组以外的默认（缺失即无点）。
      pins: pinsRaw == null
          ? const []
          : [
              for (final row in requireList(map, 'pins', 'PinsCompactResponse'))
                MapPinDto.fromCompactRow(row, schema),
            ],
      clusters: clustersRaw == null
          ? const []
          : [
              for (final item
                  in requireList(map, 'clusters', 'PinsCompactResponse'))
                MapClusterDto.fromJson(item),
            ],
      categoryVersionStale:
          optBool(map, 'category_version_stale', 'PinsCompactResponse') ?? false,
    );
  }

  /// 聚合模式：`pin`（单点，客户端 Dart 侧聚合）或 `cluster`（服务端预聚合）。
  final String mode;

  /// 命中总数（`pins`/`clusters` 为按模式裁剪后的结果）。
  final int total;

  /// 单点图钉（仅 `mode=pin` 时有值）。
  final List<MapPinDto> pins;

  /// 服务端预聚合簇（仅 `mode=cluster` 时有值）。
  final List<MapClusterDto> clusters;

  /// 分类树版本已过期：客户端须异步刷新分类树并清空本地 Pin 缓存（不报错、不阻断）。
  final bool categoryVersionStale;

  /// 是否单点模式。
  bool get isPinMode => mode == 'pin';

  /// 是否聚合模式。
  bool get isClusterMode => mode == 'cluster';
}

/// 单点图钉 DTO（`PinsCompactResponse.pins` 的一行，6 列）。
class MapPinDto {
  /// 构造单点图钉 DTO。
  const MapPinDto({
    required this.id,
    required this.lng,
    required this.lat,
    required this.leafCategoryId,
    required this.typeCode,
    required this.completenessLevel,
  });

  /// 由紧凑数组的一行 + 列序声明构造。
  ///
  /// 参数：
  ///   [row]    紧凑行（JSON 数组，元素为 integer/number）；
  ///   [schema] 列序声明（服务端下发或 [kPinsSchemaDefault]）。
  /// 返回：[MapPinDto]。
  /// 抛出：[ApiException.parse] 行非数组、列数不足、schema 缺必需列、或单元格类型不符时。
  factory MapPinDto.fromCompactRow(Object? row, List<String> schema) {
    if (row is! List) {
      throw ApiException.parse('PinsCompactResponse.pins 行应为数组，实际: $row');
    }
    final index = <String, int>{
      for (var i = 0; i < schema.length; i++) schema[i]: i,
    };
    for (final key in kPinsSchemaDefault) {
      if (!index.containsKey(key)) {
        throw ApiException.parse(
          'PinsCompactResponse.schema 缺少必需列 $key，实际: $schema',
        );
      }
    }
    if (row.length < schema.length) {
      throw ApiException.parse(
        'PinsCompactResponse.pins 行列数(${row.length})少于 schema(${schema.length})，行: $row',
      );
    }
    return MapPinDto(
      id: _intCell(row, index['id']!, 'id'),
      lng: _doubleCell(row, index['lng']!, 'lng'),
      lat: _doubleCell(row, index['lat']!, 'lat'),
      leafCategoryId: _intCell(row, index['category_id']!, 'category_id'),
      typeCode: _intCell(row, index['type']!, 'type'),
      completenessLevel:
          _intCell(row, index['completeness_level']!, 'completeness_level'),
    );
  }

  /// 帖子 ID（契约 int64）。
  final int id;

  /// GCJ-02 经度。
  final double lng;

  /// GCJ-02 纬度。
  final double lat;

  /// 叶子类目 ID（一级大类由 `topCategoryOf` 查表得出）。
  final int leafCategoryId;

  /// 供需态整数码：0=resource（资源）/1=demand（需求）。
  ///
  /// 保持 int 不在此映射枚举：本地映射唯一实现处是
  /// `supplyDemandFromCompact`（详细设计 §10.4.2），本层只承载契约值。
  final int typeCode;

  /// 完整度档位（0/1/2）。
  final int completenessLevel;
}

/// 服务端预聚合簇 DTO（`PinsCompactResponse.clusters[]`）。
class MapClusterDto {
  /// 构造聚合簇 DTO。
  const MapClusterDto({
    required this.lng,
    required this.lat,
    required this.count,
    this.categoryId,
  });

  /// 由信封 data 内的簇对象构造。
  ///
  /// 参数：[json] `clusters[]` 元素。
  /// 返回：[MapClusterDto]。
  /// 抛出：[ApiException.parse] required 字段（lng/lat/count）缺失/类型不符时。
  factory MapClusterDto.fromJson(Object? json) {
    final map = requireMap(json, 'PinsCluster');
    final lng = optDouble(map, 'lng', 'PinsCluster');
    final lat = optDouble(map, 'lat', 'PinsCluster');
    if (lng == null || lat == null) {
      throw ApiException.parse('PinsCluster.lng/lat 缺失，实际: $map');
    }
    return MapClusterDto(
      lng: lng,
      lat: lat,
      count: requireInt(map, 'count', 'PinsCluster'),
      categoryId: optInt(map, 'category_id', 'PinsCluster'),
    );
  }

  /// 簇中心 GCJ-02 经度。
  final double lng;

  /// 簇中心 GCJ-02 纬度。
  final double lat;

  /// 簇内帖子数（映射为聚合 Marker 的尺寸档）。
  final int count;

  /// 簇内主导类目（用于图标着色）；可空。
  final int? categoryId;
}

/// 列表检索分页响应 DTO（openapi.yaml `/posts/search` 的 data；
/// required = items/total/page/page_size）。
class SearchPostsPageDto {
  /// 构造分页响应 DTO。
  const SearchPostsPageDto({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.categoryVersionStale,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET /posts/search` 的 data 字段）。
  /// 返回：[SearchPostsPageDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory SearchPostsPageDto.fromJson(Object? json) {
    final map = requireMap(json, 'SearchPostsPage');
    return SearchPostsPageDto(
      items: [
        for (final item in requireList(map, 'items', 'SearchPostsPage'))
          PostCardDto.fromJson(item),
      ],
      total: requireInt(map, 'total', 'SearchPostsPage'),
      page: requireInt(map, 'page', 'SearchPostsPage'),
      pageSize: requireInt(map, 'page_size', 'SearchPostsPage'),
      categoryVersionStale:
          optBool(map, 'category_version_stale', 'SearchPostsPage') ?? false,
    );
  }

  /// 当前页列表项。
  final List<PostCardDto> items;

  /// 命中总条数（分页终止判定：「没有更多了」）。
  final int total;

  /// 当前页码（从 1 起）。
  final int page;

  /// 每页条数。
  final int pageSize;

  /// 分类树版本已过期（语义同 [PinsCompactDto.categoryVersionStale]）。
  final bool categoryVersionStale;
}

/// 列表卡片项 DTO（openapi.yaml `PostCard`；required = id/type/title/completeness_level）。
///
/// **不含完整联系方式**：契约 description 明确，这是安全边界而非疏漏。
class PostCardDto {
  /// 构造列表卡片 DTO。
  const PostCardDto({
    required this.id,
    required this.type,
    required this.title,
    required this.completenessLevel,
    this.leafCategoryId,
    this.l2CategoryId,
    this.summary,
    this.coverUrl,
    this.price,
    this.priceUnit,
    this.lng,
    this.lat,
    this.distanceM,
    this.publishAt,
  });

  /// 由信封 data 内的列表项对象构造。
  ///
  /// 参数：[json] `GET /posts/search` 的 `data.items[]` 元素。
  /// 返回：[PostCardDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory PostCardDto.fromJson(Object? json) {
    final map = requireMap(json, 'PostCard');
    return PostCardDto(
      id: requireInt(map, 'id', 'PostCard'),
      type: requireString(map, 'type', 'PostCard'),
      title: requireString(map, 'title', 'PostCard'),
      completenessLevel: requireInt(map, 'completeness_level', 'PostCard'),
      leafCategoryId: optInt(map, 'leaf_category_id', 'PostCard'),
      l2CategoryId: optInt(map, 'l2_category_id', 'PostCard'),
      summary: optString(map, 'summary', 'PostCard'),
      coverUrl: optString(map, 'cover_url', 'PostCard'),
      // int 值（如 5500）JSON 反序列化后是 int，故 price 用 num 承接。
      price: optDouble(map, 'price', 'PostCard'),
      priceUnit: optString(map, 'price_unit', 'PostCard'),
      lng: optDouble(map, 'lng', 'PostCard'),
      lat: optDouble(map, 'lat', 'PostCard'),
      distanceM: optInt(map, 'distance_m', 'PostCard'),
      publishAt: optDateTime(map, 'publish_at', 'PostCard'),
    );
  }

  /// 帖子 ID（契约 int64）。
  final int id;

  /// 供需态（`resource`/`demand`，字符串枚举）。
  final String type;

  /// 标题。
  final String title;

  /// 完整度档位（0/1/2）。
  final int completenessLevel;

  /// 叶子类目 ID（一级大类由 `topCategoryOf` 查表得出）。
  final int? leafCategoryId;

  /// 二级类目 ID。
  final int? l2CategoryId;

  /// 描述摘要。
  final String? summary;

  /// 封面 URL（仅 `audit_status=pass` 的封面）。
  final String? coverUrl;

  /// 价格（元）；null = 面议。PRD §6.4.3 要求列表卡片展示价格，故契约已补该字段。
  final double? price;

  /// 价格单位；[price] 为 null 时无意义。
  final String? priceUnit;

  /// GCJ-02 经度。
  final double? lng;

  /// GCJ-02 纬度。
  final double? lat;

  /// 距基准点距离（米，服务端按请求的 lng/lat 计算）；可为空。
  final int? distanceM;

  /// 发布时间；可为空（契约非 required）。
  final DateTime? publishAt;
}

/// 读取紧凑行中的整数值单元格。
///
/// 契约 `pins` 元素类型为 `oneOf[integer, number]`，JSON 反序列化后
/// 整数值可能是 int，也可能是 double（如 `1.0`）。两者都接受，但**非整数值
/// 一律判违约**：`completeness_level=1.5` 这类值若被 `toInt()` 静默截断，
/// 会得到一个看起来合法的档位，缺陷将无声通过。
int _intCell(List<Object?> row, int index, String column) {
  final value = row[index];
  if (value is int) return value;
  if (value is double && value == value.roundToDouble()) return value.toInt();
  throw ApiException.parse(
    'PinsCompactResponse.pins.$column 应为整数，实际: $value',
  );
}

/// 读取紧凑行中的数值单元格（整数按 double 承接）。
double _doubleCell(List<Object?> row, int index, String column) {
  final value = row[index];
  if (value is num) return value.toDouble();
  throw ApiException.parse(
    'PinsCompactResponse.pins.$column 应为数值，实际: $value',
  );
}
