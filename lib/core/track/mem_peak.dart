/// 峰值内存采集（详细设计 §17.1 `mem_peak_mb`；编码规范 §5.1 缺口 #4）。
///
/// **为什么走平台通道而非引库**（§5.1/§17.1）：`mem_peak_mb` 是单个可观测性
/// 字段，Android 侧 `Debug.MemoryInfo` 一步即可拿到，不值得为此引
/// `device_info_plus`（引入即多一个插件初始化 + 权限面）。iOS 无等价一步接口，
/// **上报空值**（`readMb` 返回 null），不引库。
///
/// **失败一律返回 null、不抛**：内存峰值是埋点的辅助字段，采集失败（平台通道
/// 缺失 / 平台异常）不该让整条 `layer_switch` 上报失败 —— 那个字段宁可空，
/// 不能因为它丢失北极星四段耗时。
library;

import 'package:flutter/services.dart';

/// 峰值内存采集器（Android 平台通道，iOS/未实现返回 null）。
class MemPeakReader {
  /// 平台通道名（唯一实现处；Android 侧在 `MainActivity.kt` 注册同名通道）。
  static const String channelName = 'com.s2s.zhaoyazhao/mem_peak';

  /// 采集方法名（Android 侧 `setMethodCallHandler` 据此分发）。
  static const String methodGetMemPeakMb = 'getMemPeakMb';

  const MemPeakReader._();

  static const MethodChannel _channel = MethodChannel(channelName);

  /// 读取当前进程峰值内存（MB）。
  ///
  /// 返回：[Future<double?>] Android 为 `Debug.MemoryInfo.getTotalPss()`（kB）
  ///   ÷1024 的 MB 值；iOS / 平台通道未实现 / 平台异常时为 null（§17.1 报空）。
  static Future<double?> readMb() async {
    try {
      final value = await _channel.invokeMethod<double>(methodGetMemPeakMb);
      return value;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
