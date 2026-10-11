/// 设置页状态层（[B2-11]）。
///
/// 单条数据流：`GET /settings` → [SettingsDto] → 页面按 `AsyncValue` 三态渲染。
/// 写动作（切开关 / 改默认范围）走 PATCH，成功后**以响应体就地覆盖 state**
/// （服务端返回更新后的完整设置，无需二次 GET，也避免本地推算与服务端不一致）。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import 'settings_dto.dart';
import 'settings_repository.dart';

/// 设置状态机。
class SettingsNotifier extends Notifier<AsyncValue<SettingsDto>> {
  @override
  AsyncValue<SettingsDto> build() {
    unawaited(_load());
    return const AsyncValue.loading();
  }

  /// 拉取设置并把失败收敛到错误态。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _load() async {
    try {
      final settings = await ref.read(settingsRepositoryProvider).fetchSettings();
      state = AsyncValue.data(settings);
    } catch (e) {
      state = AsyncValue.error(asApiException(e), StackTrace.current);
    }
  }

  /// 重新拉取（重试）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    await _load();
  }

  /// 切换消息通知总开关。
  ///
  /// 参数：[enabled] 目标值。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException] 由页面提示（失败不回滚——state 未被乐观改过）。
  Future<void> setNotifyEnabled({required bool enabled}) async {
    final updated = await ref
        .read(settingsRepositoryProvider)
        .updateSettings(notifyEnabled: enabled);
    state = AsyncValue.data(updated);
  }

  /// 设置默认检索半径档位。
  ///
  /// 参数：[radius] 契约档位（`1`/`3`/`5`/`10`/`city`）。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException]（40001 非法档位等）由页面提示。
  Future<void> setDefaultRadius({required String radius}) async {
    final updated = await ref
        .read(settingsRepositoryProvider)
        .updateSettings(defaultRadius: radius);
    state = AsyncValue.data(updated);
  }
}

/// 设置 Provider。
final settingsProvider = NotifierProvider<SettingsNotifier, AsyncValue<SettingsDto>>(
  SettingsNotifier.new,
);
