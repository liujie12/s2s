/// 探索页数据 Provider（[126] 前端段）：地图图钉与列表检索的异步装配。
///
/// **供需双选有两种形态**（2026-10-08 二次裁定「方案 B」，取代原「方案 1」）：
/// - `/map/pins` 的 `post_type` **只收单值** → 地图侧由本层**并发发两次请求**
///   并合并 pins/total（见 `pinsProvider`）；
/// - `/posts/search` 的 `post_type` 已扩为 **1–2 个** → 列表侧**单次**请求
///   （逗号多值），排序与分页由服务端全局处理（见 `searchPagerProvider`）。
///
/// [PinsQuery]/[SearchQuery] 持的都是 `postTypes` 列表（切分规则见
/// `discovery_query.dart` 的 `postTypesFor`），但只有地图侧才需要两次请求。
///
/// 地图侧合并**不需要按 id 去重**：每次请求各带一个互斥的单值 `post_type`，而一条
/// 帖子的 `type` 是 ENUM 单值，两个结果集在构造上就不相交。加去重是给不可能
/// 发生的情况写代码。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../perf/layer_switch_recorder.dart';
import 'map_dto.dart';
import 'map_repository.dart';
import 'stress_data.dart';

/// 地图图钉请求参数（值相等即复用，故实现 ==/hashCode）。
class PinsQuery {
  /// 构造图钉请求参数。
  const PinsQuery({
    required this.leafCategoryIds,
    required this.postTypes,
    required this.radius,
    required this.gridId,
    required this.categoryVersion,
    required this.lng,
    required this.lat,
    required this.zoom,
  });

  /// 叶子类目 ID（见 `leafCategoryIdsFor`）。
  final List<int> leafCategoryIds;

  /// 契约 `post_type` 单值序列（1 或 2 个）。
  final List<String> postTypes;

  /// 半径档（`1`/`3`/`5`/`10`/`city`）。
  final String radius;

  /// 约 500m 网格 ID（`gridIdOf`）。
  final String gridId;

  /// 分类树版本号。
  final String categoryVersion;

  /// 视野中心 GCJ-02。
  final double lng;
  final double lat;

  /// 地图缩放级别（决定 pin/cluster 模式）。
  final double zoom;

  @override
  bool operator ==(Object other) =>
      other is PinsQuery &&
      _listEquals(other.leafCategoryIds, leafCategoryIds) &&
      _listEquals(other.postTypes, postTypes) &&
      other.radius == radius &&
      other.gridId == gridId &&
      other.categoryVersion == categoryVersion &&
      other.lng == lng &&
      other.lat == lat &&
      other.zoom == zoom;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(leafCategoryIds),
        Object.hashAll(postTypes),
        radius,
        gridId,
        categoryVersion,
        lng,
        lat,
        zoom,
      );
}

/// 合并后的地图图钉集合（双选时为两次请求结果的并集）。
class MergedPins {
  /// 构造合并结果。
  const MergedPins({
    required this.mode,
    required this.pins,
    required this.clusters,
    required this.total,
    required this.categoryVersionStale,
  });

  /// 空结果（`postTypes` 为空即「供需都不看」，不发请求）。
  const MergedPins.empty()
      : mode = 'pin',
        pins = const [],
        clusters = const [],
        total = 0,
        categoryVersionStale = false;

  /// 聚合模式（两次请求同 zoom，故模式一致，取首个）。
  final String mode;

  /// 单点图钉（`mode=pin` 时非空）。
  final List<MapPinDto> pins;

  /// 服务端预聚合簇（`mode=cluster` 时非空）。
  final List<MapClusterDto> clusters;

  /// 命中总数（两次请求之和）。
  final int total;

  /// 任一次请求报告版本已过期（契约：非错误，仅提示刷新分类树）。
  final bool categoryVersionStale;
}

