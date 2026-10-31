/// 消息 Tab 的通知权限引导状态（R16 / 设计稿 06 帧）。
///
/// 两件事落本地（SharedPreferences，本仓既有的轻量标记口径）：
///   1. 是否已展示过说明层 —— 首次进入消息 Tab 才弹，之后不再重复；
///   2. 被拒后顶部提示是否已被用户关闭。
///
/// 权限本身仍由原生通道申请（[PushService.requestPermission]），本类不引
/// `permission_handler` 的通知能力：推送通道与权限申请必须是同一个原生实现，
/// 否则会出现「系统说开了、推送通道仍拿不到 token」的错觉。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 说明层已展示过的持久化键。
const String _kExplainerSeenKey = 's2s.message.notifyExplainerSeen';

/// 权限被拒的持久化键。
const String _kDeniedKey = 's2s.message.notifyDenied';

/// 顶部提示被关闭的持久化键。
const String _kBannerDismissedKey = 's2s.message.notifyBannerDismissed';

/// 通知权限引导快照。
class MessageNotifyPermissionState {
  /// 构造快照。
  ///
  /// 参数：[loaded] 本地标记是否已读完；[explainerSeen] 是否已展示过说明层；
  ///   [denied] 是否被系统拒绝；[bannerDismissed] 顶部提示是否已被关闭。
  const MessageNotifyPermissionState({
    required this.explainerSeen,
    required this.denied,
    required this.bannerDismissed,
    this.loaded = false,
  });

  /// 初始态：未询问、未拒绝、提示未关闭。
  static const MessageNotifyPermissionState initial =
      MessageNotifyPermissionState(
    explainerSeen: false,
    denied: false,
    bannerDismissed: false,
  );

  /// 本地标记是否已读完（未读完时页面不得据此弹层，避免冷启动闪一次）。
  final bool loaded;

  /// 是否已展示过说明层。
  final bool explainerSeen;

  /// 是否被系统拒绝。
  final bool denied;

  /// 顶部提示是否已被关闭。
  final bool bannerDismissed;

  /// 首次进入是否需要弹说明层。
  bool get shouldShowExplainer => loaded && !explainerSeen;

  /// 是否常驻顶部「通知未开启」提示。
  bool get shouldShowBanner => denied && !bannerDismissed;

  /// 复制并覆盖字段。
  ///
  /// 参数：各字段的覆盖值（null＝保持原值）。
  /// 返回：[MessageNotifyPermissionState] 新快照。
  MessageNotifyPermissionState copyWith({
    bool? explainerSeen,
    bool? denied,
    bool? bannerDismissed,
  }) {
    return MessageNotifyPermissionState(
      explainerSeen: explainerSeen ?? this.explainerSeen,
      denied: denied ?? this.denied,
      bannerDismissed: bannerDismissed ?? this.bannerDismissed,
      loaded: loaded,
    );
  }
}

/// 通知权限引导状态机。
class MessageNotifyPermissionNotifier
    extends Notifier<MessageNotifyPermissionState> {
  @override
  MessageNotifyPermissionState build() {
    _load();
    return MessageNotifyPermissionState.initial;
  }

  /// 从本地读三枚标记（失败按初始态，不阻塞页面）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = MessageNotifyPermissionState(
        explainerSeen: prefs.getBool(_kExplainerSeenKey) ?? false,
        denied: prefs.getBool(_kDeniedKey) ?? false,
        bannerDismissed: prefs.getBool(_kBannerDismissedKey) ?? false,
        loaded: true,
      );
    } catch (_) {
      // 本地存储不可用：按「未询问」处理并标记已读完，本次仍引导一次。
      state = const MessageNotifyPermissionState(
        explainerSeen: false,
        denied: false,
        bannerDismissed: false,
        loaded: true,
      );
    }
  }

  /// 标记说明层已展示（无论用户点「去开启」还是「暂不」）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> markExplainerSeen() async {
    state = state.copyWith(explainerSeen: true);
    await _write(_kExplainerSeenKey, true);
  }

  /// 记录系统权限被拒（顶部提示依据）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> markDenied() async {
    state = state.copyWith(denied: true);
    await _write(_kDeniedKey, true);
  }

  /// 用户关闭顶部提示（本次不再出现，下次进入仍按本地标记抑制）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> dismissBanner() async {
    state = state.copyWith(bannerDismissed: true);
    await _write(_kBannerDismissedKey, true);
  }

  /// 写一枚布尔标记（失败静默：引导状态丢失不让页面报错）。
  ///
  /// 参数：[key] 键；[value] 值。
  /// 返回：[Future<void>]。
  Future<void> _write(String key, bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 同 _load：本地存储故障不影响会话主链。
    }
  }
}

/// 通知权限引导 Provider。
final messageNotifyPermissionProvider = NotifierProvider<
    MessageNotifyPermissionNotifier, MessageNotifyPermissionState>(
  MessageNotifyPermissionNotifier.new,
);
