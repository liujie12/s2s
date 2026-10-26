/// 语义搜索一次性状态（地图语音语义搜索 U5，方案 KTD4）。
///
/// 与 `DiscoveryFilter` 的分工：`DiscoveryFilter` 是**持久筛选**（范围条/供需/分类
/// 胶囊），本对象是**一次性搜索态**——由一句话解析得到，可撤销、可逐项删除，
/// 不写入持久筛选。混在一起会让用户撤销搜索后仍被悄悄收窄。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/contract_json.dart';
import '../../core/network/api_exception.dart';
import 'condition_slots.dart';
import 'search_repository.dart';

/// copyWith 的「保持不变」哨兵（null 表示显式清除某槽位）。
const Object _keep = _KeepSentinel();

/// 哨兵类型：只为在可选参数默认值里使用 const 实例。
class _KeepSentinel {
  /// 构造哨兵。
  const _KeepSentinel();
}

/// 契约半径档顺序（与后端 `NfrSearch.RADIUS_TIERS` 同序）。
const List<String> _radiusTiers = <String>['1', '3', '5', '10', 'city'];

/// 半径档 → 显示文案。
String radiusTierLabel(String? tier) => switch (tier) {
  '1' => '1km',
  '3' => '3km',
  '5' => '5km',
  '10' => '10km',
  'city' => '全城',
  _ => '',
};

/// 供需 → 显示文案。
String postTypeLabel(String? postType) => switch (postType) {
  'resource' => '资源',
  'demand' => '需求',
  _ => '',
};

/// 小区候选（低置信时回显给用户点选）。
class CommunityCandidate {
  /// 构造候选。
  const CommunityCandidate({
    required this.id,
    required this.name,
    required this.district,
    required this.lng,
    required this.lat,
  });

  /// 由契约对象构造。
  ///
  /// 参数：[json] `community_candidates[]` 元素。
  /// 返回：[CommunityCandidate]；缺少 id/name 或坐标非法时返回 null。
  static CommunityCandidate? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final name = json['name'];
    final lng = json['lng'];
    final lat = json['lat'];
    if (id is! String || id.isEmpty || name is! String || lng is! num || lat is! num) {
      return null;
    }
    return CommunityCandidate(
      id: id,
      name: name,
      district: json['district'] is String ? json['district'] as String : '',
      lng: lng.toDouble(),
      lat: lat.toDouble(),
    );
  }

  /// 小区实体 ID（高德 POI ID）。
  final String id;

  /// 小区规范名。
  final String name;

  /// 所属区县。
  final String district;

  /// 小区质心坐标（GCJ-02）。
  final double lng;
  final double lat;

  @override
  bool operator ==(Object other) =>
      other is CommunityCandidate &&
      other.id == id &&
      other.name == name &&
      other.district == district &&
      other.lng == lng &&
      other.lat == lat;

  @override
  int get hashCode => Object.hash(id, name, district, lng, lat);
}

/// 一次语义解析得到的槽位卡（不可变）。
class SearchIntent {
  /// 构造槽位卡。
  const SearchIntent({
    required this.queryText,
    this.transcript,
    this.postType,
    this.leafCategoryIds = const <int>[],
    this.categoryLabels = const <String>[],
    this.radius,
    this.radiusMeters,
    this.anchorLat,
    this.anchorLng,
    this.anchorName,
    this.anchorSource,
    this.communityId,
    this.communityName,
    this.communityCandidates = const <CommunityCandidate>[],
    this.priceMin,
    this.priceMax,
    this.priceExcludesNegotiable = false,
    this.unresolvedFields = const <String>[],
    this.sources = const <String, String>{},
    this.clearedSlots = const <ConditionSlot>{},
    this.aiUsed = false,
    this.degraded = false,
  });