/// 地图图钉 Provider（`autoDispose`：筛选组合会随交互不断变化，
/// 不 autoDispose 会让每个历史组合的 pins 常驻内存）。
///
/// 返回：[MergedPins]；`postTypes` 为空时直接给空结果，不发请求
/// ——契约五要素缺一即 40001，空 post_type 必然失败。
final pinsProvider = FutureProvider.autoDispose.family<MergedPins, PinsQuery>((
  ref,
  query,
) async {
  if (query.postTypes.isEmpty) return const MergedPins.empty();

  // POC-B 短路注入（[139]）：压测档位开启时不调 /map/pins，直接用压测图钉
  // 组装 MergedPins(mode=pin)。地图「投影→聚合→绘制」全链照跑，帧指标测的
  // 就是真实渲染在 1 万/5 万 点下的表现 —— 这正是 POC-B 要压的那条路径。
  final stress = ref.watch(stressLevelProvider);
  if (stress != StressLevel.off) {
    return MergedPins(
      mode: 'pin',
      // 中心取**当前请求视口中心**而非写死默认中心：否则压测点会落在别的城市、
      // 屏上一条都看不到，测出来只是「Pin 全在屏外」的管线成本（修 H-1）。
      // 视口在相机停稳时更新（见 `_syncFetchViewport`），故一次拖动结束即重新居中。
      pins: buildStressPins(
        stress.pointCount,
        centerLat: query.lat,
        centerLng: query.lng,
      ),
      clusters: const [],
      total: stress.pointCount,
      categoryVersionStale: false,
    );
  }

  final repo = ref.watch(mapRepositoryProvider);
  // 图层切换耗时的网络段（[140] / PRD §6.10）：只在有活跃切换会话时打点。
  // 视口变化（拖动/缩放结束）也会走到这里，但那时没有会话，begin/endNet 是空操作
  // —— 「拖动重取」不是图层切换，本就不该计入 300ms 判据。
  final recorder = ref.read(layerSwitchRecorderProvider);
  recorder.beginNet();
  final List<PinsCompactDto> results;
  try {
    results = await Future.wait([
      for (final postType in query.postTypes)
        repo.fetchPins(
          categoryIds: query.leafCategoryIds,
          postType: postType,
          radius: query.radius,
          gridId: query.gridId,
          categoryVersion: query.categoryVersion,
          lng: query.lng,
          lat: query.lat,
          zoom: query.zoom,
        ),
    ]);
  } finally {
    // 失败也要收段，否则网络段会一直跑到下一次收尾，把整段耗时算成网络耗时。
    recorder.endNet();
  }

  return MergedPins(
    mode: results.first.mode,
    pins: [for (final r in results) ...r.pins],
    clusters: [for (final r in results) ...r.clusters],
    total: results.fold(0, (sum, r) => sum + r.total),
    categoryVersionStale: results.any((r) => r.categoryVersionStale),
  );
});

/// 列表检索请求参数（值相等即复用，故实现 ==/hashCode）。
///
/// **不含 `page`**：分页由 [SearchPager] 独占（`nextPage` 存在分页状态里）。
/// 若把 page 放进 family 键，翻页会生成新的 Provider 实例、把已加载页全部丢弃，
/// 与「无限滚动累积」正好相反。
class SearchQuery {
  /// 构造列表检索请求参数。
  const SearchQuery({
    required this.leafCategoryIds,
    required this.postTypes,
    required this.radius,
    required this.gridId,
    required this.categoryVersion,
    required this.lng,
    required this.lat,
    this.keyword,
    this.sort,
    this.pageSize,
  });

  /// 叶子类目 ID。
  final List<int> leafCategoryIds;

  /// 契约 `post_type` 单值序列（1 或 2 个）。
  final List<String> postTypes;

  /// 半径档。
  final String radius;

  /// 网格 ID。
  final String gridId;

  /// 分类树版本号。
  final String categoryVersion;

  /// 视野中心 GCJ-02。
  final double lng;
  final double lat;

