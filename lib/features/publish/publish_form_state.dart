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
import '../../domain/publish_completeness.dart';
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

  /// 模板字段加载中（[124] B3：`GET /templates/{leaf}` 未返回前禁提交，
  /// 防止用本地字段校验放行、提交时被服务端 precheck 打回）。
  ///
  /// **它不由 [PublishFormState.blocker] 返回**：blocker 是纯同步链，模板
  /// 加载是异步事态。该值由发布页在「已选分类且 loadedTemplate 未就位」
  /// 时于 blocker 之前合成（见 `publish_screen.dart`）。
  templateLoading('模板加载中…'),

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
    this.doorNumber = '',
    this.title = '',
    this.priceText = '',
    this.priceUnit,
    this.negotiable = false,
    this.description = '',
    this.templateValues = const {},
    this.loadedTemplate,
    this.imageCount = 0,
    this.contact = '',
    this.agreed = false,
  });

  final PublishKind kind;

  /// 已选叶子类目 ID（§13.2 `post.leaf_category_id`）。null 表示未选。
  final int? leafCategoryId;

  /// 是否已选位置。真实坐标待地图选点（见文件头）。
  final bool hasLocation;

  /// 门牌号（§9.8 条件二「位置到门牌号」）。
  ///
  /// **为什么要有一个手填框而不是只靠地图选点**：§9.8 的兜底列写明
  /// 「地址库无该门牌时，允许手填自由文本并视为达成，不卡用户」。
  /// 而本期没有高德 Key，「取当前定位门牌」拿不到真值 —— 若只留那个按钮，
  /// 🟢 档在本期将无人可达，完整度三档就退化成「只有 🟡 和 🔴」，
  /// 那么 §5.9 冲刺区与 §9.8 权益卡都没法验收。
  final String doorNumber;

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

  /// 服务端模板就位后的生效模板（[124] B3）：字段集合来自
  /// `GET /templates/{leaf}`，框架文案来自本地（合成唯一实现处在
  /// `publish_template_provider.dart`）。null 表示尚未加载（含拉取
  /// 尚未返回与从未发起两种，页面不区分——都按 [templatePending] 处理）。
  final PublishTemplate? loadedTemplate;

  final int imageCount;

  /// 联系方式（§5.4.1 第 8 段）。
  final String contact;

  /// 是否勾选发布协议（§5.8「协议未勾选 → 主按钮 Disabled」）。
  final bool agreed;

  /// 当前生效的模板（未选分类时为通用模板）。
  ///
  /// [loadedTemplate] 就位后优先取之（字段集合是服务端口径）；未就位时
  /// 回退本地查表 —— 标题提示 / 价格单位 / 描述引导三项框架文案契约
  /// 不下发，加载中也必须有值渲染，故 getter 永不返回 null。
  PublishTemplate get template =>
      loadedTemplate ??
      (leafCategoryId == null
          ? genericTemplate
          : templateForLeaf(leafCategoryId!));

  /// 模板字段是否等待服务端下发（[124] B3 的提交闸门判据）。
  ///
  /// 已选分类且 [loadedTemplate] 未就位即 true；未选分类不涉及模板
  /// 拉取，恒 false（通用模板无附加字段，无等待语义）。
  bool get templatePending =>
      leafCategoryId != null && loadedTemplate == null;

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

  /// 完整度判定（§9.8 三条件 → 三档，判定逻辑本身在 `CompletenessAssessment`）。
  ///
  /// 本 getter 只负责「把表单翻译成三个布尔」，档位映射与权益文案不在这里 ——
  /// §9.8 末条要求判定口径唯一，若这里也写一遍 `metCount >= 2 ? 黄 : 红`，
  /// 就成了第二处判定。
  CompletenessAssessment get completeness => CompletenessAssessment(
    // 必填项 100%：直接复用 blocker —— 它本就是「必填是否齐」的唯一判据。
    // 另写一套「必填计数」会出现「按钮能点但完整度说必填没齐」这种矛盾。
    requiredFieldsComplete: canSubmit,
    hasDoorNumber: doorNumber.trim().isNotEmpty,
    leafCategoryPrecise: _leafCategoryPrecise,
  );

  /// 三级类目是否精准命中（§9.8 条件三）。
  ///
  /// **不是简单判断「有没有选分类」**：§9.8 兜底列写明「若该二级类目下运营
  /// 尚未配置三级类目，则选到二级即视为精准命中（判定按该类目实际最深层级，
  /// 不因运营未配置而惩罚用户）」。本期 §2.4 的 48 个叶子全部是三级，
  /// 但这个判断必须按「实际最深层级」写 —— 否则将来运营加一个只有两级的
  /// 类目，那个类目下的用户会永远升不到 🟢，且没人能看出原因。
  bool get _leafCategoryPrecise {
    final id = leafCategoryId;
    if (id == null) return false;
    // 能在树里查到，说明选中的就是该分支的最深一层（`leafCategories`
    // 收集的就是各分支末端节点）。查不到 = 脏 ID，不算命中。
    return leafCategoryById(id) != null;
  }

  PublishFormState copyWith({
    PublishKind? kind,
    int? leafCategoryId,
    bool? hasLocation,
    String? doorNumber,
    String? title,
    String? priceText,
    String? priceUnit,
    bool? negotiable,
    String? description,
    Map<String, String>? templateValues,
    PublishTemplate? loadedTemplate,
    int? imageCount,
    String? contact,
    bool? agreed,
  }) {
    return PublishFormState(
      kind: kind ?? this.kind,
      leafCategoryId: leafCategoryId ?? this.leafCategoryId,
      hasLocation: hasLocation ?? this.hasLocation,
      doorNumber: doorNumber ?? this.doorNumber,
      title: title ?? this.title,
      priceText: priceText ?? this.priceText,
      priceUnit: priceUnit ?? this.priceUnit,
      negotiable: negotiable ?? this.negotiable,
      description: description ?? this.description,
      templateValues: templateValues ?? this.templateValues,
      loadedTemplate: loadedTemplate ?? this.loadedTemplate,
      imageCount: imageCount ?? this.imageCount,
      contact: contact ?? this.contact,
      agreed: agreed ?? this.agreed,
    );
  }

  /// 服务端模板就位后回写（[124] B3，由发布页在 provider 数据到达时调用）。
  ///
  /// 参数 [template] 合成后的模板（服务端字段 + 本地框架文案）。
  /// 返回：loadedTemplate 更新后的新快照；templateValues 保留 —— 加载中
  /// 页面渲染的是本地字段（同 key 时输入不丢），换分类才清值（见
  /// [withCategory]）。
  PublishFormState withTemplate(PublishTemplate template) {
    return copyWith(loadedTemplate: template);
  }

  /// 构造 PostDraft 契约载荷（[124] B4，`POST /posts/precheck` 用；
  /// B5 `POST /posts` 复用同一构造 —— 两个端点的载荷 schema 同源，
  /// 各写一份会出现 precheck 过了、createPost 传了不同字段的分叉）。
  ///
  /// 映射口径（契约 `PostDraft`，全字段非必填允许半成品预校验）：
  /// - `type`：supply→`resource`、demand→`demand`（契约 PostTypeEnum）；
  /// - `attributes`：只含当前模板字段键的非空值（空值不传键——
  ///   attributes 语义是「已填的动态属性」，空串值无意义）；
  /// - `lng`/`lat`/`address`：本轮无真实坐标（地图选点待高德 Key，
  ///   见 publish_screen 文件头），不传假值——precheck 对半成品开放，
  ///   服务端五项校验（敏感词/图片/禁发/资质/实名上限）均不依赖坐标；
  /// - `address_precise`：门牌号手填非空即 true（§9.8 条件二兜底口径）；
  /// - `media_ids`：媒体上传保持占位（说明文档裁定），恒空数组；
  /// - 派生字段（`l2_category_id`/`completeness_level`/`grid_id`/
  ///   `expire_at`/`version`）一律不传（契约：客户端传了也被忽略，
  ///   不传是对「服务端生成」的正向表达）。
  ///
  /// 返回：[Map] 契约 `PostDraft` 形态对象（可直接作请求体）。
  Map<String, Object?> postDraftPayload() {
    return <String, Object?>{
      'type': kind == PublishKind.supply ? 'resource' : 'demand',
      if (leafCategoryId != null) 'leaf_category_id': leafCategoryId,
      if (title.trim().isNotEmpty) 'title': title.trim(),
      if (description.trim().isNotEmpty) 'description': description.trim(),
      'attributes': <String, String>{
        for (final field in template.extraFields)
          if ((templateValues[field.key] ?? '').trim().isNotEmpty)
            field.key: templateValues[field.key]!.trim(),
      },
      'address_precise': doorNumber.trim().isNotEmpty,
      'media_ids': const <String>[],
      'contact_type': 'phone',
      if (contact.trim().isNotEmpty) 'contact_value': contact.trim(),
    };
  }

  /// 换分类后重置模板相关字段。
  ///
  /// **为什么不能用 `copyWith`**：换分类会换模板，旧模板的 `templateValues`
  /// 键在新模板里不存在。留着它们不会报错、也不显示，但会被一起提交入库
  /// （§13.2 `template_values` 是 JSON），成为查不出来的脏数据。
  /// 价格单位同理 —— 家政的「元/小时」在二手闲置模板里不是合法选项。
  ///
  /// `loadedTemplate` 同样不携带（构造器未传即 null）：新分类的字段集合
  /// 必须重新向 `/templates/{leaf}` 拉取，[templatePending] 恢复为 true。
  PublishFormState withCategory(int leafId) {
    final next = templateForLeaf(leafId);
    return PublishFormState(
      kind: kind,
      leafCategoryId: leafId,
      hasLocation: hasLocation,
      // 门牌号跟着位置走，与分类无关，故换分类时保留
      doorNumber: doorNumber,
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
    // topCategory 现为可空（详细设计 §10.4.1）。查不到大类时不加前缀，
    // 而不是兜一个「【求助】」—— 前缀会进标题落库，猜错等于替用户改文案。
    null => null,
  };
}
