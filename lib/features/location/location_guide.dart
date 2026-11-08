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
///
/// 带生命周期监听：用户按「去系统设置打开」跳到系统设置、授权后返回本 App 时，
/// 必须重新评估权限态（否则会停在引导页，只能杀进程重启才能恢复，见 DEF-02）。
class LocationGuide extends ConsumerStatefulWidget {
  const LocationGuide({super.key});

  @override
  ConsumerState<LocationGuide> createState() => _LocationGuideState();
}

/// 引导页 State：负责注册 `WidgetsBindingObserver`，在 App 回到前台时复评权限。
class _LocationGuideState extends ConsumerState<LocationGuide>
    with WidgetsBindingObserver {
  /// 注册生命周期监听。
  ///
  /// 参数：无。
  /// 返回：无。
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 注销生命周期监听，避免 State 销毁后仍被回调。
  ///
  /// 参数：无。
  /// 返回：无。
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 生命周期变化回调：回到前台（resumed）时重新评估定位权限态。
  ///
  /// 用户从系统设置页返回、或从后台切回时都会触发；复评命中 granted 后
  /// 引导页随 `locationPermissionProvider` 变化自动让位给地图。
  ///
  /// 参数：[state] 当前生命周期状态。
  /// 返回：无。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(locationPermissionProvider.notifier).evaluate();
    }
  }

  @override
  Widget build(BuildContext context) {
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