  /// 由契约 data（`SearchResolveResult`）构造。
  ///
  /// 参数：[json] 信封 data。
  /// 返回：[SearchIntent]。
  /// 抛出：[ApiException.parse] 结构非法时。
  factory SearchIntent.fromJson(Object? json) {
    final map = requireMap(json, 'SearchResolveResult');
    return SearchIntent(
      queryText: optString(map, 'query_text', 'SearchResolveResult') ?? '',
      transcript: optString(map, 'transcript', 'SearchResolveResult'),
      postType: optString(map, 'post_type', 'SearchResolveResult'),
      leafCategoryIds: _intList(map['leaf_category_ids']),
      categoryLabels:
          optStringList(map, 'category_labels', 'SearchResolveResult') ??
          const <String>[],
      radius: optString(map, 'radius', 'SearchResolveResult'),
      radiusMeters: optInt(map, 'radius_meters', 'SearchResolveResult'),
      anchorLat: optDouble(map, 'anchor_lat', 'SearchResolveResult'),
      anchorLng: optDouble(map, 'anchor_lng', 'SearchResolveResult'),
      anchorName: optString(map, 'anchor_name', 'SearchResolveResult'),
      anchorSource: optString(map, 'anchor_source', 'SearchResolveResult'),
      communityId: optString(map, 'community_id', 'SearchResolveResult'),
      communityName: optString(map, 'community_name', 'SearchResolveResult'),
      communityCandidates: _communityCandidates(map['community_candidates']),
      priceMin: optDouble(map, 'price_min', 'SearchResolveResult'),
      priceMax: optDouble(map, 'price_max', 'SearchResolveResult'),
      priceExcludesNegotiable:
          optBool(map, 'price_excludes_negotiable', 'SearchResolveResult') ?? false,
      unresolvedFields:
          optStringList(map, 'unresolved_fields', 'SearchResolveResult') ??
          const <String>[],
      sources: _stringMap(map['sources']),
      aiUsed: optBool(map, 'ai_used', 'SearchResolveResult') ?? false,
      degraded: optBool(map, 'degraded', 'SearchResolveResult') ?? false,
    );
  }

  /// 归一化后的解析输入（回显到搜索框）。
  final String queryText;

  /// 语音转写文本（无语音为 null）。
  final String? transcript;

  /// 供需方向（resource/demand）。
  final String? postType;

  /// 命中的叶子类目 ID。
  final List<int> leafCategoryIds;

  /// 叶子类目显示名（与 ID 同序）。
  final List<String> categoryLabels;

  /// 半径档（1/3/5/10/city）。
  final String? radius;

  /// 真实半径米数（用于画圈与客户端精裁）。
  final int? radiusMeters;

  /// 锚点纬度。
  final double? anchorLat;

  /// 锚点经度。
  final double? anchorLng;

  /// 地点名（POI 命中时有值）。
  final String? anchorName;

  /// 锚点来源（text/poi/long_press/current）。
  final String? anchorSource;

  /// 小区实体 ID（高置信时自动采用；用于 `/map/pins?community_id=` 精确过滤）。
  final String? communityId;

  /// 小区规范名（回显用）。
  final String? communityName;

  /// 低置信时的小区候选（最多 3 个，供用户点选）。
  final List<CommunityCandidate> communityCandidates;

  /// 价格下限（元）。
  final double? priceMin;

  /// 价格上限（元）。
  final double? priceMax;

  /// 设置上限时面议被排除。
  final bool priceExcludesNegotiable;

  /// 未敢采用/无法解析的字段（灰态「没敢用」）。
  final List<String> unresolvedFields;

  /// 槽位来源标记。
  final Map<String, String> sources;

  /// 被用户**显式清空**的槽位。
  ///
  /// 为什么需要它：槽位值为 null 有歧义 —— 既可能表示「本次搜索没提到这一维」
  /// （应回落持久筛选），也可能表示「用户把这一维删掉了」（不该回落）。
  /// 缺这份标记，删掉搜索态的一枚 chip，它会立刻以持久值重新出现。
  final Set<ConditionSlot> clearedSlots;

  /// 该槽位是否被显式清空。
  ///
  /// 参数：[slot] 槽位；返回：是否被显式清空。
  bool isCleared(ConditionSlot slot) => clearedSlots.contains(slot);

  /// 是否走了 AI 解析（缓存命中也算）。
  final bool aiUsed;

  /// AI 不可用/超时，已降级为词表解析。
  final bool degraded;

  /// 是否没有任何有效收窄（用于零结果改写入口）。
  bool get hasNoSlot =>
      postType == null &&
      leafCategoryIds.isEmpty &&
      radius == null &&
      priceMin == null &&
      priceMax == null &&
      communityId == null &&
      anchorLat == null;

  /// 价格文案。
  String get priceLabel {
    final min = priceMin;
    final max = priceMax;
    if (min != null && max != null) {
      return '${_yuan(min)}-${_yuan(max)}元';
    }
    if (max != null) return '≤${_yuan(max)}元';
    if (min != null) return '≥${_yuan(min)}元';
    return '';
  }

  /// 删除某个类目 chip。
  ///
  /// 参数：[index] 类目下标。
  /// 返回：删除后的新槽位卡。
  SearchIntent withoutCategoryAt(int index) {
    final ids = [...leafCategoryIds]..removeAt(index);
    final labels = [...categoryLabels]..removeAt(index);
    return copyWith(leafCategoryIds: ids, categoryLabels: labels);
  }

