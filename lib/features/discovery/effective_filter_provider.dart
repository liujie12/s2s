/// 生效条件的唯一读点。
///
/// 地图请求、条件带、筛选面板、列表页都只读它；它们不再各自 watch
/// `discoveryFilterProvider` 与 `searchIntentProvider` 再自己回落。
///
/// 为什么用 `Provider` 而不是在页面里算：页面内联计算等于每个读点一份回落规则，
/// 而「两页对同一条件给出不同结果」正是本轮要消除的缺陷。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'discovery_filter.dart';
import 'effective_filter.dart';
import 'search_intent.dart';

/// 当前生效条件。
final effectiveFilterProvider = Provider<EffectiveFilter>((ref) {
  final DiscoveryFilter filter = ref.watch(discoveryFilterProvider);
  final SearchIntentState intentState = ref.watch(searchIntentProvider);
  return effectiveFilterOf(filter, intentState.intent);
});

/// 一次搜索的进度态（忙碌 / 失败 / 没听懂）。
///
/// 为什么单独出一个 Provider：条件带与语音面板都要显示这三态，但它们是纯展示，
/// 不该各自去读「槽位卡」这个实现细节。集中在这里，读点纪律才守得住。
class SearchStatus {
  /// 构造状态。
  const SearchStatus({this.busy = false, this.error, this.noUnderstand = false});

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
