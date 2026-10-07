/// city 域状态（[132] 前端段）：可选城市列表 Provider。
///
/// 城市列表仅作定位兜底「手动选城市」出口的数据源，选中城市用于确定地图中心，
/// 不在客户端做行政区过滤（DEC-24）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'city.dart';
import 'city_repository.dart';

/// 可选城市列表 Provider。
///
/// 用 [FutureProvider]：列表由网络拉取，加载/错误态由调用方按 AsyncValue 三态
/// 处理（编码规范 §5.6，禁 `.value!` 强解）。
final citiesProvider = FutureProvider<List<CityItem>>((ref) async {
  return ref.watch(cityRepositoryProvider).fetchCities();
});
