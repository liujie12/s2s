/// 推送服务（B2-2 阶段 2）：厂商 token 生命周期 + 通知权限 + 点击事件。
///
/// 与插件选型解耦：厂商 SDK 由原生侧（当前小米，`android/app/src/.../push/`）
/// 通过同名 Platform Channel 暴露能力，本层只做编排：
/// 注册 → 取 token → `POST /users/me/devices`（[PushDeviceRepository]）。
///
/// 纪律（详设 §10.2.2）：
/// - 权限**不在冷启动首屏**申请，由「发布成功」等产生通知预期的交互点触发；
/// - 权限被拒不上报（没有 token），由站内通知中心兜底；
/// - 登出不主动清本地 token（服务端 logout 已清 `device.push_token`）；
/// - 上报失败只记 debug 日志，不向用户抛错（推送是尽力而为的旁路）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'push_device_repository.dart';

/// token 上报函数（生产实现 = [PushDeviceRepository.upsert]，测试可注入假实现）。
typedef PushTokenReporter = Future<void> Function(PushChannel channel, String token);

/// 推送服务。
class PushService {
  /// 构造服务并挂上原生回调。
  ///
  /// 参数：
  ///   [reporter] token 上报函数（生产传 `repository.upsert`）；
  ///   [channel]  平台通道（测试注入 MockMethodChannel 用，默认取 [channelName]）。
  PushService(
    this._reporter, {
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName) {
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// 平台通道名（与 Android 侧 `PushMethodHandler.CHANNEL_NAME` 同名）。
  static const String channelName = 'com.s2s.zhaoyazhao/push';

  /// 触发厂商注册。
  static const String methodRegister = 'register';

  /// 读取已缓存 token。
  static const String methodGetToken = 'getToken';

  /// 申请 Android 13+ 通知权限。
  static const String methodRequestPermission = 'requestPermission';

  /// 读取「App 未启动时点击通知」暂存的点击内容（原生侧读取后清除）。
  static const String methodGetInitialClick = 'getInitialClick';

  /// 原生 → Dart：token 到达。
  static const String eventToken = 'onToken';

  /// 原生 → Dart：通知被点击。
  static const String eventClick = 'onClick';

  /// 原生返回：注册已发起。
  static const String statusOk = 'ok';

  /// 需要补报 token 的通道（原生侧已实现小米 + 华为）。
  static const List<PushChannel> _probeChannels = [
    PushChannel.hw,
    PushChannel.mi,
  ];

  final PushTokenReporter _reporter;
  final MethodChannel _channel;
  final StreamController<Map<String, Object?>> _clicks =
      StreamController<Map<String, Object?>>.broadcast();

  /// 通知点击事件流（App 存活时；落点由 [pushClickTargetOf] 解析，R16a）。
  Stream<Map<String, Object?>> get clicks => _clicks.stream;

  /// 取「App 未启动时点击通知」暂存的点击内容（一次性，原生侧读取后清除）。
  ///
  /// 参数：无。
  /// 返回：点击载荷；非 Android / 无记录 / 通道异常时为 null。
  Future<Map<String, Object?>?> readInitialClick() async {
    if (!_isAndroid) return null;
    try {
      return await _channel.invokeMapMethod<String, Object?>(
        methodGetInitialClick,
      );
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('push: 读取初始点击失败 ${e.code}');
      return null;
    }
  }

  /// 是否 Android（当前小米、华为通道有原生实现；iOS APNs 待接入）。
  bool get _isAndroid => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 登录成功后调用：发起注册并补报各通道已缓存的 token。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]；未配置/非 Android/失败均静默返回。
  Future<void> registerIfAvailable() async {
    if (!_isAndroid) return;
    try {
      final status = await _channel.invokeMethod<String>(methodRegister);
      if (status != statusOk) {
        if (kDebugMode) debugPrint('push: 未配置厂商凭据，跳过注册（$status）');
        return;
      }
      await _reportCachedTokens();
    } on MissingPluginException {
      // iOS / 未注册通道：静默降级。
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('push: 注册失败 ${e.code}');
    }
  }

  /// 申请系统通知权限（Android 13+）。
  ///
  /// 参数：无。
  /// 返回：是否已授权；非 Android/异常时返回 false。
  Future<bool> requestPermission() async {
    if (!_isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>(methodRequestPermission) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('push: 权限申请失败 ${e.code}');
      return false;
    }
  }

  /// 补报一次各通道已缓存的 token（token 刷新后由前端主导重报的场景）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> reportTokenIfAny() async {
    if (!_isAndroid) return;
    try {
      await _reportCachedTokens();
    } on MissingPluginException {
      // 未接入该通道：静默降级。
    } on PlatformException catch (e) {
      if (kDebugMode) debugPrint('push: 读取推送凭据失败 ${e.code}');
    }
  }

