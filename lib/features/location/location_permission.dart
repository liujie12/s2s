/// 定位权限与三态（PRD §6.4.4）。
///
/// 权限三态 A/B 的判定：
/// - A「从未授权」：权限 denied 且无 [location_granted_once] 本地标记；
/// - B「曾授权后被关」：权限 denied/permanentlyDenied/restricted 且有标记；
/// - granted：已授权，交给地图取点。
///
/// A 与 B 必须靠本地持久化标记区分（§6.4.4 `:1232`–`:1233`）：系统 API 只回答
/// 「现在有没有权限」，不回答「以前有没有过」。首次成功取到坐标时写入
/// `location_granted_once = true`（见 [markGrantedOnce]）。
///
/// C「已授权但取点失败 ≥3 次」由地图侧取点回调驱动（§6.8），不在此处判定——
/// 它依赖 amap_map 的 onLocationChanged 连续失败计数，属取点而非权限问题。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 定位权限三态（PRD §6.4.4 A/B + granted）。
enum LocationPermissionPhase {
  /// 尚未评估权限（异步读盘/读权限中）。
  unknown,

  /// A：从未授权（denied 且无 granted_once 标记）→ 引导页 + 系统弹窗。
  neverGranted,

  /// B：曾授权后被关（denied/restricted 且有 granted_once 标记）→ 引导页 + 跳设置。
  revoked,

  /// 已授权（granted/limited）→ 交给地图取点。
  granted,
}

/// 权限状态 + granted_once 标记 → 三态归类（§6.4.4 A/B 判定）。
///
/// 独立为顶层纯函数以便单测锁定 A/B 区分：系统 API 只回答「现在有没有权限」，
/// 「以前有没有过」只能靠 [grantedOnce] 标记补足（§6.4.4 `:1232`–`:1233`）。
///
/// 参数：
///   [status] 系统返回的权限状态；
///   [grantedOnce] 是否曾成功定位（本地持久化标记）。
/// 返回：对应 [LocationPermissionPhase]。
LocationPermissionPhase classifyLocationPhase(
  PermissionStatus status,
  bool grantedOnce,
) {
  if (status.isGranted || status.isLimited) {
    return LocationPermissionPhase.granted;
  }
  // denied/permanentlyDenied/restricted 均属「无权限」，靠 granted_once 分 A/B。
  return grantedOnce
      ? LocationPermissionPhase.revoked
      : LocationPermissionPhase.neverGranted;
}

/// `location_granted_once` 本地标记的持久化键。带 `s2s.` 前缀避免与插件键冲突。
const String _kGrantedOnceKey = 's2s.location.grantedOnce';

/// 定位权限态的读写。
///
/// 用 Notifier 而非全局单例：Provider 可被测试覆写，无需真实权限与
/// SharedPreferences 即可测三态分支。
class LocationPermissionNotifier extends Notifier<LocationPermissionPhase> {
  @override
  LocationPermissionPhase build() {
    _evaluate();
    return LocationPermissionPhase.unknown;
  }

  /// 评估当前权限状态，归类到 A/B/granted 之一。
  ///
  /// 返回：评估完成（状态写入 [state]）。
  Future<void> evaluate() => _evaluate();

  /// 请求定位权限（A 态主按钮「开启位置权限」）。
  ///
  /// 返回：请求完成（状态随权限结果更新）。
  Future<void> requestPermission() async {
    final status = await Permission.locationWhenInUse.request();
    final grantedOnce = await _readGrantedOnce();
    state = classifyLocationPhase(status, grantedOnce);
  }

  /// 跳系统设置（B 态主按钮「去系统设置打开」），返回后重新评估。
  ///
  /// 返回：跳转并复评完成。
  Future<void> openSettings() async {
    await openAppSettings();
    await _evaluate();
  }

  /// 首次成功取到坐标时写入 granted_once 标记（§6.4.4 `:1233`）。
  ///
  /// 返回：落盘完成。
  Future<void> markGrantedOnce() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGrantedOnceKey, true);
  }

  /// 读取「是否曾成功定位过」标记（B 态判定依据）。
  ///
  /// 返回：是否曾成功定位。
  Future<bool> readGrantedOnce() => _readGrantedOnce();

  Future<void> _evaluate() async {
    final status = await Permission.locationWhenInUse.status;
    final grantedOnce = await _readGrantedOnce();
    state = classifyLocationPhase(status, grantedOnce);
  }

  Future<bool> _readGrantedOnce() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kGrantedOnceKey) ?? false;
  }
}

/// 定位权限态 Provider。
final locationPermissionProvider =
    NotifierProvider<LocationPermissionNotifier, LocationPermissionPhase>(
      LocationPermissionNotifier.new,
    );
