/// Pin 集合本地缓存键（前端设计 §16.2 五要素）。
///
/// 五要素缺一不可（架构 §7.1.1）：任一要素缺失都会造成跨条件错命中，表现为
/// 「切了分类但地图上还是旧的点」这类无法复现的诡异现象。服务端 Redis 键用同一套
/// 要素（后端 §5.4.4），两侧必须同构——不同构时客户端命中率与服务端命中率无法交叉核对。
///
/// 服务端对缺失要素返回 `40001` 且不做默认值兜底，故客户端必须在发请求前自检五要素
/// 齐备（见 [hasAllPinCacheElements]），而不是指望服务端补齐。
library;

/// 五要素是否齐备（发请求前的自检，缺一不发）。
///
/// 返回 false 时调用方不得发送 `/map/pins` 请求，也不得构建缓存键——否则要么
/// 触发服务端 40001，要么用不完整键写入缓存造成跨条件错命中。
///
/// [leafCategoryIds] 已选叶子类目 ID 集合
/// [postType]        供需态（contract `resource`/`demand`）
/// [radius]          半径档（contract `'1'`/`'3'`/`'5'`/`'10'`/`'city'`）
/// [gridId]          约 500m 网格 ID（算法见 `grid_id.dart`）
/// [categoryVersion] 分类树版本号（格式 `YYYY-MM-DD.N`）
///
/// 返回：五要素是否全部非空
bool hasAllPinCacheElements({
  required List<int> leafCategoryIds,
  required String postType,
  required String radius,
  required String gridId,
  required String categoryVersion,
}) {
  return leafCategoryIds.isNotEmpty &&
      postType.isNotEmpty &&
      radius.isNotEmpty &&
      gridId.isNotEmpty &&
      categoryVersion.isNotEmpty;
}

/// 拼装 Pin 集合的本地缓存键（调用方须先经 [hasAllPinCacheElements] 自检）。
///
/// 分类 ID 集合排序后拼装：集合无序，不排序会对同一语义产生「等价键的多份缓存」，
/// 既浪费容量又让命中率失真（前端设计 §16.2）。
///
/// 价格区间是语义搜索的一次性收窄条件（方案 KTD3/KTD4）：不设区间时不追加后缀，
/// 与旧键逐字一致（历史缓存继续命中）；设了区间才追加 `:p{min}-{max}`，
/// 避免「带价格过滤的点集」被当成「全量点集」复用。
///
/// [leafCategoryIds] 已选叶子类目 ID 集合
/// [postType]        供需态
/// [radius]          半径档
/// [gridId]          网格 ID
/// [categoryVersion] 分类树版本号
/// [priceMin]        价格下限（元，可空）
/// [priceMax]        价格上限（元，可空）
/// [communityId]     小区实体 ID（可空；口语地址精确过滤，附在键尾）
///
/// 返回：可直接用于本地 KV 存储的字符串键
String buildPinCacheKey({
  required List<int> leafCategoryIds,
  required String postType,
  required String radius,
  required String gridId,
  required String categoryVersion,
  double? priceMin,
  double? priceMax,
  String? communityId,
}) {
  final sorted = [...leafCategoryIds]..sort();
  final priceSuffix = (priceMin == null && priceMax == null)
      ? ''
      : ':p${priceMin ?? ''}-${priceMax ?? ''}';
  final communitySuffix = (communityId == null || communityId.isEmpty)
      ? ''
      : ':c$communityId';
  return 'pins:${sorted.join(',')}:$postType:$radius:$gridId:$categoryVersion'
      '$priceSuffix$communitySuffix';
}
