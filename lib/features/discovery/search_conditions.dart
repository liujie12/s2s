/// 条件写入门面：所有条件改动的唯一写点。
///
/// 为什么需要门面：改动前，筛选面板直写持久筛选、回执条直写搜索态、地图页各自
/// 拼回落，写点分散导致「搜索态下改面板会写错源」和「撤销只能回退一个源」。
/// 门面把「写哪个源」的判断收在一处，撤销也在这里做（快照同时含两个源）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../domain/listing_category.dart';
import 'condition_slots.dart';
import 'discovery_filter.dart';
import 'discovery_query.dart';
import 'effective_filter.dart';
import 'effective_filter_provider.dart';
import 'search_intent.dart';

/// 一档撤销快照。
typedef ConditionsSnapshot = ({DiscoveryFilter filter, SearchIntent? intent});

/// 门面状态：输入文本 + 一档撤销快照。
///
/// 文本为什么由门面持有：地图与列表共用同一个输入框，页面私有 controller
/// 无法跨页共享；切视图后会出现「输入框空着但 chip 在过滤」。
class SearchConditionsState {
  /// 构造状态。
  const SearchConditionsState({this.queryText = '', this.snapshot, this.interactionId});

  /// 当前搜索输入文本（只用于回显，不参与过滤）。
  final String queryText;

  /// 可撤销的快照；null 表示无可撤销状态。
  final ConditionsSnapshot? snapshot;

  /// 本次搜索的交互标识（解析与取数共用；null 表示当前没有进行中的搜索）。
  ///
  /// 由门面持有而不是每个请求各自生成：拦截器只在头缺失时兜底补新 UUID，
  /// 两条请求各自生成就会拿到不同标识，服务端日志无法成对检索。
  final String? interactionId;

  /// 是否可撤销。
  bool get canUndo => snapshot != null;

  /// 复制并替换字段。
  SearchConditionsState copyWith({
    String? queryText,
    ConditionsSnapshot? snapshot,
    bool clearSnapshot = false,
    String? interactionId,
    bool clearInteractionId = false,
  }) {
    return SearchConditionsState(
      queryText: queryText ?? this.queryText,
      snapshot: clearSnapshot ? null : (snapshot ?? this.snapshot),
      interactionId: clearInteractionId ? null : (interactionId ?? this.interactionId),
    );
  }
}

/// 条件写入门面。
class SearchConditionsNotifier extends Notifier<SearchConditionsState> {
  @override
  SearchConditionsState build() => const SearchConditionsState();

  /// 更新输入文本（不触发解析、不改条件）。
  ///
  /// 参数：[text] 新文本；返回：无。
  void setQueryText(String text) {
    state = state.copyWith(queryText: text);
  }

  /// 只清文本（搜索框叉号），保留全部条件与搜索态（R15）。
  void clearText() {
    state = state.copyWith(queryText: '');
  }

  /// 设置半径档。
  ///
  /// 参数：[radius] 目标档位；返回：无。
  void setRadius(SearchRadius radius) {
    _recordSnapshot();
    final SearchIntent? intent = _intent;
    if (intent == null) {
      ref.read(discoveryFilterProvider.notifier).setRadius(radius);
      return;
    }
    _writeIntent(
      intent.copyWith(
        radius: toApiRadius(radius),
        radiusMeters: radius.km == null ? null : radius.km! * 1000,
      ),
    );
  }

  /// 设置供需集合。
  ///
  /// 参数：[selected] 目标集合；返回：无。
  void setSupplyDemand(Set<SupplyDemand> selected) {
    _recordSnapshot();
    final SearchIntent? intent = _intent;
    if (intent == null) {
      ref.read(discoveryFilterProvider.notifier).setSupplyDemand(selected);
      return;
    }
    _writeIntent(intent.copyWith(postType: _singlePostType(selected)));
  }

