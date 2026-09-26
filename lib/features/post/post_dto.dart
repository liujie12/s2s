/// post 域契约 DTO（[124]/[125] 前端段 / B4）：openapi.yaml
/// `PrecheckResult` / `PrecheckBlock` 两 schema 的逐字段手写映射。
///
/// 与 category_dto 同构的分工：契约 DTO 只承载传输形态（snake_case 键、
/// 可空性与 schema `required` 逐字对齐），本地行为语义（五码动作映射）
/// 在页面层，不进 DTO。字段读取助手引用 `core/contract_json.dart`
/// 唯一实现处（B4 从 category_dto 上浮）。
library;

import 'package:zhaoyazhao/core/contract_json.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

/// 发布前置校验结果 DTO（openapi.yaml `PrecheckResult`：required =
/// passed/blocks）。
class PrecheckResultDto {
  /// 构造校验结果 DTO。
  const PrecheckResultDto({
    required this.passed,
    required this.blocks,
    this.completenessLevel,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`POST /posts/precheck` 的 data 字段）。
  /// 返回：[PrecheckResultDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory PrecheckResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'PrecheckResult');
    return PrecheckResultDto(
      passed: requireBool(map, 'passed', 'PrecheckResult'),
      blocks: [
        for (final item in requireList(map, 'blocks', 'PrecheckResult'))
          PrecheckBlockDto.fromJson(item),
      ],
      // 契约 int enum [0,1,2]。**不映射本地档位模型**：本字段是服务端
      // 预演算值（description「供客户端提前展示完整度提示」），本轮页面
      // 完整度提示用本地 `PublishFormState.completeness`，此值留字段不消费；
      // 校验范围外的整数也原样保留，不替服务端拦。
      completenessLevel: optInt(map, 'completeness_level', 'PrecheckResult'),
    );
  }

  /// true 表示无阻断项，可直接提交发布。
  final bool passed;

  /// 全部阻断项（一次性给全，契约语义「不逐条打断用户」）。
  final List<PrecheckBlockDto> blocks;

  /// 服务端预演算的完整度等级（0/1/2；非 required，本轮留字段不消费）。
  final int? completenessLevel;
}

/// 发布前置校验阻断项 DTO（openapi.yaml `PrecheckBlock`：required =
/// code/message）。
class PrecheckBlockDto {
  /// 构造阻断项 DTO。
  const PrecheckBlockDto({
    required this.code,
    required this.message,
    this.field,
  });

  /// 由信封 data 内的阻断项对象构造。
  ///
  /// 参数：[json] `blocks[]` 数组元素。
  /// 返回：[PrecheckBlockDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory PrecheckBlockDto.fromJson(Object? json) {
    final map = requireMap(json, 'PrecheckBlock');
    return PrecheckBlockDto(
      code: requireInt(map, 'code', 'PrecheckBlock'),
      message: requireString(map, 'message', 'PrecheckBlock'),
      field: optString(map, 'field', 'PrecheckBlock'),
    );
  }

  /// 阻断类型码（契约枚举：40901 敏感词 / 40902 图片 / 40303 禁发 /
  /// 40302 资质 / 40304 未实名上限）。
  ///
  /// **保持 int 不映射 [ApiErrorCode]**：那是链上错误码域（信封 code →
  /// 行为五类），本字段是校验项类型标识，复用数值但语义不同；映射动作
  /// 由页面层 switch 五码完成。
  final int code;

  /// 可直接呈现的中文提示（契约原文），页面逐字展示、不重写。
  final String message;

  /// 关联字段名（契约 nullable：非 required，供定位具体表单项）。
  final String? field;
}

