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
    this.priceLabel,
    this.priceValue,
  });

  final String id;
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

  /// 价格展示文案，如「50 元/小时」。无价格（如借物、求助）为 null。
  ///
  /// 存文案而非数值：单位随分类而变（元/小时、元/月、元/件），
  /// 存数值就得再存一个单位字段，且展示侧还要拼一次。
  final String? priceLabel;

  /// 价格排序用的数值（元）。无价格为 null。
  ///
  /// 与 [priceLabel] 并存而非从文案里解析：文案含单位且格式不固定
  /// （「面议」「50 元/小时」「1500-2000 元/月」），解析必然出现歧义，
  /// 而歧义在排序里的表现是「顺序看着差不多但就是不对」，极难被发现。
  ///
  /// **单位不可比是已知局限**：50 元/小时与 1500 元/月放在一起排没有实义。
  /// 本期先按裸数值排（PRD §6.4.3 只写了「价格升序/降序」，未定义跨单位口径），
  /// 待 §7.4.1 模板字段落地、单位随分类固定后再定归一化规则。
  final double? priceValue;
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
