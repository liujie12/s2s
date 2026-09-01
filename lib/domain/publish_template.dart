/// 发布模板引擎（PRD §5.4.3 模板字段差异表 / §5.7 实现逻辑 / §5.8 边界）。
///
/// **为什么模板是「按叶子类目查表」而不是每类写一个页面**：§5.4.3 的四类模板
/// 差异只在字段集合与文案上，版式完全一致。写四个页面等于把同一套版式抄四遍，
/// 之后改主按钮位置要改四处；而 §2.4 有 48 个叶子，照这个路子最终要写 48 个页面。
///
/// **为什么模板挂在二级而非叶子**：§5.4.3 的四行分别是「二手闲置 / 家政保洁 /
/// 拼车 / 全职招聘」—— 都是二级类目。同一二级下的叶子（如家政的日常保洁、
/// 深度保洁、开荒保洁）字段集合完全相同，按叶子配等于把同一份 Schema 抄三遍。
/// 故查表键取二级 ID，由叶子 ID 除 100 推出（`category_tree.dart` 的编号规则）。
///
/// **不做的两件事**：
/// ① **Schema 从服务端下发**（§12.3 `/categories/tree` 可带模板）—— 无服务端时
///    下发与硬编码的区别只是多一层解析，而解析代码没有真实响应可测；
/// ② **记忆机制**（§5.7「按 user_id + category_leaf_id 存最近一次发布值」）——
///    §5.7 明确「先拉云端，本地作 fallback」，云端不存在时只剩 fallback，
///    做出来是个单机草稿箱，与 PRD 描述的能力不是同一个东西。本轮在字段上
///    留出 `memoryHint` 展示位，让「【记忆带入】」的版面占位可被验收。
library;

import 'category_tree.dart';

/// 模板字段的输入类型（决定用哪种控件与哪套校验）。
enum TemplateFieldType {
  /// 单行文本
  text,

  /// 多行文本（描述类，带字数区间提示）
  multiline,

  /// 纯数字（价格、人数、空座数）
  number,

  /// 单选（新旧程度、取件方式等 §5.4.3「附加字段」列的选单）
  select,
}

/// 模板中的一个字段（§5.7「字段 key、label、类型、校验、placeholder、必填」）。
///
/// 用 record 而非 class 的判断：它没有行为，只有一组同时出现的数据，
/// 且要放进 const 列表里。但 record 无法写字段级注释，而这里每个字段
/// 都需要说明其 PRD 出处，故仍用 class。
class TemplateFieldSpec {
  const TemplateFieldSpec({
    required this.key,
    required this.label,
    required this.type,
    this.placeholder,
    this.required = false,
    this.options = const [],
    this.memoryHint,
    this.maxLength,
  });

  /// 存储键，对应 §13.2 `post.template_values` 的 JSON key。
  ///
  /// 用英文 key 而非直接用 label 作键：label 是会被产品改的文案
  /// （「价格」改成「报价」是一句话的事），而键一旦入库就不能改。
  final String key;

  /// 字段名，逐字取自 §5.4.1 / §5.4.3。
  final String label;

  final TemplateFieldType type;

  /// 输入提示，取自 §5.4.3「标题 placeholder」与「描述引导」两列。
  final String? placeholder;

  /// 是否必填。必填项未齐则主按钮禁用（§5.4.1 顶部栏「禁用直到必填齐全」）。
  final bool required;

  /// [TemplateFieldType.select] 的候选值。其余类型为空。
  final List<String> options;

  /// 记忆带入提示，如「上次：50 元/小时」（§5.4.1 的【记忆带入】行）。
  ///
  /// **本轮是演示值而非真记忆**：真记忆需云端（见文件头②）。留这个位是为了让
  /// 「记忆带入」这条产品主张的版面占位能被验收 —— 不留位，日后接上云端时
  /// 会发现每个字段都要重新排版。
  final String? memoryHint;

  /// 字数上限。null 表示不限。
  final int? maxLength;
}