  /// 切换单个供需项（面板胶囊用）。
  ///
  /// 参数：[value] 被切换的方向；返回：无。
  void toggleSupplyDemand(SupplyDemand value) {
    final Set<SupplyDemand> current = ref.read(effectiveFilterProvider).supplyDemand;
    final Set<SupplyDemand> next = {...current};
    next.contains(value) ? next.remove(value) : next.add(value);
    setSupplyDemand(next);
  }

  /// 设置一级大类集合。
  ///
  /// 参数：[tops] 目标大类集合（空集 = 全部分类）；返回：无。
  void setCategories(Set<ListingCategory> tops) {
    _recordSnapshot();
    final SearchIntent? intent = _intent;
    if (intent == null) {
      ref.read(discoveryFilterProvider.notifier).setCategories(tops);
      return;
    }
    _writeIntent(
      intent.copyWith(
        leafCategoryIds: leafCategoryIdsFor(tops),
        categoryLabels: [
          for (final ListingCategory c in ListingCategory.values)
            if (tops.contains(c)) c.label,
        ],
      ),
    );
  }

  /// 切换一级大类（面板胶囊用）。
  ///
  /// 从「全部」点某一类时直接替换为该一类（与面板既有语义一致），
  /// 否则在已选集合上增删。
  ///
  /// 参数：[value] 被切换的大类；返回：无。
  void toggleCategory(ListingCategory value) {
    final EffectiveFilter effective = ref.read(effectiveFilterProvider);
    final Set<ListingCategory> current = {
      for (final ListingCategory c in ListingCategory.values)
        if (effective.includesCategory(c)) c,
    };
    if (effective.isAllCategories) {
      setCategories({value});
      return;
    }
    current.contains(value) ? current.remove(value) : current.add(value);
    setCategories(current);
  }

  /// 回到「全部分类」。
  void clearCategories() => setCategories(const <ListingCategory>{});

  /// 设置价格区间；任一侧传 null 即取消该侧（R23）。
  ///
  /// 价格无论有无搜索态都写持久筛选 —— 它是持久条件，不随一次搜索结束而消失。
  ///
  /// 参数：[min]/[max] 价格上下限（元）；返回：无。
  void setPrice({int? min, int? max}) {
    _recordSnapshot();
    ref.read(discoveryFilterProvider.notifier).setPriceRange(min: min, max: max);
  }

  /// 删除一枚条件 chip。
  ///
  /// 删除写入「显式清空」标记，该维不再回落持久值（否则 chip 会立刻以另一个
  /// 来源重新出现，删除看起来失灵）。
  ///
  /// 参数：[chip] 目标 chip；返回：无。
  void removeSlot(ConditionChip chip) {
    _recordSnapshot();
    final SearchIntent? intent = _intent;
    switch (chip.slot) {
      case ConditionSlot.radius:
        if (intent == null) {
          ref.read(discoveryFilterProvider.notifier).setRadius(SearchRadius.city);
        } else {
          _writeIntent(intent.withoutRadius());
        }
      case ConditionSlot.supplyDemand:
        if (intent == null) {
          ref.read(discoveryFilterProvider.notifier)
              .setSupplyDemand(const {SupplyDemand.supply, SupplyDemand.demand});
        } else {
          _writeIntent(intent.withoutPostType());
        }
      case ConditionSlot.category:
        if (intent == null) {
          ref.read(discoveryFilterProvider.notifier).clearCategories();
        } else {
          _writeIntent(
            chip.index == null
                ? intent.copyWith(leafCategoryIds: const <int>[], categoryLabels: const <String>[])
                : intent.withoutCategoryAt(chip.index!),
          );
        }
      case ConditionSlot.price:
        ref.read(discoveryFilterProvider.notifier).setPriceRange();
      case ConditionSlot.anchor:
        if (intent != null) _writeIntent(intent.withoutAnchor());
      case ConditionSlot.community:
        if (intent != null) _writeIntent(intent.withoutCommunity());
    }
  }

