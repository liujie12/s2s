/// 地图类目名称披露的分档与抑制规则（R1 / R4 / R8 / KD5 / KTD1）。
///
/// **为什么单独立文件**：这三条规则（按分辨率分档、单一叶子抑制、中景聚合开关）
/// 是产品口径而非绘制细节，且都要在单测里直接断言边界值。放进 `map_screen`
/// 就得靠 widget 测试间接覆盖，改一个阈值要跑整页。
///
/// 本文件只依赖领域层（分类树）与 NFR 常量真源，不 import Flutter。
library;

import '../../domain/category_tree.dart';
import '../../nfr_constants.dart';

/// 名称披露档位（R1 的三档）。
///
/// - [detail] 近景：保留单点，标三级类目名；
/// - [mid] 中景：保留单点，按二级聚簇并在簇/最大单元上标二级名；
/// - [far] 远景：沿用服务端预聚合簇，仅当簇带类目 ID 时标名（本次恒缺失，KD6）。
enum MarkerDisclosureTier {
  /// 近景档。
  detail,

  /// 中景档（默认 5 km 视野落在这里）。
  mid,

  /// 远景档。
  far,
}

/// 按当前地面分辨率判定档位（R1）。
///
/// 边界取**闭区间**：`m/px ≤ 近景上界` 为近景；`≤ 切换阈值` 为中景；其余为远景。
/// 闭区间是为了让「恰好等于阈值」有确定归属，避免浮点比较时两档都不认。
///
/// 参数：[metersPerPixel] 当前渲染视野的米/像素。
/// 返回：档位。
MarkerDisclosureTier markerTierOf(double metersPerPixel) {
  if (metersPerPixel <= NfrPerf.labelDetailMetersPerPixel) {
    return MarkerDisclosureTier.detail;
  }
  if (metersPerPixel <= NfrPerf.clusterModeSwitchMetersPerPixel) {
    return MarkerDisclosureTier.mid;
  }
  return MarkerDisclosureTier.far;
}

/// 生效筛选只剩单一叶子时是否抑制 Pin 名称（R8 / KD3）。
///
/// 抑制对所有档位生效：同屏同名的标签只会变成重复噪声，类目名改由条件带的
/// 类目 chip 承担 —— 那枚 chip 同时显示二级图标与名字。
///
/// 参数：[effectiveLeafCount] 生效筛选展开后的叶子数量。
/// 返回：恰为 1 时为真（0 表示未收窄，不抑制）。
bool suppressMarkerLabelsFor(int effectiveLeafCount) => effectiveLeafCount == 1;

/// 中景档是否按二级类目聚合（R3 / KD2 / KD5）。
///
/// 三个条件缺一不可：处于中景档、用户没有显式点选叶子。
/// 显式选了叶子时关闭聚合 —— 用户刚把多个叶子区分开，按二级合并会把这份
/// 区分直接抹掉（KD5）；此时保留单点并按三级名去重标注。
///
/// 参数：
/// - [tier]：当前档位；
/// - [explicitLeafSelection]：用户是否显式点选了具体叶子（不含「整类选中」的展开）。
/// 返回：需要按二级聚合时为真。
bool midTierAggregationFor({
  required MarkerDisclosureTier tier,
  required bool explicitLeafSelection,
}) => tier == MarkerDisclosureTier.mid && !explicitLeafSelection;

/// 叶子类目的三级名（R2 / R7）。
///
/// 参数：[leafCategoryId] 服务端叶子类目 ID。
/// 返回：类目名；ID 为空或分类树查不到时返回 null —— **不返回「未知」占位**，
///   调用方据此不标名（R7）。
String? leafCategoryNameOf(int? leafCategoryId) {
  if (leafCategoryId == null) return null;
  return leafCategoryById(leafCategoryId)?.name;
}

/// 二级类目名（按二级 ID，R3 / R4）。
///
/// 分类树只有「按叶子回溯」的入口，二级 ID 本身没有单点查询函数，故在此
/// 做一次浅遍历：树只有 5 个一级 × 5 个二级，成本可忽略；调用方还应按 ID
/// 预查缓存，避免每个 Marker 各遍历一次。
///
/// 参数：[midCategoryId] 二级类目 ID（如 `101`）。
/// 返回：二级名；查不到返回 null（同 R7 的降级取向）。
String? midCategoryNameOf(int? midCategoryId) {
  if (midCategoryId == null) return null;
  for (final top in categoryTree) {
    for (final mid in top.children) {
      if (mid.id == midCategoryId) return mid.name;
    }
  }
  return null;
}

/// 叶子所属二级类目名（按叶子 ID，R3）。
///
/// 参数：[leafCategoryId] 服务端叶子类目 ID。
/// 返回：其所属二级名；叶子未登记返回 null。
String? midCategoryNameOfLeaf(int? leafCategoryId) {
  if (leafCategoryId == null) return null;
  final path = categoryPathOf(leafCategoryId);
  return path.length >= 3 ? path[1].name : null;
}
