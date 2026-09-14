/// 五大分类的域模型（PRD §1.4.3 色板 / §6.4.2 Marker 规范 / §6.15 聚合阈值）。
///
/// 为什么放 `domain/` 而不是 `features/map/`：分类会被地图页、列表页、发布页、
/// 详情页四处消费。放在 map 目录下，会逼着详情页去 import 地图模块，
/// 那是把「谁先实现谁拥有」当成了归属依据。
///
/// **本文件刻意不 import Flutter。** 原先色/图标/阈值三样都挂在这里，
/// 为了 `Color` 与 `IconData` 必须 import `material.dart`；而聚合模块
/// （`features/map/clustering/`）刻意保持纯 Dart（POC-A 要在 Dart VM 里跑基准），
/// 于是它无法持有本枚举，只能靠一个 `int` 传分类 —— 那个 `int` 就是
/// `ListingCategory.id => index` 的由来，也是「枚举下标被当成服务端叶子类目 ID」
/// 这个 release 崩溃隐患的源头（详细设计 §10.4.1）。
///
/// 拆分后的归属：
/// - 本文件（纯 Dart）：枚举本体、[ListingCategoryProps.label]、
///   [ListingCategoryProps.clusterThreshold]、供需态及其映射函数；
/// - `listing_category_style.dart`（依赖 Flutter）：`color` / `deepColor` / `icon`。
///
/// 拆分依据不是「谁需要 Flutter」这种技术分类，而是「渲染口径」与「业务口径」
/// 本就是两件事：聚合阈值参与计算，配色只参与绘制。
library;

import '../core/network/api_exception.dart';

/// 五大分类。
///
/// 枚举顺序即 UI 中分类栏的展示顺序（PRD §6.4.1 ASCII 图：工作 房屋 车辆 生活 服务）。
///
/// **枚举下标不再对外暴露。** 服务端口径的分类标识是叶子类目 ID（如 `10101`，
/// 见 `category_tree.dart`），与本枚举下标（0..4）取值范围完全不同。
/// 由叶子类目 ID 求本枚举须走 `topCategoryOf`（查表），不得做下标转换。
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

/// 分类的业务属性（不含渲染样式，样式见 `listing_category_style.dart`）。
extension ListingCategoryProps on ListingCategory {
  /// 分类名（分类栏与图例用）。
  String get label => switch (this) {
    ListingCategory.work => '工作',
    ListingCategory.house => '房屋',
    ListingCategory.vehicle => '车辆',
    ListingCategory.life => '生活',
    ListingCategory.service => '服务',
  };

  /// 聚合阈值：同一网格内达到此条数才聚成簇，未达则各自画单点 Pin（PRD §6.15）。
  ///
  /// 差异化而非统一阈值的依据是各类目真实密度（工作最密故 3 条即聚，
  /// 生活/车辆/服务属低密度长尾故 8 条才聚）。统一阈值会让工作类在城区糊成一片、
  /// 而服务类永远聚不起来。
  ///
  /// 留在纯 Dart 侧而不随配色搬走：它是**参与聚合计算**的输入，
  /// 聚合模块要能直接读到；配色只在绘制时用得上。
  int get clusterThreshold => switch (this) {
    ListingCategory.work => 3,
    ListingCategory.house => 5,
    ListingCategory.vehicle => 8,
    ListingCategory.life => 8,
    ListingCategory.service => 8,
  };
}

/// 供需属性（PRD §6.4.2：资源＝实心圆，需求＝空心圆 + ? 角标）。
enum SupplyDemand {
  /// 资源：我有，可提供。**契约里叫 `"resource"`，与此处不同名**，
  /// 转换须走 [supplyDemandFromApi]。
  supply,

  /// 需求：我要，求提供。契约里恰好也叫 `"demand"` —— 正是这个「一半同名」
  /// 让 `values.byName` 的错误实现能跑过一半用例（详细设计 §10.4.2）。
  demand,
}

/// 供需的显示属性。
extension SupplyDemandProps on SupplyDemand {
  String get label => switch (this) {
    SupplyDemand.supply => '资源',
    SupplyDemand.demand => '需求',
  };
}

/// 供需态：契约字符串 → 本地枚举（详细设计 §10.4.2）。
///
/// **必须显式 switch，不能用 `values.byName`**：服务端用 `"resource"`，
/// 本地枚举叫 `supply`，两者不同名；而 `"demand"` 恰好同名，会让 `byName`
/// 的错误实现「一半能跑」—— 一半用例通过的缺陷比全错的难查得多，
/// 它会让人相信「映射逻辑是对的，只是某条数据有问题」。
///
/// [raw] 契约 `PostTypeEnum` 值，取值 `"resource"` / `"demand"`
///
/// 返回：对应的本地枚举
///
/// 抛出：[ApiException] —— 出现契约外的值
SupplyDemand supplyDemandFromApi(String raw) => switch (raw) {
  'resource' => SupplyDemand.supply,
  'demand' => SupplyDemand.demand,
  _ => throw ApiException.parse('未知 post_type: $raw'),
};

/// 供需态：本地枚举 → 契约字符串。
///
/// 与 [supplyDemandFromApi] 成对提供：发布/筛选请求要往上传这个值，
/// 缺了它调用方就会就地写 `sd.name`，而 `SupplyDemand.supply.name == 'supply'`
/// 并不是契约值 `"resource"` —— 且这种错在「只测 demand」时同样看不出来。
///
/// [sd] 本地枚举
///
/// 返回：契约 `PostTypeEnum` 值
String toApiPostType(SupplyDemand sd) => switch (sd) {
  SupplyDemand.supply => 'resource',
  SupplyDemand.demand => 'demand',
};

/// 供需态：紧凑数组整数码 → 本地枚举（详细设计 §10.4.2）。
///
/// 用于 `/map/pins` 的 schema 第 5 列。0/1 的含义由契约 `PinsCompactResponse`
/// 固定，**不得按枚举 index 推导** —— `SupplyDemand` 的 index 恰好也是 0/1，
/// 这个巧合会让 `values[code]` 在当前版本能跑，等枚举新增值或调序时才炸，
/// 而那时没人会想到来查这里。显式 switch 不是啰嗦，是把巧合换成约定。
///
/// [code] 紧凑数组中的 `type` 列，取值 0 或 1
///
/// 返回：对应的本地枚举
///
/// 抛出：[ApiException] —— 出现契约外的码值
SupplyDemand supplyDemandFromCompact(int code) => switch (code) {
  0 => SupplyDemand.supply,
  1 => SupplyDemand.demand,
  _ => throw ApiException.parse('未知 type 码: $code'),
};
