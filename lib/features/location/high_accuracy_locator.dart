/// 发布前单次高精度定位。
///
/// **为什么不用 `amap_flutter_location`**（2026-10-17 真机实测，Android 13 / 小米）：
/// 该插件（3.0.0，2021 停更）在发布页只回调一条 `locationType=4` 的缓存点
/// （accuracy 550m），窗口内无任何 GPS/网络新点；同进程原生网络定位线程持续抛
/// `NumberFormatException: s == null`。而同期系统定位给本进程的精度是 1.7–15m，
/// 故改为直接取系统定位（`geolocator` → Android FusedLocationProvider/GPS）。
///
/// **坐标系**：系统定位返回 WGS-84，而全工程（地图/接口/落库）统一 GCJ-02
/// （PRD §6.4.1），因此取到点后必须做 [wgs84ToGcj02] 转换，否则会有约 500m 偏移。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

import '../../nfr_constants.dart';
import 'coordinate_transform.dart';
import 'location_center.dart';

/// 单次高精度定位器。
class HighAccuracyLocator {
  const HighAccuracyLocator();

  /// 拉起一次系统高精度定位。
  ///
  /// 参数：
  /// [timeout] 最长等待时间，默认 [NfrLocation.publishFixTimeoutMs]；
  /// 系统在时限内拿不到点会抛超时，由本方法吞掉并返回 null。
  ///
  /// 返回：GCJ-02 坐标的定位点；未授权、定位关闭、超时或无有效点时返回 null。
  Future<LocationFix?> locate({
    Duration timeout = const Duration(
      milliseconds: NfrLocation.publishFixTimeoutMs,
    ),
  }) async {
    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: timeout,
        ),
      );
      // 系统坐标是 WGS-84，必须转成工程统一的 GCJ-02 再落库/上图。
      final gcj = wgs84ToGcj02(
        lat: position.latitude,
        lng: position.longitude,
      );
      if (!isUsableLocationFix(
        lat: gcj.lat,
        lng: gcj.lng,
        accuracy: position.accuracy,
      )) {
        return null;
      }
      return LocationFix(
        lat: gcj.lat,
        lng: gcj.lng,
        accuracy: position.accuracy,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 高精度定位器 Provider（测试可 override）。
final highAccuracyLocatorProvider = Provider<HighAccuracyLocator>(
  (ref) => const HighAccuracyLocator(),
);

/// 发布取点：先做一次高精度定位，成功则同时回写会话最优点。
///
/// 参数：[ref] 组件引用。
///
/// 返回：含 [lat]/[lng]/[accuracy] 的记录；失败返回 null（调用方可退化到
/// [readPublishCoordinate] 的会话最优点）。
Future<({double lat, double lng, double accuracy})?> locateForPublish(
  WidgetRef ref,
) async {
  final fix = await ref.read(highAccuracyLocatorProvider).locate();
  if (kDebugMode) {
    debugPrint('[PUBLISH-LOCATE] accuracy=${fix?.accuracy}');
  }
  if (fix == null) return null;
  ref.read(locationFixProvider.notifier).update(
        lat: fix.lat,
        lng: fix.lng,
        accuracy: fix.accuracy,
      );
  return (lat: fix.lat, lng: fix.lng, accuracy: fix.accuracy);
}
