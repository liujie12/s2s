/// 定位权限引导页（PRD §6.4.4）。
///
/// A/B 两态共用同一布局与插画，只有标题文案、说明文案、主按钮文字与主按钮
/// 动作四处不同（§6.4.4 末条）。三态均须提供「手动选择城市」出口，不得做成
/// 必须授权才能继续的硬门禁。
///
/// 隐私时序红线（§6.4.4 `:1234`）：本页只在隐私协议已同意后展示，A 态才触发
/// 系统弹窗，绝不跳过引导页直接弹系统弹窗。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import '../city/city_selector_sheet.dart';
import 'location_center.dart';
import 'location_permission.dart';

/// 会话级「定位引导页已跳过」标记（默认 false）。
///
/// 与权限态解耦：权限态是持久事实（A/B/granted），「跳过」是用户本次会话的
/// 选择——用户选了手动城市即不再弹引导页，但权限态不变（下次冷启动仍会评估）。
class LocationGuideDismissedNotifier extends Notifier<bool> {
  @override
  bool build() => false;

  /// 标记引导页已跳过（手动选城市后调用）。
  void dismiss() => state = true;
}

/// 定位引导页是否已跳过。
final locationGuideDismissedProvider =
    NotifierProvider<LocationGuideDismissedNotifier, bool>(
      LocationGuideDismissedNotifier.new,
    );

/// A/B 定位权限引导页。
class LocationGuide extends ConsumerWidget {
  const LocationGuide({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = ref.watch(locationPermissionProvider);
    final isA = phase == LocationPermissionPhase.neverGranted;
    // A/B 只有四处不同：标题、说明、主按钮文字、主按钮动作（§6.4.4 末条）。
    final title = isA ? '开启位置，发现身边' : '定位被关掉了';
    final description = isA
        ? '只推你走得到的地方，不用再翻全城。'
        : '你之前允许过定位，现在被系统关掉了，去设置里重新打开。';
    final primaryLabel = isA ? '开启位置权限' : '去系统设置打开';

    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.xxl),
              Icon(
                Icons.location_on,
                size: 64,
                color: const Color(AppColors.primary),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                title,
                style: TextStyle(
                  fontSize: AppTypeScale.h1.size,
                  height: AppTypeScale.h1.lineHeight,
                  fontWeight: FontWeight.w700,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                description,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  height: AppTypeScale.body.lineHeight,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
              const Spacer(),
              ElevatedButton(
                onPressed: () => _onPrimary(ref),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(AppColors.primary),
                  foregroundColor: Colors.white,
                  minimumSize: const Size.fromHeight(48),
                ),
                child: Text(primaryLabel),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: () => _onManualCity(context, ref),
                child: Text(
                  '手动选择城市',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 主按钮动作：A 请求权限、B 跳系统设置。
  ///
  /// 参数：[ref] Riverpod 引用。
  /// 返回：动作执行完成。
  Future<void> _onPrimary(WidgetRef ref) async {
    final notifier = ref.read(locationPermissionProvider.notifier);
    if (ref.read(locationPermissionProvider) == LocationPermissionPhase.neverGranted) {
      await notifier.requestPermission();
    } else {
      await notifier.openSettings();
    }
  }

  /// 次按钮：手动选择城市。
  ///
  /// 选中后把中心点移到所选城市并跳过引导页；取消则停留在引导页。
  ///
  /// 参数：
  ///   [context] 构建上下文；
  ///   [ref] Riverpod 引用。
  /// 返回：选择完成。
  Future<void> _onManualCity(BuildContext context, WidgetRef ref) async {
    final city = await showCitySelectorSheet(context);
    if (city == null) return;
    ref.read(locationCenterProvider.notifier).moveTo(city.lat, city.lng);
    ref.read(locationGuideDismissedProvider.notifier).dismiss();
  }
}
