/// 发现筛选态（PRD §6.4.1 收起口径 / §6.4.3 列表页）。
///
/// 为什么放在 `features/discovery/` 而不是 `features/map/`：PRD §10.1 明确
/// 「列表页与地图共享同一套筛选与范围状态」。若把状态挂在地图页下，列表页要么
/// import 地图模块，要么自己再存一份 —— 后者会导致两页筛选结果对不上，
/// 而这种不一致用户一眼看得见（地图 3 个 Pin、列表 12 条）。
///
/// 状态本身刻意不含「结果数据」，只含筛选条件。结果由数据层按条件派生，
/// 混在一起会让「改了条件但忘了重算结果」变成可能。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../domain/listing_category.dart';

/// 可选范围档位（PRD §6.4.1 ASCII 图：范围 1 3 [5] 10 全城）。
///
/// 用枚举而非任意 double：范围是离散档位不是连续滑块，允许任意值会让
/// 摘要胶囊的回显文案（「5km · ...」）需要处理 4.7km 这种不该存在的输入。
enum SearchRadius {
  km1(1),
  km3(3),
  km5(5),
  km10(10),

  /// 全城：不做距离过滤。
  city(null);

  const SearchRadius(this.km);

  /// 半径公里数；全城为 null。
  final int? km;

  /// 摘要胶囊与范围条的显示文案。
  String get label => km == null ? '全城' : '${km}km';
}

/// 搜索半径：本地枚举 → 契约字符串（详细设计 §10.4.3）。
///
/// 契约 `RadiusEnum` 是**字符串**枚举 `['1','3','5','10','city']`，不是整数 ——
/// 因为它要容纳 `'city'` 这个非数值档。本地则用 `int?` 表示，`null` 代表全城
/// （不做距离过滤）。两侧对「全城」的编码方式不同，必须显式映射。
///
/// **`km?.toString() ?? 'city'` 这一行是整个映射的要点。** 若写成
/// `km.toString()`，全城档会得到字面量 `"null"`：服务端按 §16.2 的规则回
/// `40001`（缓存键五要素不允许兜底），而客户端报错文案只会说「参数错误」，
/// 不会告诉你是哪个参数 —— 排查成本极高。
///
/// [r] 本地半径档位
///
/// 返回：契约要求的 `radius` 参数值
String toApiRadius(SearchRadius r) => r.km?.toString() ?? 'city';

/// 搜索半径：契约字符串 → 本地枚举（详细设计 §10.4.3）。
///
/// 显式 switch 而非按 `km` 反查：`'city'` 在本地对应的是 `km == null`，
/// 按值反查要为它单开一条分支，写出来的代码比直接 switch 更长也更绕。
///
/// [raw] 契约 `radius` 值，取值 `'1'` / `'3'` / `'5'` / `'10'` / `'city'`
///
/// 返回：对应的本地档位
///
/// 抛出：[ApiException] —— 出现契约外的值
SearchRadius searchRadiusFromApi(String raw) => switch (raw) {
  '1' => SearchRadius.km1,
  '3' => SearchRadius.km3,
  '5' => SearchRadius.km5,
  '10' => SearchRadius.km10,
  'city' => SearchRadius.city,
  _ => throw ApiException.parse('未知 radius: $raw'),
};

/// 发现页筛选条件。
///
/// 不可变类 + copyWith：状态对象若可变，Riverpod 无法靠引用比较判断变化，
/// 会出现「改了字段但 UI 不刷新」。
class DiscoveryFilter {
  const DiscoveryFilter({
    this.radius = SearchRadius.km5,
    this.supplyDemand = const {SupplyDemand.supply, SupplyDemand.demand},
    this.categories = const {},
    this.priceMin,
    this.priceMax,
  });

  /// 范围档位。默认 5km —— PRD §6.4.1 ASCII 图中 `[5]` 为选中态。
  final SearchRadius radius;

  /// 供需筛选。PRD §6.4.1「⦿ 资源 ○ 需求（可都选）」，故用集合而非单选。
  ///
  /// 空集视为「都不看」，会得到空结果。这是用户的显式选择，不做「空即全选」的
  /// 兜底 —— 兜底会让用户取消掉最后一项时看到全部结果，与其操作意图相反。
  final Set<SupplyDemand> supplyDemand;

  /// 分类筛选。**空集 = 全部分类**（对应分类栏的「全部」）。
  ///
  /// 这里与 [supplyDemand] 的空集语义刻意不同：分类栏有显式的「全部」按钮，
  /// 用空集表示它是最直接的映射；而供需只有两个胶囊，没有「全部」这一档。
  final Set<ListingCategory> categories;

  /// 价格下限（元）；null 表示不限下界。
  ///
  /// 价格是**持久条件**：与半径、供需、分类同源，默认不过滤，可被手动设置，
  /// 不随一次语义搜索结束而消失。
  final int? priceMin;

  /// 价格上限（元）；null 表示不限上界。
  ///
  /// 上限存在时排除面议，与语义解析产出的价格口径一致（`priceExcludesNegotiable`）。
  final int? priceMax;

  /// 是否设置了任一侧价格。
  bool get hasPrice => priceMin != null || priceMax != null;

  /// 是否为全部分类。
  bool get isAllCategories => categories.isEmpty;

