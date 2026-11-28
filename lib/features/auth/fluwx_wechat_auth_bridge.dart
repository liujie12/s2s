/// 真实微信 SDK 授权桥（fluwx 6.x 实现，B2-6a）。
///
/// **职责**：把 [WechatAuthBridge] 的两件事落到实处 ——
///   1. 首次使用时用 AppID 注册微信 SDK（`registerApi`）；
///   2. 拉起微信客户端授权页（`authBy(NormalAuth)`），把回调里的一次性 `code`
///      经 Completer 交回登录页。
///
/// **为什么用 fluwx 6.x**：该版本已把 `WXEntryActivity` 以 `activity-alias` 形式
/// 声明在插件自身的 AndroidManifest 里（`${applicationId}.wxapi.WXEntryActivity`），
/// 并自带 `com.tencent.mm` 的 `<queries>` 声明 —— 因此**宿主工程无需新增原生
/// Activity 或改清单**，只要包名与签名与开放平台登记一致即可。
///
/// **凭据口径**：AppID 属公开标识，但仍只经 `--dart-define=WECHAT_APP_ID` 注入
/// 组装根后传入本类，不写死在仓库源码里；AppSecret **只在服务端**，客户端不接触。
///
/// **未注入 AppID 时**：[isAvailable] 为 false，`requestCode` 抛
/// [WechatAuthUnavailableException]，登录页按既有口径提示「微信登录暂不可用」，
/// 与接入前的行为一致（不会崩溃、不会静默无响应）。
library;

import 'dart:async';

import 'package:fluwx/fluwx.dart';

import 'wechat_auth_bridge.dart';

/// 微信授权作用域：官方规定**只能**填该值（获取用户个人信息）。
const String _authScope = 'snsapi_userinfo';

/// 授权 `state`：仅用于微信原样回传与防 CSRF，服务端当前不校验。
/// 之所以仍显式传：微信在 `state` 缺失时回包语义不稳定，且默认值 `state` 无区分度。
const String _authState = 'zhaoyazhao_wechat_login';

/// 等待微信回包的兜底时长。
///
/// 微信 SDK 的回调只在用户「允许 / 拒绝 / 取消」后才到；用户把微信切后台不再返回时，
/// 若无兜底会让登录页的 loading 无限挂着。取 2 分钟：足够用户看清授权页并操作，
/// 又不至于让按钮长时间不可点。
const Duration _authResponseTimeout = Duration(seconds: 120);

/// 微信 SDK 错误码：用户主动取消授权（正常流程）。
const int _errCodeUserCancel = -2;

/// 微信 SDK 错误码：用户拒绝授权。
const int _errCodeAuthDenied = -4;

/// 基于 fluwx 的真实微信授权桥。
///
/// 生命周期与应用一致：构造时订阅微信回包，`dispose` 时退订。
/// 同一时刻只允许一次授权在途，避免两个 Completer 争抢同一个回调。
class FluwxWechatAuthBridge implements WechatAuthBridge {
  /// 构造桥实例并订阅微信回包。
  ///
  /// 参数：[appId] 微信开放平台移动应用 AppID（空串表示未配置，桥不可用）；
  ///      [api] 可注入的 fluwx 实例（仅测试期替换，生产传 null 用默认实现）。
  FluwxWechatAuthBridge({required this.appId, Fluwx? api})
      : _api = api ?? Fluwx() {
    _subscription = _api.addSubscriber(_onWeChatResponse);
  }

  /// 微信开放平台移动应用 AppID。
  final String appId;

  /// fluwx 门面（注册 / 拉起授权 / 查询微信是否安装）。
  final Fluwx _api;

  /// 微信回包订阅句柄（`dispose` 时释放）。
  late final FluwxCancelable _subscription;

  /// SDK 注册结果缓存：只在首次授权时注册一次。
  Future<bool>? _registration;

  /// 当前在途授权（微信回包到达或超时时完成）。
  Completer<String>? _pending;

  @override
  bool get isAvailable => appId.trim().isNotEmpty;

  /// 确保 SDK 已注册（幂等：多次调用共用同一个 Future）。
  ///
  /// 返回：true 表示注册成功；false 表示注册失败（AppID 无效 / 平台通道异常）。
  Future<bool> _ensureRegistered() {
    return _registration ??= _api.registerApi(
      appId: appId,
      doOnAndroid: true,
      // iOS 侧尚无 Apple 组织账号与 Universal Link，显式关闭避免半配置状态。
      doOnIOS: false,
    );
  }

  @override
  Future<String> requestCode() async {
    if (!isAvailable) {
      throw const WechatAuthUnavailableException('未注入 WECHAT_APP_ID');
    }
    if (_pending != null) {
      throw const WechatAuthUnavailableException('上一次微信授权尚未结束');
    }

    final bool registered = await _ensureRegistered();
    if (!registered) {
      // 注册失败不缓存：下次点击可再试（例如开放平台配置刚生效）。
      _registration = null;
      throw const WechatAuthUnavailableException('微信 SDK 注册失败');
    }

    if (!await _api.isWeChatInstalled) {
      throw const WechatAuthUnavailableException('未安装微信客户端');
    }

    final completer = Completer<String>();
    _pending = completer;

    final bool dispatched = await _api.authBy(
      which: NormalAuth(scope: _authScope, state: _authState),
    );
    if (!dispatched) {
      _pending = null;
      throw const WechatAuthUnavailableException('拉起微信授权失败');
    }

    try {
      return await completer.future.timeout(_authResponseTimeout);
    } on TimeoutException {
      _pending = null;
      throw const WechatAuthUnavailableException('微信授权无响应');
    }
  }

  /// 微信回包分发：只处理授权类回包，其余（分享/支付等）忽略。
  ///
  /// 参数：[response] 微信 SDK 回调事件；
  /// 返回：无（结果通过 [_pending] 交回 [requestCode]）。
  void _onWeChatResponse(WeChatResponse response) {
    if (response is! WeChatAuthResponse) return;
    final completer = _pending;
    if (completer == null || completer.isCompleted) return;
    _pending = null;

    final String? code = response.code;
    if (response.errCode == 0 && code != null && code.isNotEmpty) {
      completer.complete(code);
      return;
    }
    if (response.errCode == _errCodeUserCancel ||
        response.errCode == _errCodeAuthDenied) {
      completer.completeError(const WechatAuthCanceledException());
      return;
    }
    completer.completeError(
      WechatAuthUnavailableException(
        '微信授权失败 errCode=${response.errCode} errStr=${response.errStr}',
      ),
    );
  }

  /// 释放微信回包订阅（由 Provider 在销毁时调用）。
  ///
  /// 返回：无。
  void dispose() {
    _pending = null;
    _subscription.cancel();
  }
}
