/// 发布表单状态与校验（PRD §5.4.1 顶部栏「禁用直到必填齐全」/ §5.8 边界表）。
///
/// **为什么校验单独成类而不是写在页面 setState 里**：§5.8 的边界有八条
/// （价格为空、媒体上限、协议未勾、位置超范围…），它们决定的是同一个结果 ——
/// 主按钮能不能点。散在页面里意味着这八条规则只能靠手点去验，而其中
/// 「未实名每日 1 条」这类根本点不出来。抽成纯数据类后可逐条单测。
///
/// **不含媒体与位置的真实值**：媒体依赖 §13.2 `post_media` 与 CDN（详情页同因），
/// 地图选点依赖高德 Key。这两项在表单里以「是否已选」的布尔位参与校验，
/// 让「必填齐全才启用」这条规则可以被完整验证，而具体上传与选点是下一层的事。
library;

import '../../domain/category_tree.dart';
import '../../domain/listing_category.dart';
import '../../domain/publish_template.dart';

/// 发布类型（§5.4.1 胶囊切换「发布资源 / 发布需求」，对应 §13.2 `post.type`）。
enum PublishKind {
  /// 我有，可提供
  supply('发布资源'),

  /// 我要，求提供
  demand('发布需求');

  const PublishKind(this.label);

  final String label;
}

/// 主按钮被禁用的具体原因（§5.4.1「禁用直到必填齐全」的可解释化）。
///
/// **为什么要具名而不是只返回 bool**：一个灰按钮不告诉用户差什么，用户
/// 只能一格格猜。§5.4.1 只写了「禁用」，但禁用而不说原因是把校验规则
/// 藏起来让用户去试 —— 与登录页 `AuthFailure` 同一取向（条目 [71] 三）。
enum PublishBlocker {
  /// 未选叶子分类（§5.4.1 第 1 段）
  noCategory('请先选择分类'),

  /// 未选位置（§5.4.1 第 2 段）
  noLocation('请选择位置'),

  /// 标题为空（§5.4.1 第 3 段）
  noTitle('请填写标题'),

  /// 价格既没填数字也没选「面议」（§5.8「价格为空」）
  noPrice('请填写价格，或选择「面议」'),

  /// 描述为空（§5.4.1 第 5 段）
  noDescription('请填写描述'),

  /// 模板必填项未齐（§5.4.3「附加字段」中标必填的）
  templateFieldMissing('模板必填项未填完'),

  /// 联系方式为空（§5.4.1 第 8 段）
  noContact('请填写联系方式'),

  /// 协议未勾选（§5.8「协议未勾选 → 主按钮 Disabled」）
  agreementUnchecked('请勾选并同意发布协议'),

  /// 媒体超上限（§5.8「图片 ≤ 9，视频 ≤ 3」）
  tooManyMedia('图片最多 9 张');

  const PublishBlocker(this.message);

  /// 给用户看的文案。
  final String message;
}

/// 图片数量上限（§5.8「媒体数量上限：图片 ≤ 9」）。
///
/// 字面量而非从别处 import：这是 PRD 明写的契约数字，按原则 134，
/// 契约值必须至少有一处用字面量钉死并有断言直接比对。
const int kMaxImageCount = 9;

/// 描述建议字数区间（§5.4.1 第 5 段「建议 30-200 字」）。
///
/// 叫「建议」就不是必填校验 —— 只作提示，不参与 [PublishFormState.blocker]。
/// 把建议做成硬限制是把产品的软引导偷偷升级成门槛。
const int kDescriptionSuggestMin = 30;
const int kDescriptionSuggestMax = 200;

/// 默认有效期天数（§5.11「默认 7 天，不提供其他可选值」）。
const int kDefaultValidDays = 7;

/// 发布表单的一份完整快照。
///
/// 做成不可变类 + `copyWith`，而不是让页面持有一堆可变字段：校验要看的是
/// 「所有字段的组合」，可变字段意味着校验时机散落在每个 onChanged 里，
/// 而漏掉一个 onChanged 的表现是「填完了按钮还是灰的」这类无从复现的报告。
class PublishFormState {
  const PublishFormState({
    this.kind = PublishKind.supply,
    this.leafCategoryId,
    this.hasLocation = false,
    this.title = '',
    this.priceText = '',
    this.priceUnit,
    this.negotiable = false,
    this.description = '',
    this.templateValues = const {},
    this.imageCount = 0,
    this.contact = '',
    this.agreed = false,
  });

  final PublishKind kind;

  /// 已选叶子类目 ID（§13.2 `post.leaf_category_id`）。null 表示未选。
  final int? leafCategoryId;

  /// 是否已选位置。真实坐标待地图选点（见文件头）。
  final bool hasLocation;

  final String title;

  /// 价格输入的原文而非 num：用户输入过程中会出现 `5.` 这种中间态，
  /// 提前转 num 会让输入框在打字时跳字。转换只在提交时做一次。
  final String priceText;

  /// 已选价格单位，取自 [PublishTemplate.priceUnits]。
  final String? priceUnit;

  /// 是否可议价（§5.4.1 第 4 段「⬜ 可议价」）。
  ///
  /// 与「面议」单位并存且不同：可议价 = 有标价但可谈；面议 = 不标价。
  /// §5.8 只把「面议」当作免填数字的出口，故这里可议价不影响校验。
  final bool negotiable;

  final String description;

  /// 模板附加字段的值，key 对应 [TemplateFieldSpec.key]。
  final Map<String, String> templateValues;

  final int imageCount;

