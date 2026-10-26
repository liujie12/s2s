/// 生效条件投影：把「持久筛选」与「本次搜索槽位」合成唯一一份当前条件。
///
/// 为什么需要它：改动前，「当前筛的是什么」被写了三遍 —— 摘要胶囊只读持久筛选、
/// 回执条只读搜索态、请求逐槽位优先搜索态再回落持久筛选。三处各读各的，
/// 于是同一句话可以同时出现两套「当前筛选」，而地图与列表也可能按不同条件取数。
///
/// 本文件是纯函数：同一个 `(filter, intent)` 必得同一个结果，可直接单测，
/// 也让「投影之外还有没有第二处回落」变成可被门禁扫描的判断题。
library;

import '../../domain/listing_category.dart';
import 'condition_slots.dart';
import 'discovery_filter.dart';
import 'discovery_query.dart';
import 'search_intent.dart';

/// 一个槽位当前值的来源。
enum ConditionSource {
  /// 来自持久筛选（跨搜索、跨视图保留）。
  persistent,

  /// 来自本次搜索。
  intent,
}

/// 条件带上的一枚 chip。
class ConditionChip {
  /// 构造一枚 chip。
  const ConditionChip({
    required this.slot,
    required this.label,
    required this.source,
    this.editable = false,
    this.deletable = true,
    this.index,
  });

  /// 所属槽位。
  final ConditionSlot slot;

  /// 展示文案（已含单位，如 `5km`、`≤2000 元`）。
  final String label;

  /// 值来自哪个源。
  final ConditionSource source;

  /// 是否可点开改值。
  final bool editable;

  /// 是否可删除。
  ///
  /// 只有「空档」的槽位不可删（例如供需未选），因为删掉它无法表达任何条件。
  final bool deletable;

  /// 类目槽位在意图类目列表中的下标；其他槽位为 null。
  final int? index;
}

/// 当前生效条件的完整快照。
///
/// 字段是「请求需要什么」而不是「界面需要什么」：地图的 `PinsQuery` 与列表的
/// `SearchQuery` 都从这里取，避免两页各自写一份回落规则。
class EffectiveFilter {
  /// 构造投影结果。
  const EffectiveFilter({
    required this.radius,
    required this.supplyDemand,
    required this.leafCategoryIds,
    required this.categoryLabels,
    required this.chips,
    required this.unresolvedLabels,
    this.priceMin,
    this.priceMax,
    this.anchorLat,
    this.anchorLng,
    this.anchorName,
    this.anchorSource,
    this.communityId,
    this.communityName,
    this.active = false,
  });

  /// 生效半径档。
  final SearchRadius radius;

  /// 生效供需集合。
  final Set<SupplyDemand> supplyDemand;

  /// 生效叶子类目 ID（已展开）。
  final List<int> leafCategoryIds;

  /// 生效类目显示名（与 [leafCategoryIds] 不必同长：持久来源用一级大类名）。
  final List<String> categoryLabels;

  /// 价格下限（元）。
  final int? priceMin;

  /// 价格上限（元）。
  final int? priceMax;

  /// 地点锚点纬度。
  final double? anchorLat;

  /// 地点锚点经度。
  final double? anchorLng;

  /// 地点名。
  final String? anchorName;

  /// 锚点来源（text/poi/long_press/current）。
  final String? anchorSource;

  /// 小区实体 ID。
  final String? communityId;

  /// 小区规范名。
  final String? communityName;

  /// 条件带要渲染的 chip（已排序）。
  final List<ConditionChip> chips;

  /// 未敢采用字段的展示名（灰态，不参与过滤）。
  final List<String> unresolvedLabels;

  /// 是否处于搜索态。
  final bool active;

  /// 设置上限时排除面议。
  ///
  /// 与解析侧口径一致：`priceExcludesNegotiable = priceMax != null`。
  bool get priceExcludesNegotiable => priceMax != null;

  /// 是否设置了任一侧价格。
  bool get hasPrice => priceMin != null || priceMax != null;

