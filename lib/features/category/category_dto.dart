/// 分类与模板契约 DTO（openapi.yaml `CategoryTree`/`CategoryNode`/`Template`/
/// `TemplateField` 四 schema 的逐字段手写映射，详设 §10.3）。
///
/// 为什么独立于 `lib/domain/category_tree.dart` / `publish_template.dart`
/// 另建一层：domain 模型承载本地渲染语义（大类色、`requiredCert` 四档、
/// 模板文案），契约 DTO 承载传输形态（snake_case 键、`level`/`sensitive`/
/// `banned`、字段类型五枚举）。两者字段并不一一对应——契约有 `level`/
/// `banned` 而本地没有，本地有 `requiredCert` 而契约不下发。混在一层
/// 会让「服务端违约字段」与「本地渲染兜底」共用同一条解析路径，出错时
/// 无法区分是哪一侧的缺陷。
///
/// 可空性纪律（详设 §10.3 / 编码规范 §5.2）：与 schema `required` 逐字
/// 对齐——required 字段缺失/类型不符抛 [ApiException.parse]（message 含
/// 实际收到值）；非 required 字段一律可空，**不用 `?? 默认值` 掩盖**，
/// 缺失语义由 DTO→domain 转换层落实，不在 DTO 内偷塞默认值。
library;

import 'package:zhaoyazhao/core/contract_json.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

/// 模板字段类型的契约枚举（openapi.yaml `TemplateField.type` 五值）。
///
/// 与 domain `TemplateFieldType`（text/multiline/number/select 四档）不合并：
/// 契约有 `multi_select`/`date` 而无 `multiline`，传输形态按契约建模，
/// 到 domain 的映射由转换层完成（B3 模板驱动接线时）。
enum TemplateFieldTypeDto {
  /// 单行文本
  text,

  /// 纯数字
  number,

  /// 单选（options 有值）
  select,

  /// 多选（options 有值）
  multiSelect,

  /// 日期
  date,
}

/// 契约字符串 → 字段类型枚举（显式 switch + default 降级，禁
/// `values.byName`，详设 §10.3）。
///
/// 参数：[value] 契约 `type` 字段原值。
/// 返回：对应枚举；**未知值降级 [TemplateFieldTypeDto.text]**——未知
///   字段类型渲染为单行文本，用户仍可填写提交，不阻断发布主流程（与
///   `supplyDemandFromApi` 同范式）；契约枚举增删须同步本 switch 与单测。
TemplateFieldTypeDto templateFieldTypeFromApi(String value) =>
    switch (value) {
      'text' => TemplateFieldTypeDto.text,
      'number' => TemplateFieldTypeDto.number,
      'select' => TemplateFieldTypeDto.select,
      'multi_select' => TemplateFieldTypeDto.multiSelect,
      'date' => TemplateFieldTypeDto.date,
      _ => TemplateFieldTypeDto.text,
    };

/// 分类树节点 DTO（openapi.yaml `CategoryNode`：required = id/name/level）。
class CategoryNodeDto {
  /// 构造分类树节点 DTO。
  const CategoryNodeDto({
    required this.id,
    required this.name,
    required this.level,
    this.icon,
    this.sensitive,
    this.banned,
    this.children,
  });

  /// 由信封 data 内的节点 JSON 构造（递归解析子节点）。
  ///
  /// 参数：[json] 信封 data 中的节点对象（拆信封后的值）。
  /// 返回：[CategoryNodeDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符、`level`
  ///   超出 1..3、可选字段类型不符时（均含实际收到值）。
  factory CategoryNodeDto.fromJson(Object? json) {
    final map = requireMap(json, 'CategoryNode');
    final level = requireInt(map, 'level', 'CategoryNode');
    // level 是结构属性（契约 enum [1,2,3]）：未知层级无法降级渲染，
    // 树会拼错，按服务端违约处理抛 parse（与字段类型未知值可降级不同）。
    if (level < 1 || level > 3) {
      throw ApiException.parse(
        'CategoryNode.level 应为 1..3，实际: $level',
      );
    }
    return CategoryNodeDto(
      id: requireInt(map, 'id', 'CategoryNode'),
      name: requireString(map, 'name', 'CategoryNode'),
      level: level,
      icon: optString(map, 'icon', 'CategoryNode'),
      sensitive: optBool(map, 'sensitive', 'CategoryNode'),
      banned: optBool(map, 'banned', 'CategoryNode'),
      children: _optChildren(map),
    );
  }

