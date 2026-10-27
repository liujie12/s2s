/// 生效条件的唯一读点。
///
/// 地图请求、条件带、筛选面板、列表页都只读它；它们不再各自 watch
/// `discoveryFilterProvider` 与 `searchIntentProvider` 再自己回落。
///
/// 为什么用 `Provider` 而不是在页面里算：页面内联计算等于每个读点一份回落规则，
/// 而「两页对同一条件给出不同结果」正是本轮要消除的缺陷。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/listing_category.dart';
import 'condition_slots.dart';
import 'discovery_filter.dart';
import 'discovery_query.dart';
import 'effective_filter.dart';
import 'search_intent.dart';

/// 当前生效条件。
final effectiveFilterProvider = Provider<EffectiveFilter>((ref) {
  final DiscoveryFilter filter = ref.watch(discoveryFilterProvider);
  final SearchIntentState intentState = ref.watch(searchIntentProvider);
  return effectiveFilterOf(filter, intentState.intent);
});

/// 筛选面板的「分类显式选中」投影。
///
/// 面板要画的是「用户到底明确选了什么」，而不是生效条件里展开后的结果：
/// 全部分类时 `EffectiveFilter.leafCategoryIds` 会展开成全部叶子，直接拿来
/// 画选中态会把「全部」误画成全选。
///
/// 为什么放在本文件：`lib/features` 下只有本文件与门面允许读两个源（同源门禁
/// `test/architecture/single_source_test.dart`），面板自己算就是第二个读点。
class ExplicitCategorySelection {
  /// 构造投影。
  const ExplicitCategorySelection({
    this.leafIds = const {},
    this.wholeTopCategory,
  });

  /// 显式选中的叶子 ID 集合（选中整类时为其全部叶子）。
  final Set<int> leafIds;

  /// 持久筛选恰好「只选了一个大类、且没有单叶子」时的大类；其余情况为 null。
  ///
  /// 二级面板的「全部服务」用它判断「已经整类选中」，避免重复写入同一状态。
  final ListingCategory? wholeTopCategory;

  /// 是否没有显式选中任何分类。
  bool get isEmpty => leafIds.isEmpty;
}

/// 分类显式选中投影。
///
/// 取值优先级：意图叶子 → 持久叶子 → 持久整类（展开为叶子）→ 空集。
final explicitCategorySelectionProvider = Provider<ExplicitCategorySelection>((
  ref,
) {
  final DiscoveryFilter filter = ref.watch(discoveryFilterProvider);
  final SearchIntent? intent = ref.watch(searchIntentProvider).intent;
  final ListingCategory? wholeTop =
      filter.categories.length == 1 && filter.leafCategoryIds.isEmpty
      ? filter.categories.first
      : null;

  if (intent != null &&
      !intent.isCleared(ConditionSlot.category) &&
      intent.leafCategoryIds.isNotEmpty) {
    return ExplicitCategorySelection(leafIds: intent.leafCategoryIds.toSet());
  }
  if (filter.leafCategoryIds.isNotEmpty) {
    return ExplicitCategorySelection(leafIds: filter.leafCategoryIds.toSet());
  }
  if (filter.categories.isNotEmpty) {
    return ExplicitCategorySelection(
      leafIds: leafCategoryIdsFor(filter.categories).toSet(),
      wholeTopCategory: wholeTop,
    );
  }
  return const ExplicitCategorySelection();
});

/// 一次搜索的进度态（忙碌 / 失败 / 没听懂）。
///
/// 为什么单独出一个 Provider：条件带与语音面板都要显示这三态，但它们是纯展示，
/// 不该各自去读「槽位卡」这个实现细节。集中在这里，读点纪律才守得住。
class SearchStatus {
  /// 构造状态。
  const SearchStatus({
    this.busy = false,
    this.error,
    this.noUnderstand = false,
  });

  /// 是否正在解析。
  final bool busy;

  /// 最近一次解析失败的用户文案。
  final String? error;

  /// 解析成功但没有任何槽位（「没听懂」）。
  final bool noUnderstand;
}

/// 搜索进度态。
final searchStatusProvider = Provider<SearchStatus>((ref) {
  final SearchIntentState state = ref.watch(searchIntentProvider);
  final SearchIntent? intent = state.intent;
  return SearchStatus(
    busy: state.busy,
    error: state.error,
    noUnderstand: !state.busy && intent != null && intent.hasNoSlot,
  );
});
