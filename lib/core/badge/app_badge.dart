/// Android 桌面角标桥（R11 / KTD13）。
///
/// 只消费 [unreadSummaryProvider] 的 `total`（KTD14）：Tab 数字、服务行条数与
/// 桌面角标指向同一个值，本层不另算未读、不轮询。
///
/// 平台纪律：
///   - **只有 Android 调用**（R11 / K9）：iOS 本期没接 APNs，角标会长期停在旧值，
///     故 [apply] 在非 Android 平台直接返回，不发通道调用；
///   - 数字上限沿用 [NfrChat.unreadBadgeMax]（超过 99 传 99，与「99+」同源）；
///   - 0 表示清除角标；
///   - 厂商接口失败或启动器不支持数字时由原生侧降级为红点（值 1）并在结果里
///     标注降级原因（KTD13）—— 本层只记录，不向用户报错：角标是增益信息。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../nfr_constants.dart';

/// 角标下发结果（原生回执的客户端模型）。
class AppBadgeResult {
  /// 构造结果。
  ///
  /// 参数：[applied] 是否已生效（含降级红点）；[degradedReason] 降级原因，
  ///   null 表示按数字角标生效；平台不支持时也带原因。
  const AppBadgeResult({required this.applied, this.degradedReason});

  /// 平台不支持（iOS / Web / 未注册通道）。
  static const AppBadgeResult unsupported =
      AppBadgeResult(applied: false, degradedReason: 'unsupported_platform');

  /// 是否已生效（数字或降级红点）。
  final bool applied;

  /// 降级原因（如 `dot_fallback` / `unsupported_launcher`）；null＝数字角标。
  final String? degradedReason;

  /// 是否发生了降级（生效但不是数字角标）。
  bool get degraded => degradedReason != null;
}

/// Android 桌面角标桥。
class AppBadge {
  /// 构造桥接。
  ///
  /// 参数：[channel] 平台通道（测试注入 MockMethodChannel 用，默认取 [channelName]）。
  AppBadge({MethodChannel? channel}) : _channel = channel ?? const MethodChannel(channelName);

  /// 通道名（与 Android 侧 `BadgeMethodHandler.CHANNEL_NAME` 同名）。
  static const String channelName = 'com.s2s.zhaoyazhao/badge';

  /// 下发角标方法名。
  static const String methodSetBadge = 'setBadge';

  /// 是否 Android（与 [PushService] 同一判定口径）。
  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  final MethodChannel _channel;

  /// 下发未读总数。
  ///
  /// 参数：[total] 未读总数（来自 [unreadSummaryProvider]）；0 表示清除角标。
  /// 返回：[AppBadgeResult]；非 Android 返回 [AppBadgeResult.unsupported]。
  Future<AppBadgeResult> apply(int total) async {
    if (!_isAndroid) return AppBadgeResult.unsupported;
    // 上限与「99+」同源：传 99 而不是 120，避免原生侧自己再定义一次上限。
    final count = total <= 0 ? 0 : math.min(total, NfrChat.unreadBadgeMax);
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>(
        methodSetBadge,
        <String, Object?>{'count': count},
      );
      final applied = raw?['applied'] == true;
      final reason = raw?['degraded'] as String?;
      return AppBadgeResult(applied: applied, degradedReason: reason);
    } on MissingPluginException {
      // iOS / 未注册通道：静默降级（本桥不参与功能判定）。
      return AppBadgeResult.unsupported;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('badge: 角标下发失败 ${e.code}');
      return AppBadgeResult(applied: false, degradedReason: e.code);
    }
  }
}

/// 角标桥 Provider（原生通道默认实例）。
final appBadgeProvider = Provider<AppBadge>((ref) => AppBadge());