/// 一个类目的完整模板（§5.7「按叶子类目 ID 映射模板 Schema」）。
class PublishTemplate {
  const PublishTemplate({
    required this.id,
    required this.titlePlaceholder,
    required this.priceUnits,
    required this.descriptionGuide,
    this.extraFields = const [],
  });

  /// 模板 ID，取 §5.4.3 的编号（如 `4.1` 二手闲置）或 `generic` 通用模板。
  final String id;

  /// 标题提示（§5.4.3「标题 placeholder」列）。
  final String titlePlaceholder;

  /// 价格单位候选（§5.7「模板 Schema 里定义 price_units 数组」）。
  ///
  /// 「面议」也放在这个数组里而不单做一个开关：§5.8「价格为空」这条边界写的是
  /// 「允许选『面议』不填数字」—— 它在产品语义上就是一个单位选项，
  /// 单独做开关会出现「勾了面议又填了数字」这种要额外规则去排除的组合。
  final List<String> priceUnits;

  /// 描述引导文案（§5.4.3「描述引导」列）。
  final String descriptionGuide;

  /// 模板特有字段（§5.4.3「附加字段」列）。
  final List<TemplateFieldSpec> extraFields;

  /// 是否为通用模板降级态（§5.8「模板缺配 → 降级为通用模板」）。
  bool get isGeneric => id == genericTemplateId;
}

/// 通用模板 ID。
const String genericTemplateId = 'generic';

/// 通用模板（§5.8「模板缺配 → 降级为『通用模板』，最少字段：标题+价格+描述+位置」）。
///
/// **它不是兜底摆设，而是 48 个叶子里 40 个的实际归宿**：§5.4.3 只给了 4 类示例，
/// 剩下的类目 PRD 并未定字段。此时给通用模板，比给一份我猜的字段集合更诚实 ——
/// 猜出来的字段会被当成 PRD 已定的规格，日后没人知道那是猜的。
const PublishTemplate genericTemplate = PublishTemplate(
  id: genericTemplateId,
  titlePlaceholder: '一句话说清你要发什么',
  priceUnits: ['元', '元/次', '元/月', '面议'],
  descriptionGuide: '请补充关键信息，填得越具体越容易被联系',
);