  /// 逐通道读取原生缓存的 token 并上报。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]；某通道读取失败不影响其它通道。
  Future<void> _reportCachedTokens() async {
    for (final channel in _probeChannels) {
      try {
        final token = await _channel.invokeMethod<String>(
          methodGetToken,
          {'channel': channel.wire},
        );
        await _report(channel, token);
      } on PlatformException catch (e) {
        if (kDebugMode) debugPrint('push: ${channel.wire} 读取推送凭据失败 ${e.code}');
      }
    }
  }

  /// 原生事件分发。
  ///
  /// 参数：[call] 原生调用（`onToken` / `onClick`）。
  /// 返回：[Future<void>]。
  Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case eventToken:
        await _reportNativeToken(call.arguments);
      case eventClick:
        final args = call.arguments;
        if (args is Map) {
          _clicks.add(args.cast<String, Object?>());
        }
      default:
        if (kDebugMode) debugPrint('push: 未知原生事件 ${call.method}');
    }
  }

  /// 解析并上报原生 `onToken` 事件。
  ///
  /// 新契约参数为 `{channel, token}`；兼容旧版原生直接回传纯字符串（视为小米）。
  ///
  /// 参数：[args] 原生事件参数。
  /// 返回：[Future<void>]。
  Future<void> _reportNativeToken(Object? args) async {
    if (args is Map) {
      final channel = _parseChannel(args['channel']?.toString());
      if (channel == null) return;
      await _report(channel, args['token']?.toString());
      return;
    }
    if (args is String) await _report(PushChannel.mi, args);
  }

  /// 通道线值转枚举；未知线值返回 null（不猜通道）。
  ///
  /// 参数：[wire] 原生或服务端使用的通道线值。
  /// 返回：[PushChannel?]。
  PushChannel? _parseChannel(String? wire) {
    if (wire == null || wire.isEmpty) return null;
    for (final channel in PushChannel.values) {
      if (channel.wire == wire) return channel;
    }
    return null;
  }

  /// 上报 token（空/空白视为无 token，不上报）。
  ///
  /// 参数：[channel] 厂商通道；[token] 厂商下发的推送 token。
  /// 返回：[Future<void>]；失败只记 debug 日志。
  Future<void> _report(PushChannel channel, String? token) async {
    final value = token?.trim() ?? '';
    if (value.isEmpty) return;
    try {
      await _reporter(channel, value);
    } catch (e) {
      // 只记错误码/类型，不打印异常对象：异常消息可能携带请求体或推送凭据。
      final String detail = e is PlatformException ? e.code : e.runtimeType.toString();
      if (kDebugMode) debugPrint('push: 推送凭据上报失败 $detail');
    }
  }

  /// 释放事件流（测试与热重启用）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> dispose() => _clicks.close();
}

/// 落点类型：打开会话详情（与服务端 `PushMessage.LANDING_CONVERSATION` 同值）。
const String pushLandingConversation = 'conversation';

/// 推送点击落点。
class PushClickTarget {
  /// 构造落点。
  ///
  /// 参数：[landingType] 服务端下发的落点类型；[targetId] 关联对象 ID。
  const PushClickTarget({required this.landingType, this.targetId});

  /// 落点类型（`conversation` / 其它）。
  final String landingType;

  /// 关联对象 ID（会话落点时为会话 ID）。
  final int? targetId;

  /// 是否应打开会话详情（R16a）。
  bool get opensConversation =>
      landingType == pushLandingConversation && targetId != null;
}

/// 从点击载荷里解析落点（R16a）。
///
/// 兼容三种形态：
///   1. `payload` 为 JSON 字符串（小米 `MiPushMessage.content`，当前服务端实现）；
///   2. `payload` 为已解析的 Map；
///   3. 厂商把字段放进 `extra`（Map 或 JSON 字符串）。
/// 解析不出来（或不是会话落点）返回 null —— 点击退回默认行为，不猜落点。
///
/// 参数：[click] 原生 `onClick` / `getInitialClick` 的载荷。
/// 返回：[PushClickTarget?]。
PushClickTarget? pushClickTargetOf(Map<String, Object?> click) {
  final payload = _asMap(click['payload']) ?? _asMap(click['extra']);
  if (payload == null) return null;
  final landing = payload['landingType']?.toString();
  if (landing == null || landing.isEmpty) return null;
  final rawTarget = payload['targetId'];
  final targetId = rawTarget is int
      ? rawTarget
      : int.tryParse(rawTarget?.toString() ?? '');
  return PushClickTarget(landingType: landing, targetId: targetId);
}

/// 把 Map 或 JSON 字符串统一解析成 Map；失败返回 null。
///
/// 参数：[value] 原始值。
/// 返回：展开一层的键值对；不可解析时为 null。
Map<String, Object?>? _asMap(Object? value) {
  if (value is Map) return value.cast<String, Object?>();
  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) return decoded.cast<String, Object?>();
    } on FormatException {
      return null;
    }
  }
  return null;
}

/// 推送服务 Provider（原生通道默认实例）。
final pushServiceProvider = Provider<PushService>(
  (ref) => PushService(
    (channel, token) =>
        ref.read(pushDeviceRepositoryProvider).upsert(channel: channel, token: token),
  ),
);
