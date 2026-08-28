/// 详情页域模型（PRD §7.4.1 详情页 / §13.2 数据字典）。
///
/// **为什么与 [Listing] 分开而不是给它加字段**：列表一次拉几百条，详情一次拉一条。
/// 合成一个类会让列表接口被迫返回模板字段、描述、发布者信息，而 §12.1 明确
/// 「地图取数接口单次响应 ≤10KB」。分开对应 §12.3 里本就是两个接口这一事实。
///
/// **字段名对齐 §13.2**：`post` / `user` / `cert` 三张表的列名直接作为字段名，
/// 不做「更好听」的重命名 —— 客户端与服务端各叫各的，接口联调时每个字段
/// 都要查一次映射表，而映射表是最容易过期的文档。
library;

import 'listing.dart';
import 'listing_category.dart';

/// 信息完整度三档（PRD §9.8，对应 §13.2 `post.completeness_level`）。
enum CompletenessLevel {
  /// 🟢 完整：三条件全达成
  green('完整'),

  /// 🟡 半完整：三条件达成 2 个
  yellow('半完整'),

  /// 🔴 待补：三条件达成 ≤1 个
  red('待补');

  const CompletenessLevel(this.label);

  /// 档位文案（PRD §9.8 视觉标记列）。
  final String label;
}

/// 联系方式渠道（PRD §13.2 `post.contact_channel`，§7.4.2 二选一单轨）。
enum ContactChannel {
  phone('手机号'),
  wechat('微信号');

  const ContactChannel(this.label);

  final String label;
}

/// 发布者信息（PRD §7.4.1 发布者信任卡，对应 §13.2 `user` + `cert`）。
class Publisher {
  const Publisher({
    required this.id,
    required this.nickname,
    required this.realNameVerified,
    this.qualificationLabel,
  });

  final String id;
  final String nickname;

  /// 是否已完成个人实名（§13.2 `cert` 中 type=identity 且状态通过）。
  ///
  /// 用 bool 而非直接存 `cert` 记录：详情页只需回答「有没有」，
  /// 认证明细属 §4 信任体系页面的职责。
  final bool realNameVerified;

  /// 资质认证名称，如「家政服务资质」。无资质为 null。
  ///
  /// **不做「资质等级」或合并成信誉分**：PRD §2.5 技术建议明确「仅此二层
  /// 独立展示，不合并为统一信誉分」，这是产品红线不是实现细节。
  final String? qualificationLabel;
}

/// 模板字段的一项（PRD §7.4.1 模板字段区，对应 §13.2 `post.template_values`）。
///
/// 用「有序键值对列表」而非 Map：§7.7 要求「按序显示 key/value」，
/// 而 Dart 的 Map 字面量顺序虽然稳定，语义上并不承诺顺序，
/// 依赖它等于让展示顺序建立在一个未被承诺的实现细节上。
typedef TemplateField = ({String label, String value});

/// 一条信息的完整详情。
class ListingDetail {
  const ListingDetail({
    required this.listing,
    required this.description,
    required this.publisher,
    required this.completeness,
    required this.expireAt,
    required this.contactChannel,
    required this.contactMasked,
    this.categoryPath = const [],
    this.templateFields = const [],
    this.address,
    this.negotiable = false,
  });

  /// 复用列表模型承载共有字段，避免同一条信息在两个类里各存一份标题与坐标。
  final Listing listing;

  /// 描述正文（§13.2 `post.desc`）。
  final String description;

  final Publisher publisher;
  final CompletenessLevel completeness;

  /// 下架时间（§13.2 `post.expire_at`，默认 +7 天见 §5.11）。
  ///
  /// 存绝对时刻而非「剩余天数」：剩余天数在页面停留期间会过期，
  /// 而绝对时刻可以随时重算。
  final DateTime expireAt;

  final ContactChannel contactChannel;

  /// 脱敏后的联系方式，如 `138****8888`（PRD §7.7）。
  ///
  /// **完整值不在本模型中**：§14.3 规定「全系统仅 `/contact` 一个接口返回
  /// 完整值」，且 §7.7 要求「完整号码不写入前端初始状态」。若详情接口顺手
  /// 带上完整号码，前端不显示也照样能被抓包批量采集 —— 那正是反爬要防的。
  final String contactMasked;

  /// 三级分类路径，如 `['家政', '保洁', '日常保洁']`（§7.4.1 面包屑）。
  ///
  /// 与 [Listing.category] 的五大类并存：大类决定配色与聚合阈值（§6.4.2 /
  /// §6.15），三级路径决定模板与面包屑（§2.4）。二者用途不同，不是冗余。
  final List<String> categoryPath;

  final List<TemplateField> templateFields;

  /// 地址文案（§13.2 `post.address`，到门牌号影响完整度档见 §9.8）。
  final String? address;

  /// 是否可议价（§7.4.1 价格行的「⬜ 可议价」）。
  final bool negotiable;

  /// 剩余有效期天数（向上取整）。
  ///
  /// 参数 [now] 由调用方注入而非内部取 `DateTime.now()`：页面停留时不必重算，
  /// 且测试可固定输入。返回 0 表示已到期。
  int daysUntilExpire(DateTime now) {
    final diff = expireAt.difference(now);
    if (diff.isNegative) return 0;
    // 向上取整：剩 25 小时显示「2 天后下架」比「1 天」更安全 ——
    // 宁可让用户以为还早一点，也不要让人以为已经没了而放弃联系。
    return diff.inHours ~/ 24 + (diff.inHours % 24 > 0 ? 1 : 0);
  }

  /// 需求态标题前缀（PRD §7.4.3：由分类自动推导）。
  ///
  /// 资源态返回 null。前缀按大类映射，与 §7.4.3 列出的四种保持一致。
  String? get demandPrefix {
    if (listing.supplyDemand != SupplyDemand.demand) return null;
    return switch (listing.category) {
      ListingCategory.house => '【求租】',
      ListingCategory.vehicle => '【求搭】',
      ListingCategory.life => '【求购】',
      ListingCategory.work || ListingCategory.service => '【求助】',
    };
  }

  /// 标题（需求态自动带前缀）。
  String get displayTitle => '${demandPrefix ?? ''}${listing.title}';
}
