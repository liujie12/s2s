/// 探索页请求参数组装（[126] 前端段）：把本地筛选态翻译成契约参数。
///
/// 为什么把这段单独成文件且做成**纯函数**：五要素的组装规则（叶子类目展开、
/// 供需双选的两次请求切分）都是「同一个输入必须得到同一个输出」的确定性映射，
/// 是这条链路里最容易写错、也最容易测的部分。放进 Widget 或 Provider 内部会让
/// 它们只能靠集成测试验证，而集成测试恰好漏「转换静默错位」这类不抛异常但值不对
/// 的缺陷（详细设计 §10.4 反复强调的陷阱）。
///
/// **缩放换算不在此文件**：`mpp ↔ zoom` 的唯一实现处是
/// `MapProjection.zoomForMetersPerPixel`（`features/map/map_projection.dart`），
/// 本文件不再重复一份（编码规范 §1.1）。
library;

import '../../domain/category_tree.dart';
import '../../domain/listing_category.dart';

/// 把「一级大类筛选」展开为契约要的**叶子类目 ID** 列表。
///
/// 契约 `/map/pins` 与 `/posts/search` 的 `category_ids` 是**叶子类目 ID**
/// （如 `10101`），而本地筛选态 [ListingCategory] 是五大类（1..5）。
/// 直接传 1..5 不会报错，只会**恒返回空结果** —— 服务端按 `leaf_category_id`
/// 过滤，1..5 匹配不到任何行，而空结果在地图上表现为「这个分类下没有数据」，
/// 极难被识别为参数错误。故必须在此展开。
///
/// 空集（筛选栏的「全部」）展开为**全部 48 个叶子**：契约 `category_ids`
/// 为 `minItems: 1` 且无「全部」语义，只能显式枚举。
///
/// [selectedTops] 已选一级大类；空集表示全部分类。
/// 返回：叶子类目 ID 列表（顺序取自 [leafCategories]，稳定可断言）。
List<int> leafCategoryIdsFor(Set<ListingCategory> selectedTops) {
  if (selectedTops.isEmpty) {
    return [for (final leaf in leafCategories) leaf.id];
  }
  return [
    for (final leaf in leafCategories)
      if (leaf.topCategory != null && selectedTops.contains(leaf.topCategory))
        leaf.id,
  ];
}

/// 把「供需筛选」切分为契约可表达的 `post_type` 单值序列。
///
/// **契约只收单值**（`PostTypeEnum` = `resource`/`demand`，缺失/多值回 40001），
/// 而 PRD §6.4.1 明确筛选栏「资源 ○ 需求（**可都选**）」。两者之间的缝由本函数
/// 承担：双选即切分为两个单值，由调用方**并发发两次请求**再合并
/// （2026-10-08 用户裁定「方案 1：双选时并发两个请求」）。
///
/// 顺序固定为 resource 在前、demand 在后：请求顺序稳定，合并结果与断言才可复现。
///
/// [selected] 已选供需态；空集表示「都不看」，返回空列表（调用方据此不发请求，
/// 与 `DiscoveryFilter.supplyDemand` 空集语义一致——空集不是全选）。
/// 返回：0/1/2 个契约 `post_type` 值。
List<String> postTypesFor(Set<SupplyDemand> selected) {
  return [
    if (selected.contains(SupplyDemand.supply)) toApiPostType(SupplyDemand.supply),
    if (selected.contains(SupplyDemand.demand)) toApiPostType(SupplyDemand.demand),
  ];
}
