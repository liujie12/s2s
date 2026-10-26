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