  /// 关键词（可空）。
  final String? keyword;

  /// 排序（契约六值之一，见 `ListingSort.apiValue`）。
  final String? sort;

  /// 每页条数（null 用服务端默认）。
  final int? pageSize;

  @override
  bool operator ==(Object other) =>
      other is SearchQuery &&
      _listEquals(other.leafCategoryIds, leafCategoryIds) &&
      _listEquals(other.postTypes, postTypes) &&
      other.radius == radius &&
      other.gridId == gridId &&
      other.categoryVersion == categoryVersion &&
      other.lng == lng &&
      other.lat == lat &&
      other.keyword == keyword &&
      other.sort == sort &&
      other.pageSize == pageSize;

  @override
  int get hashCode => Object.hash(
        Object.hashAll(leafCategoryIds),
        Object.hashAll(postTypes),
        radius,
        gridId,
        categoryVersion,
        lng,
        lat,
        keyword,
        sort,
        pageSize,
      );
}

/// 单页检索结果（内部中间态，对外暴露的是 [SearchPageState]）。
///
/// 2026-10-08 起**双选只走一次查询**（契约 `post_type` 扩为 1–2 个，服务端以
/// `IN` 完成），故排序与分页都是全局的 —— 此前「双选时并集 ≠ 第 N 页」的近似
/// 已随该改动消失。
class MergedSearchPage {
  /// 构造合并结果。
  const MergedSearchPage({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.categoryVersionStale,
  });

  /// 空结果。
  const MergedSearchPage.empty()
      : items = const [],
        total = 0,
        page = 1,
        pageSize = 0,
        categoryVersionStale = false;

  /// 当前页列表项（双选时为两类各自该页的并集）。
  final List<PostCardDto> items;

  /// 命中总数（双选时为两侧之和）。
  final int total;

  /// 当前页码。
  final int page;

  /// 每页条数。
  final int pageSize;

  /// 任一次请求报告版本已过期。
  final bool categoryVersionStale;
}

/// 列表分页状态（无限滚动）。
class SearchPageState {
  /// 构造分页状态。
  const SearchPageState({
    required this.items,
    required this.total,
    required this.nextPage,
    this.isLoadingMore = false,
    this.moreError,
    this.categoryVersionStale = false,
  });

  /// 已加载的全部条目（跨页累积）。
  final List<PostCardDto> items;

  /// 命中总数（双选时为两侧之和）。
  final int total;

  /// 下一次要请求的页码（首屏之后从 2 起）。
  final int nextPage;

  /// 是否正在加载下一页（底部显示「加载中」）。
  final bool isLoadingMore;

  /// 加载下一页的失败原因（非空时底部显示重试）。
  final Object? moreError;

  /// 任一次请求报告版本已过期。
  final bool categoryVersionStale;

  /// 是否还有下一页。
  ///
  /// 按「已加载条数 < total」判定，**不用「本页返回条数 == pageSize」**：
  /// 当 `total` 恰为 `pageSize` 的整数倍时最后一页仍是满页，用后者会多请求一次
  /// 空页（并让底部行在「没有更多」与「加载中」之间闪一下）。
  bool get hasMore => items.length < total;

  /// 复制并覆盖部分字段。
  ///
  /// [moreError] 为 null 时**保留原值**（与其它字段一致），要清空须显式传
  /// [clearMoreError] —— 否则「取一页成功」无法把上一次的失败提示消掉。
  SearchPageState copyWith({
    List<PostCardDto>? items,
    int? total,
    int? nextPage,
    bool? isLoadingMore,
    Object? moreError,
    bool clearMoreError = false,
    bool? categoryVersionStale,
  }) {
    return SearchPageState(
      items: items ?? this.items,
      total: total ?? this.total,
      nextPage: nextPage ?? this.nextPage,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      moreError: clearMoreError ? null : (moreError ?? this.moreError),
      categoryVersionStale: categoryVersionStale ?? this.categoryVersionStale,
    );
  }
}