/// 二级类目 ID → 模板。键为 §2.4 的二级编号。
///
/// 四份模板逐字取自 §5.4.3 四行。**只做这四类**：PRD 给的就是这四行示例，
/// 其余走通用模板（见 [genericTemplate] 的注释）。
const Map<int, PublishTemplate> _templatesBySecondLevel = {
  // ── 4.1 二手闲置（§2.4 生活 › 二手闲置转让 = 401）──
  401: PublishTemplate(
    id: '4.1',
    titlePlaceholder: '【转让】品牌+物品',
    priceUnits: ['元', '面议'],
    descriptionGuide: '请说明：成色 / 使用时长 / 原价 / 自取方式',
    extraFields: [
      TemplateFieldSpec(
        key: 'condition',
        label: '新旧程度',
        type: TemplateFieldType.select,
        required: true,
        options: ['全新未拆', '几乎全新', '轻微使用痕迹', '功能正常有磨损'],
      ),
      TemplateFieldSpec(
        key: 'pickup',
        label: '取件方式',
        type: TemplateFieldType.select,
        options: ['仅自取', '可送到楼下', '可同城配送（买家付费）'],
      ),
    ],
  ),

  // ── 5.1 家政保洁（§2.4 服务 › 家政/保洁 = 501）──
  501: PublishTemplate(
    id: '5.1',
    titlePlaceholder: '【服务】家庭日常保洁',
    priceUnits: ['元/小时', '元/次', '元/㎡', '面议'],
    descriptionGuide: '请说明：可服务时间段 / 经验 / 有无工具 / 是否带清洁剂',
    extraFields: [
      TemplateFieldSpec(
        key: 'service_hours',
        label: '可服务时间段',
        type: TemplateFieldType.text,
        required: true,
        placeholder: '如：工作日 9:00-18:00',
        memoryHint: '上次：工作日 9:00-18:00',
      ),
      TemplateFieldSpec(
        key: 'own_tools',
        label: '是否自带工具',
        type: TemplateFieldType.select,
        options: ['自带全套工具与清洁剂', '自带工具，清洁剂由雇主提供', '不带工具'],
      ),
    ],
  ),

  // ── 3.1 拼车（§2.4 车辆 › 顺风车/拼车 = 301）──
  301: PublishTemplate(
    id: '3.1',
    titlePlaceholder: '【拼车】回龙观→中关村 工作日 8:00',
    priceUnits: ['元/人/次', '面议'],
    descriptionGuide: '请说明：起点终点 / 时间 / 行李空间 / 车型',
    extraFields: [
      TemplateFieldSpec(
        key: 'route',
        label: '起点 → 终点',
        type: TemplateFieldType.text,
        required: true,
        placeholder: '如：回龙观 → 中关村',
        memoryHint: '上次：回龙观 → 中关村',
      ),
      TemplateFieldSpec(
        key: 'depart_time',
        label: '出发时间',
        type: TemplateFieldType.text,
        required: true,
        placeholder: '如：工作日 8:00',
        memoryHint: '上次：工作日 8:00',
      ),
      TemplateFieldSpec(
        key: 'seats',
        label: '空座数',
        type: TemplateFieldType.number,
        required: true,
        placeholder: '1-6',
      ),
      TemplateFieldSpec(
        key: 'car_model',
        label: '车型',
        type: TemplateFieldType.text,
        placeholder: '如：轩逸（白色）',
        memoryHint: '上次：轩逸（白色）',
      ),
    ],
  ),

  // ── 1.1 全职招聘（§2.4 工作 › 全职招聘 = 101）──
  101: PublishTemplate(
    id: '1.1',
    titlePlaceholder: '【招聘】火锅店招服务员',
    priceUnits: ['元/月', '面议'],
    descriptionGuide: '请说明：人数 / 年龄 / 性别 / 包吃住否',
    extraFields: [
      TemplateFieldSpec(
        key: 'headcount',
        label: '招聘人数',
        type: TemplateFieldType.number,
        required: true,
        placeholder: '如：3',
      ),
      TemplateFieldSpec(
        key: 'work_hours',
        label: '工作时间',
        type: TemplateFieldType.text,
        required: true,
        placeholder: '如：10:00-22:00 单休',
        memoryHint: '上次：10:00-22:00 单休',
      ),
      TemplateFieldSpec(
        key: 'board',
        label: '食宿情况',
        type: TemplateFieldType.select,
        options: ['包吃包住', '包吃不包住', '包住不包吃', '不包吃住'],
      ),
    ],
  ),
};

/// 按叶子类目 ID 取模板（§5.7「按叶子类目 ID 映射模板 Schema」）。
///
/// 参数 [leafCategoryId] 取自 §13.2 `post.leaf_category_id`。
/// 返回：命中的模板；未配置或 ID 非法时返回 [genericTemplate]（§5.8「模板缺配」）。
///
/// **脏 ID 也走降级而不是抛错**：这个 ID 可能来自服务端下发或旧版本草稿，
/// 分类树改版后就会出现查不到的编号。抛错等于让一条旧草稿把发布页打崩，
/// 而降级到通用模板后用户仍能把信息发出去。
PublishTemplate templateForLeaf(int leafCategoryId) {
  final secondLevel = leafCategoryId ~/ 100;
  return _templatesBySecondLevel[secondLevel] ?? genericTemplate;
}

/// 该叶子发布前是否需要资质认证（§5.8「强制认证拦截」的判定依据）。
///
/// 参数 [leafCategoryId] 叶子 ID。返回所需认证类型，无需认证返回
/// [RequiredCert.none]。ID 非法时同样返回 `none` —— 判定「要不要拦」
/// 时宁可放过一条脏 ID，也不要把它拦在一个用户无法通过的认证前面
/// （那会变成死路：他没有这个类目，也就永远补不齐这项资质）。
RequiredCert requiredCertForLeaf(int leafCategoryId) {
  return leafCategoryById(leafCategoryId)?.requiredCert ?? RequiredCert.none;
}