  /// 真实半径米数（地图客户端精裁用）；全城为 null。
  int? get radiusMeters => radius.km == null ? null : radius.km! * 1000;

  /// 该大类是否在生效类目里（面板胶囊选中态用）。
  ///
  /// 参数：[top] 一级大类；返回：其下任一叶子落在生效类目里即为真。
  bool includesCategory(ListingCategory top) {
    final List<int> ids = leafCategoryIdsFor({top});
    return ids.any(leafCategoryIds.contains);
  }

  /// 是否等于「全部分类」。
  bool get isAllCategories =>
      leafCategoryIds.length >= leafCategoryIdsFor(const <ListingCategory>{}).length;

  /// 是否没有任何收窄（用于零结果改写入口的判断）。
  bool get hasNoSlot =>
      supplyDemand.length == 2 &&
      leafCategoryIds.isEmpty &&
      !hasPrice &&
      communityId == null &&
      anchorLat == null;
}

/// 未敢采用字段的展示名。
///
/// 与契约 `unresolved_fields` 的取值一一对应；未知键原样展示，
/// 宁可见到一个英文键，也不要静默丢掉「没敢用」提示。
String unresolvedFieldLabel(String field) => switch (field) {
  'location' => '地点',
  'price' => '价格',
  'radius' => '范围',
  'category' => '分类',
  'post_type' => '供需',
  _ => field,
};