  /// 删除价格条件。
  ///
  /// 返回：删除后的新槽位卡。
  SearchIntent withoutPrice() => copyWith(priceMin: null, priceMax: null);

  /// 删除半径条件（搜索圈随之消失）。
  ///
  /// 返回：删除后的新槽位卡。
  SearchIntent withoutRadius() => copyWith(radius: null, radiusMeters: null);

  /// 删除供需条件。
  ///
  /// 返回：删除后的新槽位卡。
  SearchIntent withoutPostType() => copyWith(postType: null);

  /// 删除地点锚点。
  ///
  /// 返回：删除后的新槽位卡（半径保留时搜索圈以地图中心兜底）。
  SearchIntent withoutAnchor() => copyWith(anchorLat: null, anchorLng: null);

  /// 小区显示文案（无小区为空串）。
  String get communityLabel => communityName ?? '';

  /// 删除小区筛选（回退到半径/地址近似匹配）。
  ///
  /// 返回：删除后的新槽位卡。
  SearchIntent withoutCommunity() => copyWith(
        communityId: null,
        communityName: null,
        communityCandidates: const <CommunityCandidate>[],
      );

  /// 采用某个小区候选（低置信点选后调用）。
  ///
  /// 参数：[candidate] 用户选中的候选。
  /// 返回：带 `communityId` 与新锚点的新槽位卡。
  SearchIntent selectCommunity(CommunityCandidate candidate) => copyWith(
        communityId: candidate.id,
        communityName: candidate.name,
        communityCandidates: const <CommunityCandidate>[],
        anchorLat: candidate.lat,
        anchorLng: candidate.lng,
        anchorName: candidate.name,
        anchorSource: 'poi',
      );

  /// 放宽一档半径（1→3→5→10→全城）；已是最宽时不变。
  ///
  /// 返回：放宽后的新槽位卡。
  SearchIntent widenRadius() {
    final current = _radiusTiers.indexOf(radius ?? '');
    final nextIndex = current < 0 ? 0 : (current + 1).clamp(0, _radiusTiers.length - 1);
    final next = _radiusTiers[nextIndex];
    return copyWith(
      radius: next,
      radiusMeters: switch (next) {
        '1' => 1000,
        '3' => 3000,
        '5' => 5000,
        '10' => 10000,
        _ => null,
      },
    );
  }

  /// 内部复制（未传的槽位保持不变；显式传 null 表示清除该槽位）。
  SearchIntent _copy({
    Object? postType = _keep,
    Object? leafCategoryIds = _keep,
    Object? categoryLabels = _keep,
    Object? radius = _keep,
    Object? radiusMeters = _keep,
    Object? anchorLat = _keep,
    Object? anchorLng = _keep,
    Object? anchorName = _keep,
    Object? anchorSource = _keep,
    Object? communityId = _keep,
    Object? communityName = _keep,
    Object? communityCandidates = _keep,
    Object? priceMin = _keep,
    Object? priceMax = _keep,
    Set<ConditionSlot>? clearedSlots,
  }) {
    final nextPostType = identical(postType, _keep) ? this.postType : postType as String?;
    final nextIds = identical(leafCategoryIds, _keep)
        ? this.leafCategoryIds
        : leafCategoryIds as List<int>;
    final nextLabels = identical(categoryLabels, _keep)
        ? this.categoryLabels
        : categoryLabels as List<String>;
    final nextRadius = identical(radius, _keep) ? this.radius : radius as String?;
    final nextRadiusMeters = identical(radiusMeters, _keep)
        ? this.radiusMeters
        : radiusMeters as int?;
    final nextAnchorLat = identical(anchorLat, _keep) ? this.anchorLat : anchorLat as double?;
    final nextAnchorLng = identical(anchorLng, _keep) ? this.anchorLng : anchorLng as double?;
    final nextPriceMin = identical(priceMin, _keep) ? this.priceMin : priceMin as double?;
    final nextPriceMax = identical(priceMax, _keep) ? this.priceMax : priceMax as double?;
    final nextCommunityId =
        identical(communityId, _keep) ? this.communityId : communityId as String?;
    final nextCommunityName =
        identical(communityName, _keep) ? this.communityName : communityName as String?;
    final nextCandidates = identical(communityCandidates, _keep)
        ? this.communityCandidates
        : communityCandidates as List<CommunityCandidate>;
    return SearchIntent(
      queryText: queryText,
      transcript: transcript,
      postType: nextPostType,
      leafCategoryIds: nextIds,
      categoryLabels: nextLabels,
      radius: nextRadius,
      radiusMeters: nextRadiusMeters,
      anchorLat: nextAnchorLat,
      anchorLng: nextAnchorLng,
      // 锚点被清除时名称/来源/小区一并清除；保留锚点时沿用或使用显式新值
      anchorName: nextAnchorLat == null
          ? null
          : (identical(anchorName, _keep) ? this.anchorName : anchorName as String?),
      anchorSource: nextAnchorLat == null
          ? null
          : (identical(anchorSource, _keep) ? this.anchorSource : anchorSource as String?),
      communityId: nextAnchorLat == null ? null : nextCommunityId,
      communityName: nextAnchorLat == null ? null : nextCommunityName,
      communityCandidates: nextAnchorLat == null
          ? const <CommunityCandidate>[]
          : nextCandidates,
      priceMin: nextPriceMin,
      priceMax: nextPriceMax,
      priceExcludesNegotiable: nextPriceMax != null,
      unresolvedFields: unresolvedFields,
      sources: sources,
      clearedSlots: clearedSlots ?? this.clearedSlots,
      aiUsed: aiUsed,
      degraded: degraded,
    );
  }

