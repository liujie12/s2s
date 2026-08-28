/// 隐私协议同意状态（PRD §6.5.1）。
///
/// 这是 🔴 上架驳回点的状态源头：PRD §14.6 `:2287` 把「未同意协议时地图不初始化」
/// 列为阻塞项，验收方式是抓包实测。因此本文件的职责边界必须严格——
/// 它只回答「用户同意了没有」，**不负责**初始化任何 SDK。
/// 把同意判断与 SDK 初始化写在一起，会让「未同意也初始化了」这种
/// 违规变得难以察觉。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 当前隐私政策版本号。
///
/// 隐私政策发生**重大变更**时手动递增此值，用户会重新看到协议门。
/// 为什么不是布尔值：《个人信息保护法》要求重大变更须重新征得同意，
/// 只存 true/false 的话改版后无法触发重弹。
const String kCurrentPrivacyPolicyVersion = '1.0.0';

/// 持久化键名。带 `s2s.` 前缀避免与插件写入的键冲突。
const String _kAgreedVersionKey = 's2s.privacy.agreedVersion';

/// 隐私协议同意态。
///
/// 三态而非两态：`unknown` 是「还没读完本地存储」，与「读完了发现没同意」
/// 是两回事。若把未知并入未同意，冷启动瞬间会闪一下协议门再消失
/// （已同意的用户也会看到），属可见的体验缺陷。
enum PrivacyConsentStatus {
  /// 尚未读取本地存储，结果未知。
  unknown,

  /// 已同意，且同意的是当前版本。
  agreed,

  /// 未同意，或同意的是旧版本（政策已改版，须重新同意）。
  notAgreed,
}

/// 隐私同意状态的读写。
///
/// 用 Riverpod 的 Notifier 而非全局单例：`Provider` 可在测试中被覆写，
/// 无需真实的 SharedPreferences 即可测试协议门的分支行为。
class PrivacyConsentNotifier extends Notifier<PrivacyConsentStatus> {
  /// 构建初始状态并异步拉取本地存储的同意记录。
  ///
  /// 返回：初始一律为 `unknown`，真实值由 [_load] 异步填入。
  @override
  PrivacyConsentStatus build() {
    _load();
    return PrivacyConsentStatus.unknown;
  }

  /// 从本地存储读取已同意的版本号并比对当前版本。
  ///
  /// 版本不一致时视为未同意 —— 政策改版后必须重新征得同意。
  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final agreedVersion = prefs.getString(_kAgreedVersionKey);
    state = agreedVersion == kCurrentPrivacyPolicyVersion
        ? PrivacyConsentStatus.agreed
        : PrivacyConsentStatus.notAgreed;
  }

  /// 记录用户同意当前版本的隐私政策。
  ///
  /// 刻意先落盘再改内存状态：反过来的话，落盘失败时界面已经放行，
  /// 用户下次冷启动又被弹一次协议门，且期间 SDK 已按「已同意」初始化。
  ///
  /// 返回：落盘与状态更新完成的 Future。
  Future<void> agree() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAgreedVersionKey, kCurrentPrivacyPolicyVersion);
    state = PrivacyConsentStatus.agreed;
  }

  /// 记录用户拒绝。
  ///
  /// **不落盘**：拒绝不是需要记住的授权，下次冷启动应当再次询问。
  /// 落盘拒绝状态反而会让用户失去改主意的入口。
  void decline() {
    state = PrivacyConsentStatus.notAgreed;
  }
}

/// 隐私同意状态 Provider。
final privacyConsentProvider =
    NotifierProvider<PrivacyConsentNotifier, PrivacyConsentStatus>(
      PrivacyConsentNotifier.new,
    );