/// 投影：把两个来源合成当前生效条件。
///
/// **槽位三态**是本函数的核心：
/// - 意图里有值 → 用意图值（来源 `intent`）；
/// - 意图里标记为「显式清空」→ 该维不生效，**不回落**持久值；
/// - 意图里没有该槽位 → 回落持久筛选（来源 `persistent`）。
///
/// 缺第三态时，用户删掉搜索态的一枚 chip，它会立刻以持久值重新出现，
/// 删除看起来失灵。
///
/// 价格是例外：它是持久条件（R23），永远取持久值；解析产出的价格由门面在
/// 提交时镜像进持久筛选，投影不再单独判断来源。
///
/// 参数：[filter] 持久筛选；[intent] 本次搜索槽位（null 表示无搜索态）。
/// 返回：当前生效条件。
EffectiveFilter effectiveFilterOf(DiscoveryFilter filter, SearchIntent? intent) {
  final bool active = intent != null;
  final List<ConditionChip> chips = <ConditionChip>[];

  // 半径
  final bool radiusCleared = _isCleared(intent, ConditionSlot.radius);
  final SearchRadius radius;
  final ConditionSource radiusSource;
  if (radiusCleared) {
    // 显式清空半径 = 不再按距离收窄，即全城。
    radius = SearchRadius.city;
    radiusSource = ConditionSource.intent;
  } else if (intent?.radius != null) {
    radius = searchRadiusFromApi(intent!.radius!);
    radiusSource = ConditionSource.intent;
  } else {
    radius = filter.radius;
    radiusSource = ConditionSource.persistent;
  }
  chips.add(
    ConditionChip(
      slot: ConditionSlot.radius,
      label: radius.label,
      source: radiusSource,
      editable: true,
    ),
  );

  // 供需
  final bool supplyCleared = _isCleared(intent, ConditionSlot.supplyDemand);
  final Set<SupplyDemand> supplyDemand;
  final ConditionSource supplySource;
  final String? intentPostType = intent?.postType;
  if (supplyCleared) {
    // 供需维度不允许为空（空集等于「都不看」），删除即回到默认「都选」。
    supplyDemand = const {SupplyDemand.supply, SupplyDemand.demand};
    supplySource = ConditionSource.intent;
  } else if (intentPostType != null) {
    supplyDemand = {
      if (intentPostType == 'resource') SupplyDemand.supply,
      if (intentPostType == 'demand') SupplyDemand.demand,
    };
    supplySource = ConditionSource.intent;
  } else {
    supplyDemand = filter.supplyDemand;
    supplySource = ConditionSource.persistent;
  }
  chips.add(
    ConditionChip(
      slot: ConditionSlot.supplyDemand,
      label: _supplyLabel(supplyDemand),
      source: supplySource,
      editable: true,
    ),
  );

  // 类目
  final bool categoryCleared = _isCleared(intent, ConditionSlot.category);
  final List<int> leafCategoryIds;
  final List<String> categoryLabels;
  final ConditionSource categorySource;
  if (categoryCleared) {
    leafCategoryIds = const <int>[];
    categoryLabels = const <String>[];
    categorySource = ConditionSource.intent;
  } else if (intent != null && intent.leafCategoryIds.isNotEmpty) {
    leafCategoryIds = intent.leafCategoryIds;
    categoryLabels = intent.categoryLabels;
    categorySource = ConditionSource.intent;
  } else {
    leafCategoryIds = leafCategoryIdsFor(filter.categories);
    categoryLabels = [
      for (final ListingCategory c in ListingCategory.values)
        if (filter.categories.contains(c)) c.label,
    ];
    categorySource = ConditionSource.persistent;
  }
  if (categorySource == ConditionSource.intent) {
    for (int i = 0; i < categoryLabels.length; i++) {
      chips.add(
        ConditionChip(
          slot: ConditionSlot.category,
          label: categoryLabels[i],
          source: categorySource,
          editable: true,
          index: i,
        ),
      );
    }
  } else {
    chips.add(
      ConditionChip(
        slot: ConditionSlot.category,
        label: filter.isAllCategories
            ? '全部分类'
            : categoryLabels.join('/'),
        source: categorySource,
        editable: true,
      ),
    );
  }

  // 价格（持久条件）
  if (filter.hasPrice) {
    chips.add(
      ConditionChip(
        slot: ConditionSlot.price,
        label: filter.priceLabel,
        source: ConditionSource.persistent,
        editable: true,
      ),
    );
  }

  // 地点与小区：只来自搜索态，没有持久来源可回落。
  final bool anchorCleared = _isCleared(intent, ConditionSlot.anchor);
  final double? anchorLat = anchorCleared ? null : intent?.anchorLat;
  final double? anchorLng = anchorCleared ? null : intent?.anchorLng;
  final String? anchorName = anchorCleared ? null : intent?.anchorName;
  final String? anchorSource = anchorCleared ? null : intent?.anchorSource;
  final String? communityName = anchorCleared ? null : intent?.communityName;
  if (anchorName != null || anchorLat != null) {
    chips.add(
      ConditionChip(
        slot: ConditionSlot.anchor,
        label: anchorName ?? '地图选点',
        source: ConditionSource.intent,
      ),
    );
  }
  if (communityName != null) {
    chips.add(
      ConditionChip(
        slot: ConditionSlot.community,
        label: communityName,
        source: ConditionSource.intent,
        editable: true,
      ),
    );
  }

  return EffectiveFilter(
    radius: radius,
    supplyDemand: supplyDemand,
    leafCategoryIds: leafCategoryIds,
    categoryLabels: categoryLabels,
    priceMin: filter.priceMin,
    priceMax: filter.priceMax,
    anchorLat: anchorLat,
    anchorLng: anchorLng,
    anchorName: anchorName,
    anchorSource: anchorSource,
    communityId: anchorCleared ? null : intent?.communityId,
    communityName: communityName,
    chips: chips,
    unresolvedLabels: [
      for (final String field in intent?.unresolvedFields ?? const <String>[])
        unresolvedFieldLabel(field),
    ],
    active: active,
  );
}

/// 该槽位是否被显式清空。
bool _isCleared(SearchIntent? intent, ConditionSlot slot) =>
    intent?.clearedSlots.contains(slot) ?? false;

/// 供需 chip 文案。
String _supplyLabel(Set<SupplyDemand> selected) => switch (selected.length) {
  0 => '未选',
  2 => '资源+需求',
  _ => selected.first.label,
};