/// 发布成功响应 DTO（[125] B5，`POST /posts` 响应 = 契约 `PostDetail`）。
///
/// 只解析本端点消费的 required 8 字段；`PostDetail` 的可选项
/// （category_path/media/contact_mask 等）属详情页域，待对应条目扩展，
/// 不在本端点预建（预留字段不造数据）。
class PostCreatedDto {
  /// 构造发布成功 DTO。
  const PostCreatedDto({
    required this.id,
    required this.type,
    required this.leafCategoryId,
    required this.l2CategoryId,
    required this.title,
    required this.status,
    required this.version,
    required this.completenessLevel,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`POST /posts` 的 data 字段）。
  /// 返回：[PostCreatedDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory PostCreatedDto.fromJson(Object? json) {
    final map = requireMap(json, 'PostDetail');
    return PostCreatedDto(
      id: requireInt(map, 'id', 'PostDetail'),
      type: requireString(map, 'type', 'PostDetail'),
      leafCategoryId: requireInt(map, 'leaf_category_id', 'PostDetail'),
      l2CategoryId: requireInt(map, 'l2_category_id', 'PostDetail'),
      title: requireString(map, 'title', 'PostDetail'),
      status: requireString(map, 'status', 'PostDetail'),
      version: requireInt(map, 'version', 'PostDetail'),
      // 契约 int enum [0,1,2]，int32；服务端 STORED 生成列产出
      completenessLevel: requireInt(
        map,
        'completeness_level',
        'PostDetail',
      ),
    );
  }

  /// 帖子 ID（int64；发布后由服务端生成）。
  final int id;

  /// 供需态（`resource`/`demand`，回显入参）。
  final String type;

  /// 叶子类目 ID（回显入参）。
  final int leafCategoryId;

  /// 二级类目 ID（服务端派生，STORED 生成列）。
  final int l2CategoryId;

  /// 标题（回显入参）。
  final String title;

  /// 状态（新建即 `active`，先发后审）。
  final String status;

  /// 乐观锁版本（初始 0）。
  final int version;

  /// 完整度等级（0/1/2，服务端三条件达成数映射）。
  final int completenessLevel;
}

/// 帖子作者摘要 DTO（openapi.yaml `AuthorBrief`；[127] 详情出参）。
///
/// 严格遵循 `user` 对外视图白名单：仅 id/nickname/avatar_url/realname_status，
/// 不含 phone_mask 等敏感列。映射到域模型 [Publisher] 时 `realname_status`
/// 四态坍缩为「是否通过实名」布尔（[127] §10.4 语义迁移）。
class PostAuthorDto {
  /// 构造作者摘要 DTO。
  const PostAuthorDto({
    required this.id,
    required this.nickname,
    this.avatarUrl,
    required this.realnameStatus,
    required this.qualificationBadges,
  });

  /// 由信封 data 内的 author 对象构造。
  ///
  /// 参数：[json] `PostDetail.author` 对象。
  /// 返回：[PostAuthorDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory PostAuthorDto.fromJson(Object? json) {
    final map = requireMap(json, 'AuthorBrief');
    return PostAuthorDto(
      id: requireInt(map, 'id', 'AuthorBrief'),
      nickname: requireString(map, 'nickname', 'AuthorBrief'),
      avatarUrl: optString(map, 'avatar_url', 'AuthorBrief'),
      realnameStatus: requireString(map, 'realname_status', 'AuthorBrief'),
      qualificationBadges:
          optStringList(map, 'qualification_badges', 'AuthorBrief') ?? const [],
    );
  }

  /// 用户 ID。
  final int id;

  /// 昵称。
  final String nickname;

  /// 头像 URL（可空）。
  final String? avatarUrl;

  /// 实名状态（none/pending/passed/rejected）。
  final String realnameStatus;

  /// 资质徽章（Batch1 恒空，cert 空壳无数据源）。
  final List<String> qualificationBadges;
}