  /// 类目 ID（L3 与 L2 满足 `l2_id = l3_id DIV 100`）。
  final int id;

  /// 类目名。
  final String name;

  /// 层级（1/2/3，构造时已校验范围）。
  final int level;

  /// 图标（契约 nullable 且非 required：可缺失可为 JSON null）。
  final String? icon;

  /// 高敏标记（非 required）：true 表示发布需先过资质认证，否则 40302。
  final bool? sensitive;

  /// 禁发标记（非 required）：true 表示当前禁止发布，发布回 40303。
  final bool? banned;

  /// 子节点（非 required；契约「L3 无 children」，缺失即无子节点，
  /// 由转换层落实为空列表语义）。
  final List<CategoryNodeDto>? children;

  /// 序列化为契约 JSON 形态（本地缓存持久化用，[124] B2）。
  ///
  /// 键名与 [fromJson] 输入逐字一致（snake_case）；为 null 的可选字段
  /// **省略键**而非写 JSON null——[fromJson] 对「缺失」与「JSON null」
  /// 均解析为 null（`_opt*` 语义），往返一致且缓存体积更小。
  ///
  /// 返回：[Map] 契约形态节点对象（含递归序列化的子节点）。
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'level': level,
    if (icon != null) 'icon': icon,
    if (sensitive != null) 'sensitive': sensitive,
    if (banned != null) 'banned': banned,
    if (children != null)
      'children': [for (final child in children!) child.toJson()],
  };
}

/// 分类树全量数据 DTO（openapi.yaml `CategoryTree`：required =
/// version/categories）。
class CategoryTreeDto {
  /// 构造分类树 DTO。
  const CategoryTreeDto({required this.version, required this.categories});

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（版本一致时为 null，由 repository 层先判，
  ///   不会进入本函数）。
  /// 返回：[CategoryTreeDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory CategoryTreeDto.fromJson(Object? json) {
    final map = requireMap(json, 'CategoryTree');
    return CategoryTreeDto(
      version: requireString(map, 'version', 'CategoryTree'),
      categories: [
        for (final item in requireList(map, 'categories', 'CategoryTree'))
          CategoryNodeDto.fromJson(item),
      ],
    );
  }

  /// 分类树全局版本号（`YYYY-MM-DD.N` 字符串）。
  ///
  /// **刻意不校验 pattern**：版本协商只需「一致/不一致」的字符串比较
  /// （契约 489-505 行），客户端不解析其内部结构；校验 pattern 反而在
  /// 服务端格式演进时误拦。原样存储、原样回传。
  final String version;

  /// 一级类目列表（L1 → L2 → L3 嵌套在 [CategoryNodeDto.children]）。
  final List<CategoryNodeDto> categories;

  /// 序列化为契约 JSON 形态（本地缓存持久化用，[124] B2）。
  ///
  /// 与 [fromJson] 往返一致：缓存恢复路径与网络路径共用同一份解析校验
  /// （缓存损坏即[fromJson] 抛 [ApiException.parse]，由存储层按
  /// 「无缓存」降级，见 `CategoryTreeStore`）。
  ///
  /// 返回：[Map] 契约形态 `CategoryTree` 对象。
  Map<String, Object?> toJson() => <String, Object?>{
    'version': version,
    'categories': [for (final node in categories) node.toJson()],
  };
}

