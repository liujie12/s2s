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