/// 帖子详情 DTO（openapi.yaml `PostDetail`；[127] 详情页接线）。
///
/// 只解析详情页消费的字段；`version`/`status`/`l2_category_id`/`category_path`/
/// `contact_mask`/`media` 等属其它端点的消费面，不在本 DTO 预建（预留字段不造数据）。
/// 映射到域模型 [ListingDetail] 在 `post_detail_provider.dart` 完成（§10.4 语义迁移）。
class PostDetailDto {
  /// 构造帖子详情 DTO。
  const PostDetailDto({
    required this.id,
    required this.type,
    required this.leafCategoryId,
    required this.title,
    this.price,
    this.priceUnit,
    this.description,
    required this.attributes,
    required this.lng,
    required this.lat,
    this.address,
    required this.completenessLevel,
    required this.publishAt,
    required this.expireAt,
    required this.author,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET /posts/{id}` 的 data 字段）。
  /// 返回：[PostDetailDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory PostDetailDto.fromJson(Object? json) {
    final map = requireMap(json, 'PostDetail');

    final attributesRaw = map['attributes'];
    final attributes = attributesRaw == null
        ? <String, Object?>{}
        : attributesRaw is Map
        ? attributesRaw.cast<String, Object?>()
        : throw ApiException.parse(
            'PostDetail.attributes 应为对象，实际: $attributesRaw');

    return PostDetailDto(
      id: requireInt(map, 'id', 'PostDetail'),
      type: requireString(map, 'type', 'PostDetail'),
      leafCategoryId: requireInt(map, 'leaf_category_id', 'PostDetail'),
      title: requireString(map, 'title', 'PostDetail'),
      price: optDouble(map, 'price', 'PostDetail'),
      priceUnit: optString(map, 'price_unit', 'PostDetail'),
      description: optString(map, 'description', 'PostDetail'),
      attributes: attributes,
      lng: optDouble(map, 'lng', 'PostDetail') ??
          (throw ApiException.parse('PostDetail.lng 缺失')),
      lat: optDouble(map, 'lat', 'PostDetail') ??
          (throw ApiException.parse('PostDetail.lat 缺失')),
      address: optString(map, 'address', 'PostDetail'),
      completenessLevel: requireInt(map, 'completeness_level', 'PostDetail'),
      publishAt: _requireDateTime(map, 'publish_at', 'PostDetail'),
      expireAt: _requireDateTime(map, 'expire_at', 'PostDetail'),
      author: PostAuthorDto.fromJson(map['author']),
    );
  }

  /// 帖子 ID。
  final int id;

  /// 供需态（`resource`/`demand`）。
  final String type;

  /// 叶子类目 ID。
  final int leafCategoryId;

  /// 标题。
  final String title;

  /// 价格（元）；null=面议。
  final double? price;

  /// 价格单位；price 为 null 时无意义。
  final String? priceUnit;

  /// 描述正文（可空）。
  final String? description;

  /// 动态属性（键=模板字段 key，值=字段值）。
  final Map<String, Object?> attributes;

  /// GCJ-02 经度。
  final double lng;

  /// GCJ-02 纬度。
  final double lat;

  /// 门牌号地址（可空）。
  final String? address;

  /// 完整度等级（0/1/2）。
  final int completenessLevel;

  /// 发布时间。
  final DateTime publishAt;

  /// 到期时间。
  final DateTime expireAt;

  /// 作者摘要。
  final PostAuthorDto author;
}

/// 解析必填 date-time 字段（RFC3339 UTC，服务端保证合法）。
///
/// 参数：[map] 父对象；[key] 契约键；[owner] 契约类型名。
/// 返回：[DateTime] 解析结果。
/// 抛出：[ApiException.parse] 缺失或非合法 ISO8601 时（含实际值）。
DateTime _requireDateTime(Map<String, Object?> map, String key, String owner) {
  final value = map[key];
  if (value is! String) {
    throw ApiException.parse('$owner.$key 缺失或非 String，实际: $value');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw ApiException.parse('$owner.$key 非合法 ISO8601 时间，实际: $value');
  }
  return parsed;
}