  /// 联系方式（§5.4.1 第 8 段）。
  final String contact;

  /// 是否勾选发布协议（§5.8「协议未勾选 → 主按钮 Disabled」）。
  final bool agreed;

  /// 当前生效的模板（未选分类时为通用模板）。
  PublishTemplate get template => leafCategoryId == null
      ? genericTemplate
      : templateForLeaf(leafCategoryId!);

  /// 价格是否已交代清楚 —— 填了数字，或选了「面议」。
  ///
  /// §5.8：「允许选『面议』不填数字；其他情况必须填数字」。
  bool get priceSettled {
    if (priceUnit == '面议') return true;
    final value = num.tryParse(priceText.trim());
    return value != null && value > 0;
  }

  /// 阻塞主按钮的第一个原因，null 表示可以发布。
  ///
  /// 返回「第一个」而非全部：一次抛八条提示等于没提示。顺序按 §5.4.1 的
  /// 表单段落顺序，用户按提示往下填就是自然的填写顺序。
  PublishBlocker? get blocker {
    if (leafCategoryId == null) return PublishBlocker.noCategory;
    if (!hasLocation) return PublishBlocker.noLocation;
    if (title.trim().isEmpty) return PublishBlocker.noTitle;
    if (!priceSettled) return PublishBlocker.noPrice;
    if (description.trim().isEmpty) return PublishBlocker.noDescription;

    // 模板必填项：未选分类时 template 是通用模板（无附加字段），故这一段
    // 只在选了分类后才真正生效，不会与 noCategory 抢先。
    for (final field in template.extraFields) {
      if (!field.required) continue;
      if ((templateValues[field.key] ?? '').trim().isEmpty) {
        return PublishBlocker.templateFieldMissing;
      }
    }

    if (imageCount > kMaxImageCount) return PublishBlocker.tooManyMedia;
    if (contact.trim().isEmpty) return PublishBlocker.noContact;
    if (!agreed) return PublishBlocker.agreementUnchecked;
    return null;
  }

  /// 是否可提交。
  bool get canSubmit => blocker == null;

  /// 该分类发布前需要的资质（§5.8「强制认证拦截」）。
  ///
  /// 未选分类返回 [RequiredCert.none]：没有分类就无从判断需要什么资质。
  RequiredCert get requiredCert => leafCategoryId == null
      ? RequiredCert.none
      : requiredCertForLeaf(leafCategoryId!);

  /// 描述字数提示（§5.4.1「已填 68 字，建议 30-200 字」）。
  String get descriptionHint =>
      '已填 ${description.trim().length} 字，建议 $kDescriptionSuggestMin-$kDescriptionSuggestMax 字';

  PublishFormState copyWith({
    PublishKind? kind,
    int? leafCategoryId,
    bool? hasLocation,
    String? title,
    String? priceText,
    String? priceUnit,
    bool? negotiable,
    String? description,
    Map<String, String>? templateValues,
    int? imageCount,
    String? contact,
    bool? agreed,
  }) {
    return PublishFormState(
      kind: kind ?? this.kind,
      leafCategoryId: leafCategoryId ?? this.leafCategoryId,
      hasLocation: hasLocation ?? this.hasLocation,
      title: title ?? this.title,
      priceText: priceText ?? this.priceText,
      priceUnit: priceUnit ?? this.priceUnit,
      negotiable: negotiable ?? this.negotiable,
      description: description ?? this.description,
      templateValues: templateValues ?? this.templateValues,
      imageCount: imageCount ?? this.imageCount,
      contact: contact ?? this.contact,
      agreed: agreed ?? this.agreed,
    );
  }

  /// 换分类后重置模板相关字段。
  ///
  /// **为什么不能用 `copyWith`**：换分类会换模板，旧模板的 `templateValues`
  /// 键在新模板里不存在。留着它们不会报错、也不显示，但会被一起提交入库
  /// （§13.2 `template_values` 是 JSON），成为查不出来的脏数据。
  /// 价格单位同理 —— 家政的「元/小时」在二手闲置模板里不是合法选项。
  PublishFormState withCategory(int leafId) {
    final next = templateForLeaf(leafId);
    return PublishFormState(
      kind: kind,
      leafCategoryId: leafId,
      hasLocation: hasLocation,
      title: title,
      priceText: priceText,
      // 新模板的第一个单位作默认值，避免出现「没有单位的价格」这种半截状态
      priceUnit: next.priceUnits.first,
      negotiable: negotiable,
      description: description,
      templateValues: const {},
      imageCount: imageCount,
      contact: contact,
      agreed: agreed,
    );
  }
}

/// 需求态标题前缀（§7.4.3：由分类自动推导）。
///
/// 与 `ListingDetail.demandPrefix` 同一份口径，但这里的输入是叶子 ID
/// 而非已建好的详情模型 —— 发布时还没有那个模型。
///
/// 参数 [kind] 发布类型，[leafCategoryId] 叶子 ID（可空）。
/// 返回：需求态返回前缀如「【求租】」，资源态或未选分类返回 null。
String? demandPrefixFor(PublishKind kind, int? leafCategoryId) {
  if (kind != PublishKind.demand || leafCategoryId == null) return null;
  final node = leafCategoryById(leafCategoryId);
  if (node == null) return null;
  return switch (node.topCategory) {
    ListingCategory.house => '【求租】',
    ListingCategory.vehicle => '【求搭】',
    ListingCategory.life => '【求购】',
    ListingCategory.work || ListingCategory.service => '【求助】',
  };
}
