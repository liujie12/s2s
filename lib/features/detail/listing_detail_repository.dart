/// 详情数据源（M4 阶段为本地样例数据）。
///
/// 详情由列表条目**派生**而非另起一套：两处数据若各自随机生成，会出现
/// 「列表显示 50 元/小时，点进去变成 120 元/月」这类不一致。用户看到的是
/// 数据在骗人，而排查时又会先怀疑是缓存或状态管理的问题。
///
/// 派生用的随机种子取自 id 而非全局 Random：同一条信息每次进入详情
/// 必须看到相同内容，否则来回切换时模板字段会自己变。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/listing.dart';
import '../../domain/listing_category.dart';
import '../../domain/listing_detail.dart';
import '../discovery/listing_repository.dart';

/// 按 id 取详情。
///
/// 返回 null 表示信息不存在（已下架或 id 非法）—— 由页面显示「信息不存在」，
/// 而不是在这里抛异常。用户点开一条刚被删除的信息属正常场景，不是错误。
final listingDetailProvider = Provider.family<ListingDetail?, String>((
  ref,
  id,
) {
  final all = ref.watch(allListingsProvider);
  // 用 where().firstOrNull 而非 firstWhere(orElse:)：后者要写一个假对象或
  // 抛异常，前者直接表达「可能没有」。
  final listing = all.where((l) => l.id == id).firstOrNull;
  if (listing == null) return null;
  return _deriveDetail(listing);
});

/// 从列表条目派生完整详情。
///
/// 参数 [listing] 为列表已有的共有字段，其余字段按 id 稳定派生。
ListingDetail _deriveDetail(Listing listing) {
  // id 的哈希做种子：同一条信息任何时候派生出的内容都一致。
  final seed = listing.id.hashCode.abs();

  return ListingDetail(
    listing: listing,
    description: _sampleDescription(listing.category, listing.supplyDemand),
    publisher: _samplePublisher(seed),
    // 三档按 seed 分布，保证三种视觉都能在样例里见到 ——
    // 只造 🟢 会让 🟡🔴 的排版直到接后端才第一次被看见。
    completeness: CompletenessLevel.values[seed % 3],
    // §5.11：默认有效期 7 天，自发布时刻起算。
    expireAt: listing.createdAt.add(const Duration(days: 7)),
    contactChannel: seed.isEven ? ContactChannel.phone : ContactChannel.wechat,
    contactMasked: seed.isEven
        ? '138****${8000 + seed % 1000}'
        : 'wx_h***${seed % 100}',
    categoryPath: _samplePath(listing.category),
    templateFields: _sampleTemplateFields(listing.category),
    address: _sampleAddress(seed),
    negotiable: seed % 3 == 0,
  );
}

/// 样例三级分类路径（PRD §2.4 三级树的一条真实分支）。
///
/// 真实路径应由 `category` 表按 `parent_id` 回溯得到（§13.2），
/// 分类树尚未建模前用固定分支占位 —— 目的是验证面包屑排版与截断。
List<String> _samplePath(ListingCategory category) => switch (category) {
  ListingCategory.work => ['工作', '兼职', '周末兼职'],
  ListingCategory.house => ['房屋', '整租', '一室一厅'],
  ListingCategory.vehicle => ['车辆', '拼车', '上下班拼车'],
  ListingCategory.life => ['生活', '闲置', '母婴用品'],
  ListingCategory.service => ['家政', '保洁', '日常保洁'],
};

/// 样例模板字段（PRD §7.4.1 模板字段区）。
///
/// 真实字段由 §5.7 模板 Schema 驱动（`template.schema` → 前端通用渲染器）。
/// 模板引擎属发布页范围，此处按大类给固定字段，用于验证「键值对区」的
/// 排版：长 value 换行、字段数量不定时的间距。
List<TemplateField> _sampleTemplateFields(ListingCategory category) =>
    switch (category) {
      ListingCategory.work => const [
        (label: '工作时间', value: '周六周日 9:00-18:00'),
        (label: '结算方式', value: '日结'),
        (label: '经验要求', value: '无经验可培训'),
      ],
      ListingCategory.house => const [
        (label: '户型', value: '1 室 1 厅 1 卫'),
        (label: '面积', value: '58 ㎡'),
        (label: '朝向', value: '南'),
        (label: '配套', value: '空调 / 洗衣机 / 宽带 / 独立卫浴'),
      ],
      ListingCategory.vehicle => const [
        (label: '出发时间', value: '工作日 8:00'),
        (label: '路线', value: '城西银泰 → 滨江网商路'),
        (label: '空位', value: '3 座'),
      ],
      ListingCategory.life => const [
        (label: '成色', value: '9 成新，使用约半年'),
        (label: '交易方式', value: '自提 / 同城可送'),
      ],
      ListingCategory.service => const [
        (label: '可服务时间', value: '工作日 9-18 点'),
        (label: '经验', value: '5 年以上'),
        (label: '工具', value: '自带清洁剂和全套工具'),
        (label: '可服务面积', value: '≤ 180 ㎡'),
      ],
    };

/// 样例描述正文。
///
/// 刻意写到接近三行：描述区要验证的是「长文本的行高与展开」，
/// 一句话的样例数据看不出段落排版是否舒适。
String _sampleDescription(ListingCategory category, SupplyDemand sd) {
  if (sd == SupplyDemand.demand) {
    return '本人常驻附近，希望能找到靠谱的资源。时间比较灵活，可以商量。'
        '如果条件合适希望能长期合作，谢谢。';
  }
  return switch (category) {
    ListingCategory.work =>
      '长期招周末兼职，工作内容简单，包一餐。'
          '按天结算，做满四天有额外补贴。有意向可以先电话沟通了解详情。',
    ListingCategory.house =>
      '房子采光很好，南向不临街，小区安静。'
          '家电齐全拎包入住，周边生活配套成熟，步行 10 分钟到地铁站。押一付三。',
    ListingCategory.vehicle =>
      '固定上下班路线，出发时间比较准时。'
          '车内禁烟，可以带小件行李。费用按人均油费算，不赚钱只求同路有个伴。',
    ListingCategory.life =>
      '家里孩子长大用不上了，一直保存得很好，无破损。'
          '可以先看货再决定，诚心要的价格好商量。',
    ListingCategory.service =>
      '本人从事家政保洁工作 5 年，自带全套清洁工具和清洁剂。'
          '擅长厨房油污和卫生间深度清洁，可洗油烟机。做事仔细，时间灵活。',
  };
}

/// 样例发布者。
Publisher _samplePublisher(int seed) {
  const names = ['王师傅', '李阿姨', '张同学', '陈先生', '刘女士'];
  const quals = [null, null, '家政服务资质', '房产经纪资质', null];
  return Publisher(
    id: 'user-${seed % 100}',
    nickname: names[seed % names.length],
    // 约 2/3 已实名：未实名的情况必须在样例里出现，
    // 否则「未实名」这一态的展示直到线上才第一次被验证。
    realNameVerified: seed % 3 != 0,
    qualificationLabel: quals[seed % quals.length],
  );
}

/// 样例地址。
///
/// 真实地址需逆地理编码（依赖高德 Key）。这里给到门牌级的固定文案，
/// 用于验证 §9.8「位置到门牌号」达成时的展示形态。
String _sampleAddress(int seed) {
  const places = ['文三路 100 号', '古翠路 8 号', '丰潭路 380 号', '教工路 18 号'];
  return places[seed % places.length];
}