  /// 结束整次搜索（清除）。
  ///
  /// 文本、槽位、撤销栈一并清空，持久筛选逐字段保持不变（R14）。
  void clearAll() {
    ref.read(searchIntentProvider.notifier).clear();
    state = const SearchConditionsState();
  }

  /// 提交文本或语音，触发一次解析（F1 的入口）。
  ///
  /// 解析成功后把解析产出的价格镜像进持久筛选：价格是持久条件，
  /// 清除搜索后仍应生效（R23）。
  ///
  /// 参数：[text] 文本（可空）；[voiceMediaId]/[voiceBase64]/[voiceContentType]
  /// 语音入口三选一；[anchorLat]/[anchorLng] 长按点；[currentLat]/[currentLng] 定位；
  /// [retry] 是否为「没听懂」后的重试（复用同一交互标识，视作同一次搜索的修正）。
  /// 返回：[Future] 完成信号。
  Future<void> submit({
    String? text,
    String? voiceMediaId,
    String? voiceBase64,
    String? voiceContentType,
    double? anchorLat,
    double? anchorLng,
    double? currentLat,
    double? currentLng,
    bool retry = false,
  }) async {
    if (text != null) state = state.copyWith(queryText: text);
    // 重试沿用同一标识；新提交换新标识（一次搜索一对请求）。
    final String interactionId = retry && state.interactionId != null
        ? state.interactionId!
        : const Uuid().v4();
    state = state.copyWith(interactionId: interactionId);
    _recordSnapshot();
    await ref.read(searchIntentProvider.notifier).resolve(
      text: text,
      voiceMediaId: voiceMediaId,
      voiceBase64: voiceBase64,
      voiceContentType: voiceContentType,
      anchorLat: anchorLat,
      anchorLng: anchorLng,
      currentLat: currentLat,
      currentLng: currentLng,
      interactionId: interactionId,
    );
    final SearchIntent? intent = _intent;
    if (intent == null) return;
    if (intent.priceMin != null || intent.priceMax != null) {
      ref.read(discoveryFilterProvider.notifier).setPriceRange(
        min: intent.priceMin?.round(),
        max: intent.priceMax?.round(),
      );
    }
  }

  /// 撤销到上一档条件（同时回退两个源）。
  void undo() {
    final ConditionsSnapshot? snapshot = state.snapshot;
    if (snapshot == null) return;
    ref.read(discoveryFilterProvider.notifier).replace(snapshot.filter);
    final SearchIntentNotifier intents = ref.read(searchIntentProvider.notifier);
    if (snapshot.intent == null) {
      intents.clear();
    } else {
      intents.replace(snapshot.intent!);
    }
    state = state.copyWith(clearSnapshot: true);
  }

  /// 当前搜索槽位卡（null 表示无搜索态）。
  SearchIntent? get _intent => ref.read(searchIntentProvider).intent;

  /// 写入当前搜索槽位卡（不额外压快照 —— 快照由调用方先压）。
  void _writeIntent(SearchIntent next) {
    ref.read(searchIntentProvider.notifier).replace(next);
  }

  /// 压一档快照（同一动作的多次写入只保留最早的那一档）。
  ///
  /// 连续操作时保留最早快照：用户点三次删除后按撤销，期望回到「都还在」，
  /// 而不是只回退最后一次。
  void _recordSnapshot() {
    if (state.snapshot != null) return;
    state = state.copyWith(
      snapshot: (
        filter: ref.read(discoveryFilterProvider),
        intent: _intent,
      ),
    );
  }

  /// 供需集合 → 契约单值（双选时 null：意图只表达单一方向）。
  String? _singlePostType(Set<SupplyDemand> selected) {
    if (selected.length != 1) return null;
    return selected.first == SupplyDemand.supply ? 'resource' : 'demand';
  }
}

/// 条件门面 Provider。
final searchConditionsProvider =
    NotifierProvider<SearchConditionsNotifier, SearchConditionsState>(
      SearchConditionsNotifier.new,
    );
