/// 实时通道装配层（features 侧）。
///
/// 把 core 的 [RealtimeClient] 接到三件事上：
///   1. 登录态：登录后连接、登出断开；
///   2. App 生命周期：前台连接、后台断开（后台提醒交给厂商推送）；
///   3. 数据刷新：事件到达后**合并 150ms** 刷新未读汇总与会话列表。
///
/// 为什么放在 features：core 不允许反向依赖 auth / message（KTD5 同一取向）；
/// 这也让会话页能直接 `ref.listen(realtimeEventsProvider)` 做自己的增量拉取。
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/realtime/realtime_client.dart';
import '../../nfr_constants.dart';
import '../auth/auth_repository.dart';
import 'message_list_provider.dart';

/// 实时客户端 Provider（全 App 单例）。
final realtimeClientProvider = Provider<RealtimeClient>((ref) {
  final client = RealtimeClient(
    endpoint: () => realtimeUriFor(ref.read(networkConfigProvider).baseUrl),
    token: () => ref.read(authSessionProvider)?.token,
  );
  ref.onDispose(() => unawaited(client.dispose()));
  return client;
});

/// 实时事件流 Provider（广播：多个页面可同时监听）。
final realtimeEventsProvider = StreamProvider<RealtimeMessageEvent>((ref) {
  return ref.watch(realtimeClientProvider).events;
});

/// 实时通道生命周期装配。
///
/// 由 app 根在 `initState` 创建并 [start]，`dispose` 时 [stop]。
class RealtimeWiring with WidgetsBindingObserver {
  /// 构造装配。
  ///
  /// 参数：[ref] app 根的 WidgetRef（用于读会话/触发刷新）。
  RealtimeWiring({required WidgetRef ref}) : _ref = ref;

  final WidgetRef _ref;
  StreamSubscription<RealtimeMessageEvent>? _events;
  ProviderSubscription<AuthSession?>? _session;
  Timer? _refreshTimer;

  /// 当前是否处于后台（后台不建连、也不在登录回调里建连）。
  bool _background = false;

  /// 启动：注册生命周期、监听登录态、订阅事件。
  void start() {
    WidgetsBinding.instance.addObserver(this);
    _session = _ref.listenManual<AuthSession?>(authSessionProvider,
        (previous, next) {
      final client = _ref.read(realtimeClientProvider);
      if (next == null) {
        unawaited(client.disconnect());
        return;
      }
      if (!_background) {
        unawaited(client.connect());
      }
    });
    _events = _ref.read(realtimeClientProvider).events.listen(_onEvent);
    if (_ref.read(authSessionProvider) != null) {
      unawaited(_ref.read(realtimeClientProvider).connect());
    }
  }

  /// 停止：取消订阅并断开连接（app 根销毁时调用）。
  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _events?.cancel();
    _events = null;
    _session?.close();
    _session = null;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    unawaited(_ref.read(realtimeClientProvider).disconnect());
  }

  /// 生命周期：前台重连并补齐，后台断开。
  ///
  /// 断线期间产生的消息不会丢——回前台时统一重拉未读汇总与会话列表首页，
  /// 当前会话由页面自己的 `after_seq` 增量补齐。
  ///
  /// 参数：[state] 新的生命周期状态。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final client = _ref.read(realtimeClientProvider);
    if (state == AppLifecycleState.paused) {
      _background = true;
      unawaited(client.disconnect());
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _background = false;
      if (_ref.read(authSessionProvider) != null) {
        unawaited(client.connect());
        unawaited(_ref.read(unreadSummaryProvider.notifier).refresh());
        unawaited(_ref.read(conversationsProvider.notifier).refreshSilently());
      }
    }
  }

  /// 事件到达：合并窗口内只刷新一次（避免一条消息刷一次列表）。
  ///
  /// 参数：[event] 新消息事件。
  void _onEvent(RealtimeMessageEvent event) {
    _refreshTimer?.cancel();
    _refreshTimer = Timer(NfrRealtime.refreshDebounce, () {
      if (_ref.read(authSessionProvider) == null) return;
      unawaited(_ref.read(unreadSummaryProvider.notifier).refresh());
      unawaited(_ref.read(conversationsProvider.notifier).refreshSilently());
    });
  }
}