  /// 摘要回显文案（PRD §6.4.1：须回显当前筛的是什么）。
  ///
  /// 价格段只在设置了任一侧时出现，避免默认状态下多出一段无信息文本。
  String get summaryLabel {
    final String supplyDemandPart = switch (supplyDemand.length) {
      0 => '未选',
      2 => '资源+需求',
      _ => supplyDemand.first.label,
    };
    final String categoryPart = isAllCategories
        ? '全部分类'
        : categories.map((c) => c.label).join('/');
    final List<String> parts = [
      radius.label,
      supplyDemandPart,
      categoryPart,
      if (hasPrice) priceLabel,
    ];
    return parts.join(' · ');
  }

  /// 价格的显示文案：区间 / 单侧上限 / 单侧下限。
  String get priceLabel => switch ((priceMin, priceMax)) {
    (final int min, final int max) => '$min–$max 元',
    (null, final int max) => '≤$max 元',
    (final int min, null) => '≥$min 元',
    _ => '',
  };

  /// 复制并替换字段。
  ///
  /// 价格用 `Object?` 哨兵而不是 `int?`：`null` 本身是有效值（取消该侧过滤），
  /// 用 `int?` 参数无法区分「不修改」与「显式清空」，删除价格条件就会失效。
  DiscoveryFilter copyWith({
    SearchRadius? radius,
    Set<SupplyDemand>? supplyDemand,
    Set<ListingCategory>? categories,
    Object? priceMin = _unset,
    Object? priceMax = _unset,
  }) {
    return DiscoveryFilter(
      radius: radius ?? this.radius,
      supplyDemand: supplyDemand ?? this.supplyDemand,
      categories: categories ?? this.categories,
      priceMin: identical(priceMin, _unset) ? this.priceMin : priceMin as int?,
      priceMax: identical(priceMax, _unset) ? this.priceMax : priceMax as int?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DiscoveryFilter &&
      other.radius == radius &&
      _sameSet(other.supplyDemand, supplyDemand) &&
      _sameSet(other.categories, categories) &&
      other.priceMin == priceMin &&
      other.priceMax == priceMax;

  @override
  int get hashCode => Object.hash(
    radius,
    Object.hashAllUnordered(supplyDemand),
    Object.hashAllUnordered(categories),
    priceMin,
    priceMax,
  );
}

/// `copyWith` 的「未传该参数」哨兵。
const Object _unset = Object();

/// 集合值相等。
///
/// 不引 `flutter/foundation` 的 `setEquals`：本文件是纯状态层，保持只依赖
/// Riverpod 可让它不被 widget 层绑定，也便于单测直接构造。
bool _sameSet<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.containsAll(b);

/// 筛选态的读写入口。
class DiscoveryFilterNotifier extends Notifier<DiscoveryFilter> {
  @override
  DiscoveryFilter build() => const DiscoveryFilter();

  /// 设置范围档位。
  void setRadius(SearchRadius radius) {
    state = state.copyWith(radius: radius);
  }

  /// 切换某个供需项的选中状态。
  void toggleSupplyDemand(SupplyDemand value) {
    final next = Set<SupplyDemand>.from(state.supplyDemand);
    next.contains(value) ? next.remove(value) : next.add(value);
    state = state.copyWith(supplyDemand: next);
  }

  /// 切换某个分类的选中状态。
  void toggleCategory(ListingCategory value) {
    final next = Set<ListingCategory>.from(state.categories);
    next.contains(value) ? next.remove(value) : next.add(value);
    state = state.copyWith(categories: next);
  }

  /// 回到「全部分类」。
  void clearCategories() {
    state = state.copyWith(categories: const {});
  }

  /// 设置价格区间；任一侧传 null 即取消该侧过滤。
  ///
  /// 只做「写入」，不做区间合法性判断：非法值由调用方（价格输入层）就地拦下，
  /// 避免状态层静默改写用户输入。
  void setPriceRange({int? min, int? max}) {
    state = state.copyWith(priceMin: min, priceMax: max);
  }

  /// 设置供需集合（门面用；面板的胶囊仍走 [toggleSupplyDemand]）。
  ///
  /// 参数：[value] 目标集合；返回：无。
  void setSupplyDemand(Set<SupplyDemand> value) {
    state = state.copyWith(supplyDemand: {...value});
  }

  /// 设置一级大类集合（门面用；空集 = 全部分类）。
  ///
  /// 参数：[value] 目标集合；返回：无。
  void setCategories(Set<ListingCategory> value) {
    state = state.copyWith(categories: {...value});
  }

  /// 整体替换（撤销回滚用）。
  ///
  /// 参数：[value] 快照里的筛选态；返回：无。
  void replace(DiscoveryFilter value) {
    state = value;
  }
}

/// 地图页与列表页共享的筛选态。
final discoveryFilterProvider =
    NotifierProvider<DiscoveryFilterNotifier, DiscoveryFilter>(
      DiscoveryFilterNotifier.new,
    );

/// 筛选面板展开态。
class FilterPanelExpandedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  void toggle() => state = !state;

  void open() => state = true;

  void close() => state = false;
}

/// 筛选面板是否展开（PRD §6.4.1 收起口径：默认收起）。
///
/// 与 [discoveryFilterProvider] 分开：展开与否是**视图状态**，切页即可丢弃；
/// 筛选条件是**业务状态**，两页共享且要跨页保持。混在一起会让列表页莫名其妙地
/// 继承地图页的展开状态，而列表页根本不适用收起（PRD §6.4.1 末条）。
final filterPanelExpandedProvider =
    NotifierProvider<FilterPanelExpandedNotifier, bool>(
      FilterPanelExpandedNotifier.new,
    );
