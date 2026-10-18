/// 微信授权桥（B2-6a）：客户端拉起微信 SDK 授权并取回一次性 `code` 的唯一入口。
///
/// **为什么独立成桥而不是直接在页面里调 SDK**：
///   1. 微信开放平台资质尚未获批（AppID/AppSecret 未到位），真实 SDK 通道暂不可用；
///      页面只依赖本抽象，测试可注入内存桩，**契约先行、零等待**；
///   2. SDK 调用是平台能力（Android/iOS 各一套原生注册），与登录页交互逻辑无关，
///      隔离后页面无需感知插件差异；
///   3. 凭据红线：AppID 只经 `--dart-define` 注入，不落仓库；桥实现负责注册，
///      页面与仓库都不接触凭据。
///
/// **接通真实 SDK 的唯一改动点**：在组装根（`main.dart`）用真实实现 override
/// [wechatAuthBridgeProvider]；登录页与 [AuthRepository] 均无需改动。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 微信授权桥抽象。
abstract class WechatAuthBridge {
  /// 当前设备是否具备完成微信授权的能力。
  ///
  /// 为 false 时页面仍可点击并得到「暂未开放」的明确提示，而不是静默无响应。
  bool get isAvailable;

  /// 拉起微信客户端授权，返回一次性授权码（最长 64 字符）。
  ///
  /// 返回：[String] 微信授权 code（服务端用它交换 openid）。
  /// 抛出：[WechatAuthCanceledException] 用户取消授权；
  ///      [WechatAuthUnavailableException] 通道未配置/微信未安装。
  Future<String> requestCode();
}

/// 微信授权通道未配置（AppID 未注入 / SDK 未接入 / 微信未安装）。
class WechatAuthUnavailableException implements Exception {
  /// 构造异常。
  ///
  /// 参数：[reason] 面向排障的原因说明（不展示给用户）。
  const WechatAuthUnavailableException([this.reason = '微信登录通道未配置']);

  /// 排障用原因。
  final String reason;

  @override
  String toString() => 'WechatAuthUnavailableException: $reason';
}

/// 用户主动取消微信授权（正常流程，不是失败，页面不展示错误横幅）。
class WechatAuthCanceledException implements Exception {
  /// 构造异常。
  const WechatAuthCanceledException();

  @override
  String toString() => 'WechatAuthCanceledException';
}

/// 默认实现：通道未配置（资质审批中，AppID/SDK 尚未接入）。
///
/// 行为：`isAvailable=false`，`requestCode` 抛 [WechatAuthUnavailableException]。
/// 接通真实 SDK 时在组装根 override [wechatAuthBridgeProvider]，本类保留为
/// 无原生能力环境（如桌面/测试）的安全兜底。
class UnavailableWechatAuthBridge implements WechatAuthBridge {
  /// 构造未配置桥（无状态，可 const）。
  const UnavailableWechatAuthBridge();

  @override
  bool get isAvailable => false;

  @override
  Future<String> requestCode() async {
    throw const WechatAuthUnavailableException();
  }
}

/// 微信授权桥 Provider（默认未配置，组装根可 override 为真实实现）。
final wechatAuthBridgeProvider = Provider<WechatAuthBridge>(
  (ref) => const UnavailableWechatAuthBridge(),
);