  /// 公开的槽位改写入口（门面专用）。
  ///
  /// 语义与 `_copy` 一致：未传的槽位保持不变，显式传 null 表示清空该槽位。
  /// 与 `_copy` 的差别只有一处 —— 它同时维护 [clearedSlots]：
  /// 传 null 记入「显式清空」，传新值则撤销该标记。这样门面不必在每次
  /// 删除/改值后自己拼标记，也就不会漏。
  ///
  /// 参数：各槽位新值（全部可选）；返回：改写后的槽位卡。
  SearchIntent copyWith({
    Object? postType = _keep,
    Object? leafCategoryIds = _keep,
    Object? categoryLabels = _keep,
    Object? radius = _keep,
    Object? radiusMeters = _keep,
    Object? anchorLat = _keep,
    Object? anchorLng = _keep,
    Object? anchorName = _keep,
    Object? anchorSource = _keep,
    Object? communityId = _keep,
    Object? communityName = _keep,
    Object? communityCandidates = _keep,
    Object? priceMin = _keep,
    Object? priceMax = _keep,
  }) {
    final Set<ConditionSlot> cleared = {...clearedSlots};
    void mark(ConditionSlot slot, Object? value, {bool clearsOnEmpty = false}) {
      if (identical(value, _keep)) return;
      final bool emptied = value == null || (clearsOnEmpty && (value as List<Object?>).isEmpty);
      emptied ? cleared.add(slot) : cleared.remove(slot);
    }

    mark(ConditionSlot.supplyDemand, postType);
    mark(ConditionSlot.radius, radius);
    mark(ConditionSlot.category, leafCategoryIds, clearsOnEmpty: true);
    mark(ConditionSlot.anchor, anchorLat);
    mark(ConditionSlot.community, communityId);

    return _copy(
      postType: postType,
      leafCategoryIds: leafCategoryIds,
      categoryLabels: categoryLabels,
      radius: radius,
      radiusMeters: radiusMeters,
      anchorLat: anchorLat,
      anchorLng: anchorLng,
      anchorName: anchorName,
      anchorSource: anchorSource,
      communityId: communityId,
      communityName: communityName,
      communityCandidates: communityCandidates,
      priceMin: priceMin,
      priceMax: priceMax,
      clearedSlots: cleared,
    );
  }

  /// 金额展示：整数不带小数。
  static String _yuan(double value) =>
      value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toString();

