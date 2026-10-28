/// 五大分类的**渲染样式**（PRD §1.4.3 色板 / §6.4.2 图标映射表）。
///
/// 为什么与 `listing_category.dart` 分成两个文件：`Color` 与 `IconData` 来自
/// Flutter，而分类枚举需要被聚合模块（`features/map/clustering/`）直接持有 ——
/// 那里刻意保持纯 Dart，好让 POC-A 基准能用 `dart run` 跑（不受渲染与设备干扰）。
/// 把样式留在枚举本体上，等于逼聚合层要么引入 Flutter、要么改用一个 `int` 代传
/// 分类，后者正是「枚举下标被当成服务端叶子类目 ID」这个 release 崩溃隐患的
/// 由来（详细设计 §10.4.1）。
///
/// 拆开后二者的界线是语义而非技术：`clusterThreshold` 参与**计算**故留在业务侧，
/// 色与图标只参与**绘制**故归此处。
///
/// 用法：渲染层 `import 'listing_category_style.dart'`，扩展方法自动可用。
library;

import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'category_tree.dart';
import 'listing_category.dart';

/// 分类的绘制属性。
extension ListingCategoryStyle on ListingCategory {
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
}

/// 二级分类图标（PRD §6.4.2「二级图标映射表」，2026-10-28 定稿）。
///
/// 参数：[leafCategoryId] 服务端叶子类目 ID（如 `10101`）；传 null 表示未知叶子。
/// 返回：该叶子所属二级的字形；叶子未登记或为 null 时返回 null。
///
/// **返回 null 而不兜底成某个字形**：调用方应退回一级图标
/// （[ListingCategoryStyle.icon]），再查不到才用 [neutralCategoryIcon]。
/// 在域层兜底会把「分类树落后」（§16.4 预期内状态）伪装成「图标选错了」。
///
/// 为什么按叶子 ID 查而不是给二级另立枚举：分类树本身只有节点 ID，
/// 再造一套二级枚举等于同一事实两份记录，发布页 / 筛选页还要多一次映射。
///
/// 为什么与一级图标同处一个文件：两者都是「分类 → 绘制属性」的同一职责，
/// 分开放会让渲染层各 import 一处，日后加图标尺寸 token 又要再裂一次。
IconData? l2CategoryIcon(int? leafCategoryId) {
  if (leafCategoryId == null) return null;
  return switch (midCategoryIdOf(leafCategoryId)) {
    101 => Icons.work,
    102 => Icons.work_history,
    103 => Icons.person_search,
    201 => Icons.apartment,
    202 => Icons.real_estate_agent,
    203 => Icons.hotel,
    204 => Icons.support_agent,
    301 => Icons.airport_shuttle,
    302 => Icons.car_rental,
    303 => Icons.sell,
    304 => Icons.hail,
    401 => Icons.inventory_2,
    402 => Icons.volunteer_activism,
    403 => Icons.search,
    404 => Icons.pets,
    405 => Icons.campaign,
    501 => Icons.cleaning_services,
    502 => Icons.home_repair_service,
    503 => Icons.school,
    504 => Icons.spa,
    505 => Icons.directions_run,
    _ => null,
  };
}

/// 分类树查表失败时的中性配色（详细设计 §10.4.1 第 3 步的降级取向）。
///
/// 用途：`topCategoryOf` 返回 `null`（本地分类树版本落后于服务端数据，
/// §16.4 明确规定这是**预期内状态**、不报错）时，Pin 仍要画出来。
///
/// 为什么必须有这个常量、而不让调用方各自挑一个灰：**不能兜底成某个真实分类色**。
/// 兜底成蓝色会让「分类树过期」这个数据问题伪装成「配色错了」的设计问题 ——
/// 后者没人会去查网络层。用一个明显不属于五色板的中性灰，异常态才看得出来。
Color get neutralCategoryColor => Color(AppColors.textSecondary);

/// 分类树查表失败时的中性图标。
///
/// `help_outline` 而非某个分类图标：同上，要让「未知」看起来就是未知。
const IconData neutralCategoryIcon = Icons.help_outline;
