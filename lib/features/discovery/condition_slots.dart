/// 条件槽位枚举。
///
/// 为什么单独成文件：它被「持久筛选 / 语义槽位 / 投影 / 写回路由」四处共用。
/// 放进任一侧都会造成 `search_intent.dart` 与 `effective_filter.dart`
/// 互相 import 的循环依赖，而这个枚举本身没有任何依赖。
library;

/// 一个可被展示、被修改、被删除的条件维度。
enum ConditionSlot {
  /// 搜索半径。
  radius,

  /// 供需方向。
  supplyDemand,

  /// 类目（叶子）。
  category,

  /// 价格区间。
  price,

  /// 地点锚点。
  anchor,

  /// 小区实体。
  community,
}
