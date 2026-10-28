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
IconData? l2CategoryIcon(int? leafCategoryId) => leafCategoryId == null
    ? null
    : l2CategoryIconOfMid(midCategoryIdOf(leafCategoryId));

/// 二级分类图标（按二级类目 ID，如 `101`）。
///
/// 与 [l2CategoryIcon] 同一份真源，只是入参粒度不同：地图 Pin 只有叶子 ID，
/// 分类树节点本身就是二级 ID。
///
/// 参数：[midCategoryId] 二级类目 ID；null 或未登记返回 null（理由同上）。
/// 返回：该二级的字形。
IconData? l2CategoryIconOfMid(int? midCategoryId) =>
    midCategoryId == null ? null : categoryIconByName(_l2IconNameByMid[midCategoryId]);

/// 分类图标名 → 字形的**唯一解析入口**（服务端 `category.icon` 的消费点）。
///
/// 键取自 PRD §6.4.2 两表「Material 名」列：一级 5 行 + 二级 21 行
/// （其中 101/402 与一级同形，故实际键 24 个）。
///
/// 参数：[name] 服务端下发的 Material Symbols 名；null 返回 null。
/// 返回：对应字形；未登记名返回 null —— 与 [l2CategoryIcon] 同取向，
///   兜底会把「服务端新增了类目」伪装成「图标选错了」（没人会去查网络层）。
IconData? categoryIconByName(String? name) =>
    name == null ? null : _categoryIconByName[name];

/// 分类节点字形：服务端名 → 本地二级映射 → 一级枚举 → 中性图标。
///
/// 这个顺序就是数据链路的优先级：服务端下发是**可运营的真源**（改 DB 即生效，
/// 不必发版）；本地映射是离线 / 树版本落后时的兜底；一级枚举只在两者都查不到时用。
///
/// **本地兜底要按层级选入口**：叶子 ID（`10101`）要经 `~/100` 折到二级，
/// 而二级节点自己的 ID（`101`）再除一次会掉到 `1`（一级），查表必然落空 ——
/// 用 [CategoryNode.isLeaf] 分流，不写死层级阈值。
///
/// 参数：[node] 任意层级分类节点（一级 / 二级 / 叶子）。
/// 返回：绘制用字形（恒非 null）。
IconData nodeIconOf(CategoryNode node) =>
    categoryIconByName(node.icon) ??
    (node.isLeaf ? l2CategoryIcon(node.id) : l2CategoryIconOfMid(node.id)) ??
    node.topCategory?.icon ??
    neutralCategoryIcon;

/// 二级 ID → PRD 表里的 Material 名（21 行）。
///
/// 只存名字、不存字形：字形统一由 [_categoryIconByName] 解析，
/// 保证「服务端下发名」与「本地按 ID 兜底」走同一条查表路径，
/// 不会出现两处各写一套 Icons 常量而其中一处漏改。
const Map<int, String> _l2IconNameByMid = {
  101: 'work',
  102: 'work_history',
  103: 'person_search',
  201: 'apartment',
  202: 'real_estate_agent',
  203: 'hotel',
  204: 'support_agent',
  301: 'airport_shuttle',
  302: 'car_rental',
  303: 'sell',
  304: 'hail',
  401: 'inventory_2',
  402: 'volunteer_activism',
  403: 'search',
  404: 'pets',
  405: 'campaign',
  501: 'cleaning_services',
  502: 'home_repair_service',
  503: 'school',
  504: 'spa',
  505: 'directions_run',
};

/// Material 名 → 字形（PRD §6.4.2 一级 5 行 + 二级 21 行，去重后 24 键）。
///
/// 为什么用字符串键而不是「服务端下发图标号」：契约里 `icon` 本就是
/// Material Symbols 名（数据库设计 `category.icon` 列注释），改名即改配置，
/// 客户端只做「名字 → 内置字形」这一层映射，不引入新编号体系。
const Map<String, IconData> _categoryIconByName = {
  // 一级（§6.4.2 图标映射表）
  'work': Icons.work,
  'home': Icons.home,
  'directions_car': Icons.directions_car,
  'volunteer_activism': Icons.volunteer_activism,
  'build': Icons.build,
  // 二级（§6.4.2 二级图标映射表，2026-10-28 定稿）
  'work_history': Icons.work_history,
  'person_search': Icons.person_search,
  'apartment': Icons.apartment,
  'real_estate_agent': Icons.real_estate_agent,
  'hotel': Icons.hotel,
  'support_agent': Icons.support_agent,
  'airport_shuttle': Icons.airport_shuttle,
  'car_rental': Icons.car_rental,
  'sell': Icons.sell,
  'hail': Icons.hail,
  'inventory_2': Icons.inventory_2,
  'pets': Icons.pets,
  'campaign': Icons.campaign,
  'cleaning_services': Icons.cleaning_services,
  'home_repair_service': Icons.home_repair_service,
  'school': Icons.school,
  'spa': Icons.spa,
  'directions_run': Icons.directions_run,
  'search': Icons.search,
};

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
