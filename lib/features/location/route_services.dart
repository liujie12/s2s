/// 起终点选择页所需的两个网络服务入口（候选搜索、驾车摘要）。
///
/// **为什么单独成文件**：这两个 typedef 与 Provider 描述的是「页面依赖哪个网络
/// 能力」，属于 location 层契约，不属于 UI。放在页面文件里会让「换成后端代理只
/// 替换 location 层」这条退路失效（KTD5），也会把网络依赖混进 widget 测试的
/// 导入图。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'amap_degrade.dart';
import 'driving_route.dart';
import 'poi_search.dart';

/// POI 候选搜索的可覆盖入口（widget 测试注入假实现）。
///
/// 参数：[keywords] 关键词；[lng]/[lat] 当前定位（排序偏置，可空）。
/// 返回：候选列表（失败为空列表）。
typedef PoiSearchFn =
    Future<List<PoiSuggestion>> Function({
      required String keywords,
      double? lng,
      double? lat,
      void Function(AmapDegradeReason reason)? onDegraded,
    });

/// 驾车路径的可覆盖入口（widget 测试注入假实现）。
///
/// 参数：起点与终点的 GCJ-02 坐标。
/// 返回：路径摘要；失败为 null。
typedef DrivingSummaryFn =
    Future<DrivingSummary?> Function({
      required double originLng,
      required double originLat,
      required double destinationLng,
      required double destinationLat,
      void Function(AmapDegradeReason reason)? onDegraded,
    });

/// POI 候选搜索 Provider（默认指向高德真实现，测试可覆写）。
final poiSearchFnProvider = Provider<PoiSearchFn>((ref) {
  return ({
    required String keywords,
    double? lng,
    double? lat,
    void Function(AmapDegradeReason reason)? onDegraded,
  }) => searchPoiSuggestions(
    keywords: keywords,
    lng: lng,
    lat: lat,
    onDegraded: onDegraded,
  );
});

/// 驾车路径 Provider（默认指向高德真实现，测试可覆写）。
final drivingSummaryFnProvider = Provider<DrivingSummaryFn>((ref) {
  return ({
    required double originLng,
    required double originLat,
    required double destinationLng,
    required double destinationLat,
    void Function(AmapDegradeReason reason)? onDegraded,
  }) => fetchDrivingSummary(
    originLng: originLng,
    originLat: originLat,
    destinationLng: destinationLng,
    destinationLat: destinationLat,
    onDegraded: onDegraded,
  );
});
