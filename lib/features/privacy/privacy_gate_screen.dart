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
///
/// **为什么是 StatefulWidget（2026-09-29 真机实测教训，阻断级）**：
/// 「已拒绝」与「从未询问过」在 Notifier 里同属 [PrivacyConsentStatus.notAgreed]
/// —— 拒绝刻意不落盘（见 privacy_consent.dart），下次冷启动须重新询问。
/// 但两者的界面必须相反：前者进受限态，后者必须停在可同意的协议页。
///
/// 若直接用 `notAgreed` 选视图，首次启动会在读盘完成的一瞬间由协议页翻成受限态，
/// 用户来不及点「同意」；而「重新阅读协议」重读盘后仍是 `notAgreed`，界面原地打转。
/// 实测表现即「一直提示尚未同意隐私政策，卡住进不去」，应用完全不可用。
/// 故把「已拒绝」降级为**会话内的界面状态**，与「本地存储里有无有效同意记录」解耦，
/// 后者只由路由（app_router.dart）判定。
class PrivacyGateScreen extends ConsumerStatefulWidget {
  const PrivacyGateScreen({super.key});

  @override
  ConsumerState<PrivacyGateScreen> createState() => _PrivacyGateScreenState();
}

class _PrivacyGateScreenState extends ConsumerState<PrivacyGateScreen> {
  /// 本会话内用户是否点过「不同意」。
  ///
  /// 与 Notifier 的 `notAgreed` 分开持有：它表达的是「这一次用户明确拒绝」，
  /// 而不是「本地存储里没有有效的同意记录」——两者界面相反，不可合并。
  bool _declinedThisSession = false;

  @override
  Widget build(BuildContext context) {
    // PopScope(canPop: false) 而非隐藏返回按钮：安卓物理返回键与手势返回
    // 不受 AppBar 影响，只有在这一层拦截才真正拦得住。
    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: const Color(AppColors.background),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: _declinedThisSession
                ? _DeclinedView(
                    onReread: () => setState(() => _declinedThisSession = false),
                  )
                : _AgreementView(onAgree: _agree, onDecline: _decline),
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
  /// 返回：落盘与 SDK 声明均完成后的 Future。
  Future<void> _agree() async {
    await ref.read(privacyConsentProvider.notifier).agree();
    AMapInitGuard.applyConsent(ref.read(privacyConsentProvider));
  }

  /// 处理用户拒绝：进入本会话的受限态，并同步 Notifier 的未同意态。
  void _decline() {
    ref.read(privacyConsentProvider.notifier).decline();
    setState(() => _declinedThisSession = true);
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
