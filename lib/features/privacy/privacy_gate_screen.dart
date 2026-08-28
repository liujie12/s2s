/// 隐私协议门（PRD §6.5.1，页面 ID：privacy-gate）。
///
/// 首次冷启动的第一屏，早于登录页。同意后才允许初始化地图 SDK 与申请定位权限。
/// 这是 🔴 上架驳回点（§14.6 `:2287`），验收方式为抓包实测。
///
/// 三条不可改的行为约束（PRD §6.5.1）：
/// 1. **不可绕过**：无右上角关闭、不响应返回键 —— 有绕过路径就等于没有门；
/// 2. **不同意不退出应用**：工信部禁止「不同意就不给用」，改为受限态；
/// 3. **协议文本走在线 URL**：上架手册 P6 要求隐私政策必须有独立可访问 URL。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import '../map/amap_init_guard.dart';
import 'privacy_consent.dart';

/// 隐私协议门。
class PrivacyGateScreen extends ConsumerWidget {
  const PrivacyGateScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(privacyConsentProvider);

    // PopScope(canPop: false) 而非隐藏返回按钮：安卓物理返回键与手势返回
    // 不受 AppBar 影响，只有在这一层拦截才真正拦得住。
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(AppColors.background),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: status == PrivacyConsentStatus.notAgreed
                ? _DeclinedView(onReread: () => _showAgreement(context, ref))
                : _AgreementView(
                    onAgree: () => _agree(ref),
                    onDecline: () =>
                        ref.read(privacyConsentProvider.notifier).decline(),
                  ),
          ),
        ),
      ),
    );
  }

  /// 处理用户同意：先落盘，再把合规声明写入高德 SDK。
  ///
  /// 顺序不可颠倒 —— 声明先写入而落盘失败的话，本次会话按已同意运行，
  /// 但下次冷启动又弹门，用户会认为「我明明同意过」。
  ///
  /// 参数：
  /// - [ref]：Riverpod 引用，用于读取 notifier 与最新状态。
  Future<void> _agree(WidgetRef ref) async {
    await ref.read(privacyConsentProvider.notifier).agree();
    AMapInitGuard.applyConsent(ref.read(privacyConsentProvider));
  }

  /// 从受限态返回协议阅读态。
  ///
  /// 参数：
  /// - [context]：用于后续接入协议 WebView（M4-4 隐私政策上线后）。
  /// - [ref]：Riverpod 引用。
  void _showAgreement(BuildContext context, WidgetRef ref) {
    // 回到 unknown 会重新触发 _load 读盘，等价于「重新走一遍协议门」。
    ref.invalidate(privacyConsentProvider);
  }
}

/// 协议阅读与同意视图。
class _AgreementView extends StatelessWidget {
  const _AgreementView({required this.onAgree, required this.onDecline});

  final VoidCallback onAgree;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.xxl),
        Text(
          '欢迎使用找鸭找',
          style: TextStyle(
            fontSize: AppTypeScale.h1.size,
            height: AppTypeScale.h1.lineHeight,
            fontWeight: FontWeight.w700,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Expanded(
          child: SingleChildScrollView(
            child: Text(
              '在使用前，请阅读并同意《用户协议》与《隐私政策》。\n\n'
              '我们将收集以下信息以提供服务：\n'
              '· 位置信息 —— 用于展示你附近的资源与需求；\n'
              '· 手机号 —— 用于登录与联系中转；\n'
              '· 发布内容 —— 用于在地图与列表中展示。\n\n'
              '本应用集成高德地图 SDK（服务商：高德软件有限公司），'
              '用于地图展示与定位，会收集位置信息与设备标识。\n\n'
              '你可以选择不同意，届时仍可浏览应用，但地图与定位功能不可用。',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                height: AppTypeScale.body.lineHeight,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        ElevatedButton(
          onPressed: onAgree,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(AppColors.primary),
            foregroundColor: Colors.white,
            // 48 而非 Token 里的间距值：这是可点区域高度，遵循 44px 下限
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text('同意并继续'),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextButton(
          onPressed: onDecline,
          child: Text(
            '不同意',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}

/// 拒绝后的受限态视图。
///
/// 刻意不是空白页：空白会让用户以为应用坏了。这里说明「还能做什么」
/// 以及「怎么改主意」，是「不强制授权」与「不流失用户」的唯一交点。
class _DeclinedView extends StatelessWidget {
  const _DeclinedView({required this.onReread});

  final VoidCallback onReread;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '地图功能需要你的同意',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppTypeScale.h2.size,
            height: AppTypeScale.h2.lineHeight,
            fontWeight: FontWeight.w600,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '你尚未同意隐私政策，地图与定位功能暂不可用。\n'
          '你可以随时重新阅读并同意。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            height: AppTypeScale.body.lineHeight,
            color: const Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        ElevatedButton(
          onPressed: onReread,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(AppColors.primary),
            foregroundColor: Colors.white,
            minimumSize: const Size.fromHeight(48),
          ),
          child: const Text('重新阅读协议'),
        ),
      ],
    );
  }
}
