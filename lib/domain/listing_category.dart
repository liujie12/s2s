/// 五大分类的域模型（PRD §1.4.3 色板 / §6.4.2 Marker 规范 / §6.15 聚合阈值）。
///
/// 为什么放 `domain/` 而不是 `features/map/`：分类会被地图页、列表页、发布页、
/// 详情页四处消费。放在 map 目录下，会逼着详情页去 import 地图模块，
/// 那是把「谁先实现谁拥有」当成了归属依据。
///
/// 为什么色/图标/阈值三样挂在同一个枚举上：PRD 里它们分散在 §1.4.3、§6.4.2、
/// §6.15 三节，但对代码而言是同一个实体的三个属性。分成三张表意味着新增分类时
/// 要记得改三个地方，漏一处的表现是「颜色对了但永远不聚合」这类难查的错。
library;

import 'package:flutter/material.dart';

import '../design_tokens.dart';

/// 五大分类。
///
/// 枚举顺序即 UI 中分类栏的展示顺序（PRD §6.4.1 ASCII 图：工作 房屋 车辆 生活 服务）。
enum ListingCategory {
  /// 工作 · 招聘/求职
  work,

  /// 房屋 · 出租/求租
  house,

  /// 车辆 · 拼车/顺风车/租车
  vehicle,

  /// 生活 · 二手/借物/互助
  life,

  /// 服务 · 家政/维修/教学
  service,
}

/// 分类的显示与聚合属性。
extension ListingCategoryProps on ListingCategory {
  /// 分类名（分类栏与图例用）。
  String get label => switch (this) {
    ListingCategory.work => '工作',
    ListingCategory.house => '房屋',
    ListingCategory.vehicle => '车辆',
    ListingCategory.life => '生活',
    ListingCategory.service => '服务',
  };

  /// 分类原色（PRD §1.4.3）。
  ///
  /// 只用于 Pin 填充、图例圆点等**图形**用途。承载白色文字的底须改用 [deepColor]
  /// —— 原色白字仅 2.54–4.23:1，五类全部不过 WCAG AA 4.5:1（design_tokens.dart:74）。
  Color get color => Color(switch (this) {
    ListingCategory.work => AppCategoryColors.catWork,
    ListingCategory.house => AppCategoryColors.catHouse,
    ListingCategory.vehicle => AppCategoryColors.catVehicle,
    ListingCategory.life => AppCategoryColors.catLife,
    ListingCategory.service => AppCategoryColors.catService,
  });

  /// 分类深色变体，用于承载白字的底。
  Color get deepColor => Color(switch (this) {
    ListingCategory.work => AppCategoryColors.catWorkDeep,
    ListingCategory.house => AppCategoryColors.catHouseDeep,
    ListingCategory.vehicle => AppCategoryColors.catVehicleDeep,
    ListingCategory.life => AppCategoryColors.catLifeDeep,
    ListingCategory.service => AppCategoryColors.catServiceDeep,
  });

  /// 分类图标（PRD §6.4.2 图标映射表，Material Symbols filled）。
  ///
  /// Flutter 内置的 Material Icons 恰好就是 Material Symbols 同一套设计网格，
  /// 故直接取内置常量，不再自带 SVG 资产 —— 自带等于把上游已做过 20/24px
  /// 网格对齐的图形重新描一遍，且日后升级无从同步。
  IconData get icon => switch (this) {
    ListingCategory.work => Icons.work,
    ListingCategory.house => Icons.home,
    ListingCategory.vehicle => Icons.directions_car,
    ListingCategory.life => Icons.volunteer_activism,
    ListingCategory.service => Icons.build,
  };

  /// 聚合阈值：同一网格内达到此条数才聚成簇，未达则各自画单点 Pin（PRD §6.15）。
  ///
  /// 差异化而非统一阈值的依据是各类目真实密度（工作最密故 3 条即聚，
  /// 生活/车辆/服务属低密度长尾故 8 条才聚）。统一阈值会让工作类在城区糊成一片、
  /// 而服务类永远聚不起来。
  int get clusterThreshold => switch (this) {
    ListingCategory.work => 3,
    ListingCategory.house => 5,
    ListingCategory.vehicle => 8,
    ListingCategory.life => 8,
    ListingCategory.service => 8,
  };

  /// 与 `ClusterPoint.categoryId` 互转用的稳定整数 ID。
  ///
  /// 用 `index` 而非自定义常量：聚合模块（grid_cluster.dart）刻意不 import Flutter，
  /// 无法直接持有本枚举，只能靠 int 传递。枚举顺序一旦调整此 ID 即漂移，
  /// 故枚举顺序视为契约，新增分类只能追加在末尾。
  int get id => index;
}

/// 从 `ClusterPoint.categoryId` 还原分类。
///
/// 参数 [id] 须来自 [ListingCategoryProps.id]，越界即为编程错误（而非脏数据），
/// 故用 assert 而不做静默兜底 —— 兜底成某个分类会让配色错误看起来像设计问题。
ListingCategory listingCategoryFromId(int id) {
  assert(
    id >= 0 && id < ListingCategory.values.length,
    'categoryId 越界：$id，合法区间 0..${ListingCategory.values.length - 1}',
  );
  return ListingCategory.values[id];
}

/// 供需属性（PRD §6.4.2：资源＝实心圆，需求＝空心圆 + ? 角标）。
enum SupplyDemand {
  /// 资源：我有，可提供
  supply,

  /// 需求：我要，求提供
  demand,
}

/// 供需的显示属性。
extension SupplyDemandProps on SupplyDemand {
  String get label => switch (this) {
    SupplyDemand.supply => '资源',
    SupplyDemand.demand => '需求',
  };
}