  static List<int> _intList(Object? raw) {
    if (raw is! List) return const <int>[];
    return [for (final item in raw) if (item is num) item.toInt()];
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    return {
      for (final entry in raw.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  }

  static List<CommunityCandidate> _communityCandidates(Object? raw) {
    if (raw is! List) return const <CommunityCandidate>[];
    return [
      for (final item in raw) ?CommunityCandidate.tryParse(item),
    ];
  }

  @override
  bool operator ==(Object other) =>
      other is SearchIntent &&
      other.queryText == queryText &&
      other.transcript == transcript &&
      other.postType == postType &&
      listEquals(other.leafCategoryIds, leafCategoryIds) &&
      listEquals(other.categoryLabels, categoryLabels) &&
      other.radius == radius &&
      other.radiusMeters == radiusMeters &&
      other.anchorLat == anchorLat &&
      other.anchorLng == anchorLng &&
      other.anchorName == anchorName &&
      other.anchorSource == anchorSource &&
      other.communityId == communityId &&
      other.communityName == communityName &&
      listEquals(other.communityCandidates, communityCandidates) &&
      other.priceMin == priceMin &&
      other.priceMax == priceMax &&
      other.priceExcludesNegotiable == priceExcludesNegotiable &&
      listEquals(other.unresolvedFields, unresolvedFields) &&
      setEquals(other.clearedSlots, clearedSlots) &&
      mapEquals(other.sources, sources) &&
      other.aiUsed == aiUsed &&
      other.degraded == degraded;

  @override
  int get hashCode => Object.hash(
    queryText,
    transcript,
    postType,
    Object.hashAll(leafCategoryIds),
    Object.hashAll(categoryLabels),
    radius,
    radiusMeters,
    anchorLat,
    anchorLng,
    anchorName,
    anchorSource,
    communityId,
    communityName,
    Object.hashAll(communityCandidates),
    priceMin,
    priceMax,
    priceExcludesNegotiable,
    Object.hashAll([
      ...unresolvedFields,
      // 排序后再入 hash：== 用 setEquals（顺序无关），hash 若依赖 Set 迭代顺序
      // 会让两个相等的实例算出不同 hash，违反 Object 契约。
      ...(clearedSlots.map((slot) => slot.name).toList()..sort()),
    ]),
    Object.hashAll(sources.entries.map((e) => '${e.key}=${e.value}')),
    Object.hash(aiUsed, degraded),
  );
}

/// 语义搜索状态（当前槽位卡 + 上一档 + 忙碌/错误）。
class SearchIntentState {
  /// 构造状态。
  const SearchIntentState({
    this.intent,
    this.previous,
    this.busy = false,
    this.error,
  });

  /// 当前槽位卡；null 表示未处于搜索态。
  final SearchIntent? intent;

  /// 上一档槽位卡（撤销回退用）。
  final SearchIntent? previous;

  /// 是否正在解析。
  final bool busy;

  /// 最近一次解析失败的用户文案。
  final String? error;

  /// 是否处于搜索态。
  bool get active => intent != null;

  /// 是否可撤销。
  bool get canUndo => previous != null;
}

/// 语义搜索状态读写入口。
class SearchIntentNotifier extends Notifier<SearchIntentState> {
  @override
  SearchIntentState build() => const SearchIntentState();

  /// 触发一次解析（文字或语音）。
  ///
  /// 参数：
  /// - [text] 文字输入（可空）；
  /// - [voiceMediaId] 登录态音频媒体 ID（可空）；
  /// - [voiceBase64] 游客音频 base64（可空）；
  /// - [voiceContentType] 游客音频 MIME（可空）；
  /// - [anchorLat]/[anchorLng] 长按地图锚点（可空）；
  /// - [currentLat]/[currentLng] 当前定位（可空）；
  /// - [interactionId] 一次搜索的交互标识（解析与后续取数共用）。
  /// 返回：[Future] 完成信号（失败写入 error，不向 UI 抛出）。
  Future<void> resolve({
    String? text,
    String? voiceMediaId,
    String? voiceBase64,
    String? voiceContentType,
    double? anchorLat,
    double? anchorLng,
    double? currentLat,
    double? currentLng,
    String? interactionId,
  }) async {
    state = SearchIntentState(intent: state.intent, previous: state.previous, busy: true);
    try {
      final intent = await ref.read(searchRepositoryProvider).resolve(
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
      state = SearchIntentState(
        intent: intent,
        previous: state.intent,
      );
    } catch (error) {
      state = SearchIntentState(
        intent: state.intent,
        previous: state.previous,
        error: asApiException(error).uiMessage,
      );
    }
  }

  /// 逐项删除/放宽后的主动更新（记录上一档供撤销）。
  ///
  /// 参数：[next] 新槽位卡；null 表示清除搜索态。
  void update(SearchIntent? next) {
    if (next == null) {
      clear();
      return;
    }
    state = SearchIntentState(intent: next, previous: state.intent);
  }

  /// 撤销回上一档；无上一档时清除。
  void undo() {
    final previous = state.previous;
    state = SearchIntentState(intent: previous);
  }

  /// 清除搜索态（回到持久筛选）。
  void clear() {
    state = const SearchIntentState();
  }

  /// 整体替换当前槽位卡（撤销回滚与门面写入用）。
  ///
  /// 与 [update] 的差别：它不记录 `previous`。撤销统一由
  /// `SearchConditionsNotifier` 的快照承担，两条撤销路径并存会各自回退一半。
  ///
  /// 参数：[next] 新的槽位卡；返回：无。
  void replace(SearchIntent next) {
    state = SearchIntentState(intent: next);
  }
}

/// 语义搜索状态 Provider。
final searchIntentProvider =
    NotifierProvider<SearchIntentNotifier, SearchIntentState>(
      SearchIntentNotifier.new,
    );
