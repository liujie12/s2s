/// 设备标识提供者（详细设计 §11.2 / 编码规范 §5.1，计划 U3 / Assumptions）。
///
/// 纪律：
///   - 首次启动自生成 UUID v4 写入 shared_preferences，此后固定（§11.2）；
///   - **惰性生成**：构造不读盘不写盘，首次 [getOrCreate] 才生成落盘
///     （计划 Assumptions：隐私门不靠「首个请求必在同意之后」的时序假设
///     兜底，是否外发由 HeaderInterceptor 的同意态硬门控制）；
///   - **不可信、可被重置**：该值只是应用私有随机数，用户清除应用数据/
///     卸载重装后即换新值，不得用于身份认定或风控主键；
///   - **明确不采集 IMEI/MAC/IDFA/OAID**（编码规范 §5.1）。
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// 设备标识提供者（惰性生成 + 内存缓存 + 本地持久化）。
class DeviceIdProvider {
  /// 构造提供者；构造时不进行任何 I/O（惰性，计划 Assumptions）。
  ///
  /// 参数：
  ///   [prefs] 可选的持久化实例（测试注入用）；生产为 null 时首次读取
  ///           自行获取 shared_preferences 单例；
  ///   [uuid]  可选的 UUID 生成器（默认标准 [Uuid]，业务不注入）。
  DeviceIdProvider({SharedPreferences? prefs, Uuid? uuid})
      : _prefsOverride = prefs,
        _uuid = uuid ?? const Uuid();

  /// 持久化键名（带 `s2s.` 前缀避免与其他插件键冲突，
  /// 与 privacy_consent.dart 的键名约定一致）。
  static const String storageKey = 's2s.device.id';

  /// 测试注入的持久化实例；null 时懒加载真实单例。
  final SharedPreferences? _prefsOverride;

  /// UUID v4 生成器（标准实现，不自拼随机串：碰撞会让设备统计串号）。
  final Uuid _uuid;

  /// 进程内缓存：首次读取后固定，重复调用直接返回（§11.2「此后固定」）。
  String? _cached;

  /// 取设备标识：首次调用生成 UUID v4 并落盘，其后返回同一值。
  ///
  /// 返回：[Future<String>] 本机设备标识（UUID v4 小写形态）。
  /// 副作用：仅首次调用写入一次 shared_preferences；已落盘值优先复用
  ///   （跨启动固定），内存缓存优先于再次读盘。
  Future<String> getOrCreate() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = _prefsOverride ?? await SharedPreferences.getInstance();
    final stored = prefs.getString(storageKey);
    if (stored != null && stored.isNotEmpty) {
      _cached = stored;
      return stored;
    }

    final generated = _uuid.v4();
    await prefs.setString(storageKey, generated);
    _cached = generated;
    return generated;
  }
}
