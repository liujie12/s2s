/// 信息条目域模型（PRD §6.4.2 Marker / §6.4.3 列表卡片共用）。
library;

import 'dart:math' as math;

import 'listing_category.dart';

/// 一条资源或需求信息。
///
/// 字段刻意只保留「地图与列表都要用」的部分。详情页专属的模板字段（§7.4.1）
/// 不放这里 —— 列表一次拉几百条，带上模板字段等于把详情页的数据量乘以条数。
class Listing {
  const Listing({
    required this.id,
    required this.title,
    required this.category,
    required this.supplyDemand,
    required this.latitude,
    required this.longitude,
    required this.createdAt,
    this.price,
    this.priceUnit,
  });

  /// 帖子 ID（服务端口径 `int64`，契约 `PostIdPath`）。
  ///
  /// 用 `int` 而不是 `String`（详细设计 §10.4.3），三条理由：
  /// 1. **相等性陷阱**：`"1001"`、`"1001 "`、`"01001"` 在 Dart 里是三个不同的
  ///    String，对服务端却是同一个（或非法）ID。用它作 Map 键、去重键、`==`
  ///    判断时，任何一次多余的格式化都会静默产生重复项。
  /// 2. **int64 精度**：若中途经过 `dynamic` → `double` 的转换（JSON 解析在
  ///    某些路径上会），大于 2^53 的 ID 会丢精度。用 `int` 直接消除，代价为零。
  /// 3. **校验点收敛**：`String` 转数字要校验，`int` 转字符串永不失败。
  ///    选 `int` 是把校验点收敛到唯一入口（`fromJson`）。
  final int id;
  final String title;
  final ListingCategory category;
  final SupplyDemand supplyDemand;

  /// 纬度（GCJ-02）。
  ///
  /// 坐标系在 PRD §6.4.1 已定为 GCJ-02 全局统一。若接入 WGS-84 数据源
  /// （如设备原始 GPS）须先转换再落库，两种坐标混存会让偏移只在部分点上出现，
  /// 极难定位。
  final double latitude;

  /// 经度（GCJ-02）。
  final double longitude;

  /// 发布时间（PRD §6.4.3 卡片「发布时间」+ 排序「最新」）。
  ///
  /// 必填而非可空：列表页「最新」排序无法为缺失时间的条目定义位置，
  /// 允许为空就得在排序里造一个假时间，那等于让数据缺陷伪装成排序结果。
  final DateTime createdAt;

  /// 价格数值（元）。「面议」或无价格场景为 null（PRD §13.2 `price` 允许 NULL）。
  ///
  /// 字段名与类型对齐 §13.2 `post.price`（decimal(12,2)）。Dart 侧用 double
  /// 承载，接后端时须注意 decimal→double 的精度问题：金额超过 2^53 分才会失真，
  /// 本业务量级不会触及，但若日后出现按分计价的大额场景需改回字符串或整型分。
  final double? price;

  /// 价格单位（PRD §13.2 `post.price_unit`，取模板 `price_units` 之一）。
  ///
  /// **与 [price] 分开存而非合成一个「50 元/小时」的文案字段**：文案不可比较，
  /// 排序时从文案反解单位必然出现歧义（「面议」「1500-2000 元/月」都无法解析），
  /// 而歧义在排序里的表现是「顺序看着差不多但就是不对」，极难被发现。
  ///
  /// 展示文案由 [priceLabel] 现拼，不落库 —— 落库会产生两份可能不一致的真相。
  final String? priceUnit;

  /// 价格展示文案，由 [price] 与 [priceUnit] 拼出，如「50 元/小时」。
  ///
  /// PRD §5.8 允许价格为空（「面议」），此时返回 null 由调用方决定是否留白。
  String? get priceLabel {
    if (price == null) return null;
    // 去掉整数价格的小数尾巴：「50 元」而不是「50.0 元」。
    final String amount = price! % 1 == 0
        ? price!.toInt().toString()
        : price!.toStringAsFixed(2);
    return priceUnit == null ? '$amount 元' : '$amount 元/$priceUnit';
  }
}

/// 地球平均半径（米）。
const double _earthRadiusMeters = 6371000;

/// 两点间大圆距离（米）。
///
/// 用 haversine 而非平面近似：范围筛选最大档 10km，平面近似在该尺度下误差虽小，
/// 但「全城」档之外未来若加省际场景，平面近似会明显失真。haversine 成本可忽略。
///
/// 参数为两点的经纬度（度）。返回米。
double distanceInMeters(double lat1, double lng1, double lat2, double lng2) {
  const double toRad = math.pi / 180;
  final double dLat = (lat2 - lat1) * toRad;
  final double dLng = (lng2 - lng1) * toRad;
  final double a =
      math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(lat1 * toRad) *
          math.cos(lat2 * toRad) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return _earthRadiusMeters * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}
