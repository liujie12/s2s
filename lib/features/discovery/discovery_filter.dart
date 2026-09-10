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
    this.keyword = '',
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

  /// 搜索关键词（PRD §6.4.1 导航栏搜索框）。
  ///
  /// 与范围/供需/分类是「与」关系，不互相覆盖。
  final String keyword;

  /// 是否为全部分类。
  bool get isAllCategories => categories.isEmpty;

  /// 摘要胶囊回显文案（PRD §6.4.1：收起态须回显当前筛的是什么）。
  ///
  /// 有关键词时优先显示关键词而非分类 —— PRD §6.4.1 明确要求，
  /// 否则摘要说「全部分类」而搜索框里写着「租房」，两处自相矛盾。
  String get summaryLabel {
    final String supplyDemandPart = switch (supplyDemand.length) {
      0 => '未选',
      2 => '资源+需求',
      _ => supplyDemand.first.label,
    };
    final String lastPart = keyword.isNotEmpty
        ? '关键词「$keyword」'
        : isAllCategories
        ? '全部分类'
        : categories.map((c) => c.label).join('/');
    return '${radius.label} · $supplyDemandPart · $lastPart';
  }

  DiscoveryFilter copyWith({
    SearchRadius? radius,
    Set<SupplyDemand>? supplyDemand,
    Set<ListingCategory>? categories,
    String? keyword,
  }) {
    return DiscoveryFilter(
      radius: radius ?? this.radius,
      supplyDemand: supplyDemand ?? this.supplyDemand,
      categories: categories ?? this.categories,
      keyword: keyword ?? this.keyword,
    );
  }
}

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

  /// 设置搜索关键词；传空串即清空（对应搜索框右侧叉号）。
  void setKeyword(String keyword) {
    state = state.copyWith(keyword: keyword.trim());
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