/// 列表分页 Provider（`isAutoDispose: true` 理由同 [pinsProvider]）。
///
/// 首屏在 `build` 拉第 1 页，后续页由 [SearchPager.loadMore] 累积。
final searchPagerProvider = AsyncNotifierProvider.family<SearchPager,
    SearchPageState, SearchQuery>(SearchPager.new, isAutoDispose: true);

/// 列表分页控制器（无限滚动）。
///
/// family 参数由**构造函数**注入（Riverpod 3 的 family notifier 约定），
/// 故 `build()` 不带参；`isAutoDispose: true` 由 provider 侧声明。
class SearchPager extends AsyncNotifier<SearchPageState> {
  /// 构造控制器。
  ///
  /// 参数：[query] 本实例对应的请求参数（family 键）。
  SearchPager(this.query);

  /// 本实例对应的请求参数。
  final SearchQuery query;

  @override
  Future<SearchPageState> build() async {
    final MergedSearchPage first = await _fetchPage(1);
    return SearchPageState(
      items: first.items,
      total: first.total,
      nextPage: 2,
      categoryVersionStale: first.categoryVersionStale,
    );
  }

  /// 加载下一页。
  ///
  /// 三种情况直接空操作：还没有首屏结果、已无更多、上一页仍在加载。
  ///
  /// 失败**不把整页打成错误态**：已加载的条目仍然可用，把列表清掉换成错误屏
  /// 会让用户为了多翻一页丢掉了已经看到的内容。失败只记在
  /// [SearchPageState.moreError]，由底部一行提示重试。
  Future<void> loadMore() async {
    final SearchPageState? current = state.asData?.value;
    if (current == null || !current.hasMore || current.isLoadingMore) return;

    state = AsyncData(current.copyWith(isLoadingMore: true, clearMoreError: true));
    try {
      final MergedSearchPage next = await _fetchPage(current.nextPage);
      state = AsyncData(
        current.copyWith(
          items: [...current.items, ...next.items],
          total: next.total,
          nextPage: current.nextPage + 1,
          isLoadingMore: false,
        ),
      );
    } catch (error) {
      state = AsyncData(
        current.copyWith(isLoadingMore: false, moreError: error),
      );
    }
  }

  /// 取某一页（双选**一次查询**，由服务端 `IN` 完成）。
  ///
  /// 2026-10-08 契约把 `post_type` 由单值扩为 1–2 个，本方法随之从「并发两次
  /// 请求再拼接」改为单次请求。理由：排序与分页都是**全局**语义，拆两次再拼接
  /// 会让「价格降序」在端上表现为「先全部资源、再全部需求」，且分页游标无法对齐。
  ///
  /// 参数：[page] 页码（从 1 起）。
  /// 返回：该页结果（服务端已按 `sort` 排好序）。
  Future<MergedSearchPage> _fetchPage(int page) async {
    // 供需都不选 = 没有可看的内容，直接给空结果（契约五要素缺一即 40001）。
    if (query.postTypes.isEmpty) return const MergedSearchPage.empty();

    final repo = ref.read(mapRepositoryProvider);
    final result = await repo.searchPosts(
      categoryIds: query.leafCategoryIds,
      postTypes: query.postTypes,
      radius: query.radius,
      gridId: query.gridId,
      categoryVersion: query.categoryVersion,
      lng: query.lng,
      lat: query.lat,
      keyword: query.keyword,
      sort: query.sort,
      page: page,
      pageSize: query.pageSize,
    );

    return MergedSearchPage(
      items: result.items,
      total: result.total,
      page: result.page,
      pageSize: result.pageSize,
      categoryVersionStale: result.categoryVersionStale,
    );
  }
}

/// 列表相等性（`List` 无值相等语义，family 键必须逐元素比较）。
bool _listEquals<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