/// 叶子类目发布模板 DTO（openapi.yaml `Template`：required =
/// leaf_category_id/fields）。
class TemplateDto {
  /// 构造模板 DTO。
  const TemplateDto({required this.leafCategoryId, required this.fields});

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data。
  /// 返回：[TemplateDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory TemplateDto.fromJson(Object? json) {
    final map = requireMap(json, 'Template');
    return TemplateDto(
      leafCategoryId: requireInt(map, 'leaf_category_id', 'Template'),
      fields: [
        for (final item in requireList(map, 'fields', 'Template'))
          TemplateFieldDto.fromJson(item),
      ],
    );
  }

  /// 叶子类目 ID。
  final int leafCategoryId;

  /// 字段模板列表（驱动动态表单渲染；`required` 标记兼完整度
  /// `required_full` 判定依据）。
  final List<TemplateFieldDto> fields;
}

/// 模板字段 DTO（openapi.yaml `TemplateField`：required =
/// key/label/type/required）。
class TemplateFieldDto {
  /// 构造模板字段 DTO。
  const TemplateFieldDto({
    required this.key,
    required this.label,
    required this.type,
    required this.isRequired,
    this.options,
    this.unit,
    this.placeholder,
  });

  /// 由信封 data 内的字段对象构造。
  ///
  /// 参数：[json] 字段对象。
  /// 返回：[TemplateFieldDto]；`type` 未知值经 [templateFieldTypeFromApi]
  ///   降级 text 不抛错。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory TemplateFieldDto.fromJson(Object? json) {
    final map = requireMap(json, 'TemplateField');
    return TemplateFieldDto(
      key: requireString(map, 'key', 'TemplateField'),
      label: requireString(map, 'label', 'TemplateField'),
      type: templateFieldTypeFromApi(
        requireString(map, 'type', 'TemplateField'),
      ),
      isRequired: requireBool(map, 'required', 'TemplateField'),
      options: optStringList(map, 'options', 'TemplateField'),
      unit: optString(map, 'unit', 'TemplateField'),
      placeholder: optString(map, 'placeholder', 'TemplateField'),
    );
  }

  /// 字段键（落 `post.attributes` JSON 的一级键）。
  final String key;

  /// 字段名（展示文案）。
  final String label;

  /// 字段输入类型。
  final TemplateFieldTypeDto type;

  /// 是否必填（命名 `isRequired` 而非 `required`：避开 Dart 内建标识符，
  /// 语义亦更明确）。
  final bool isRequired;

  /// 候选值（仅 select/multi_select 有值；非 required，缺失为 null）。
  final List<String>? options;

  /// 单位（如「吨」；契约 nullable 且非 required）。
  final String? unit;

  /// 输入提示（契约 nullable 且非 required）。
  final String? placeholder;
}

// ---------------------------------------------------------------------------
// CategoryNode 专用解析（通用字段读取助手已上浮 lib/core/contract_json.dart
// —— post 域 DTO 复用后按反冗余纪律 §1.1 上浮，此处只留本域私有逻辑）。
// ---------------------------------------------------------------------------

/// 取可选子节点数组（CategoryNode 专用：元素递归走完整 DTO 解析）。
///
/// 参数：[map] 父节点对象（`children` 键）。
/// 返回：[List<CategoryNodeDto>?]；缺失/JSON null 为 null（L3 语义）。
/// 抛出：[ApiException.parse] `children` 出现但非数组、或任一子节点
///   解析失败时（递归抛出）。
List<CategoryNodeDto>? _optChildren(Map<String, Object?> map) {
  final value = map['children'];
  if (value == null) return null;
  if (value is! List) {
    throw ApiException.parse(
      'CategoryNode.children 应为数组或 null，实际: $value',
    );
  }
  return [for (final item in value) CategoryNodeDto.fromJson(item)];
}
