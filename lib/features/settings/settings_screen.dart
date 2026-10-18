/// 设置页（PRD §9.3 / §13 `settings-screen`；[B2-11]）。
///
/// 结构（对齐设计稿 `buildSettings`）：四组设置行——账号与安全 / 通用 / 隐私 / 关于。
///
/// 数据来源：
///   - 有契约支撑的行走真接口：`消息通知`（PATCH notify.enabled 切换）、
///     `默认范围`（PATCH default_radius + 档位选择）、`联系方式展示策略`（GET 只读值）、
///     `手机号`（`GET /users/me` 的 phone_mask）；
///   - 无对应端点的行（修改密码/注销账号/清除缓存/位置权限说明/版本号/用户协议/隐私政策）
///     按项目既有降级口径提示「本期内测版暂未开放」，不做假交互。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../auth/auth_repository.dart';
import '../auth/wechat_auth_bridge.dart';
import '../profile/profile_provider.dart';
import 'settings_dto.dart';
import 'settings_provider.dart';

/// 客户端版本号（与设计稿 `settings-screen` 的「版本号 v2.1」一致）。
///
/// TODO(B2-11 收口)：接入 `package_info_plus` 读真实版本，替换本常量。
const String _appVersionLabel = 'v2.1';

/// 默认检索半径档位（openapi `RadiusEnum`；`city`＝全城）。
const List<String> _radiusValues = ['1', '3', '5', '10', 'city'];

/// 设置页。
class SettingsScreen extends ConsumerWidget {
  /// 构建设置页。
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final profile = ref.watch(myProfileProvider).asData?.value;
    final phoneMask = profile?.phoneMask;
    final wechatBound = profile?.wechatBound;

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new, size: 18, color: Color(AppColors.textPrimary)),
          onPressed: () => context.pop(),
        ),
        title: Text(
          '设置',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ListErrorView(
          error: asApiException(error),
          onRetry: () => ref.read(settingsProvider.notifier).refresh(),
        ),
        data: (settings) => _buildBody(context, ref, settings, phoneMask, wechatBound),
      ),
    );
  }

  /// 设置正文（四组）。
  ///
  /// 参数：[context] 构建上下文；[ref] Riverpod 句柄；[settings] 设置数据；
  ///   [phoneMask] 脱敏手机号（可空）；[wechatBound] 微信绑定态（可空）。
  /// 返回：Widget。
  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    SettingsDto settings,
    String? phoneMask,
    bool? wechatBound,
  ) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const _GroupTitle('账号与安全'),
        _SettingRow(
          label: '手机号',
          value: phoneMask,
          onTap: () => _notOpen(context),
        ),
        // B2-6a：手机号老账号反向绑定微信（冲突引导的闭环入口）
        _SettingRow(
          label: '微信',
          value: wechatBound == null ? null : (wechatBound ? '已绑定' : '未绑定'),
          onTap: () => _bindWechat(context, ref, wechatBound),
        ),
        _SettingRow(label: '修改密码', value: null, onTap: () => _notOpen(context)),
        _SettingRow(label: '注销账号', value: null, onTap: () => _notOpen(context)),
        const _GroupTitle('通用'),
        _SettingRow(
          label: '消息通知',
          value: settings.notify.enabled ? '已开启' : '已关闭',
          onTap: () => _toggleNotify(context, ref, settings.notify.enabled),
        ),
        _SettingRow(
          label: '默认范围',
          value: _radiusLabel(settings.defaultRadius),
          onTap: () => _pickRadius(context, ref, settings.defaultRadius),
        ),
        _SettingRow(label: '清除缓存', value: null, onTap: () => _notOpen(context)),
        const _GroupTitle('隐私'),
        _SettingRow(label: '位置权限说明', value: null, onTap: () => _notOpen(context)),
        _SettingRow(
          label: '联系方式展示策略',
          value: _contactDisplayLabel(settings.contactDisplay),
          onTap: () => _notOpen(context),
        ),
        const _GroupTitle('关于'),
        _SettingRow(label: '版本号', value: _appVersionLabel, onTap: () => _notOpen(context)),
        _SettingRow(label: '用户协议', value: null, onTap: () => _notOpen(context)),
        _SettingRow(label: '隐私政策', value: null, onTap: () => _notOpen(context)),
        // B2-4 合规公示位（PRD §5.9 裁定：挂「设置-关于」，与备案编号公示合并）。
        _SettingRow(
          label: 'AI 生成式服务公示',
          value: null,
          onTap: () => _showAiDisclosure(context),
        ),
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }

  /// 展示「AI 生成式服务公示」（B2-4；含模型名与备案号）。
  ///
  /// 参数：[context] 构建上下文。
  /// 返回：[void]。
  void _showAiDisclosure(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('AI 生成式服务公示'),
        content: const Text(
          '本应用的「AI 智能发布」由以下已备案生成式人工智能服务提供：\n\n'
          '模型名称：通义千问（阿里云百炼）\n'
          '生成式AI服务备案号：ZheJiang-TongYiQianWen-20230901\n'
          '算法备案号：网信算备330110507206401230035号\n\n'
          '上线编号：待取得后公示。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  /// 绑定微信（B2-6a 设置页入口）。
  ///
  /// 参数：[context] 构建上下文；[ref] Riverpod 句柄；[bound] 当前绑定态。
  /// 返回：[Future<void>]。
  Future<void> _bindWechat(
    BuildContext context,
    WidgetRef ref,
    bool? bound,
  ) async {
    if (bound == true) {
      _toast(context, '微信已绑定');
      return;
    }
    try {
      final code = await ref.read(wechatAuthBridgeProvider).requestCode();
      final failure = await ref
          .read(authRepositoryProvider)
          .bindWechat(code: code);
      if (!context.mounted) return;
      if (failure != null) {
        _toast(context, failure.message);
        return;
      }
      ref.read(authSessionProvider.notifier).updateIdentityFlags(
        wechatBound: true,
      );
      ref.invalidate(myProfileProvider);
      _toast(context, '微信绑定成功');
    } on WechatAuthCanceledException {
      // 用户取消授权：正常流程，不提示。
    } on WechatAuthUnavailableException {
      if (context.mounted) {
        _toast(context, AuthFailure.wechatUnavailable.message);
      }
    } catch (_) {
      if (context.mounted) _toast(context, AuthFailure.networkError.message);
    }
  }

  /// 切换消息通知总开关（PATCH）。
  ///
  /// 参数：[context] 构建上下文；[ref] Riverpod 句柄；[current] 当前值。
  /// 返回：[Future<void>]。
  Future<void> _toggleNotify(BuildContext context, WidgetRef ref, bool current) async {
    try {
      await ref.read(settingsProvider.notifier).setNotifyEnabled(enabled: !current);
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, asApiException(e).uiMessage);
    }
  }

  /// 选择默认检索半径档位（底部弹层 → PATCH）。
  ///
  /// 参数：[context] 构建上下文；[ref] Riverpod 句柄；[current] 当前档位。
  /// 返回：[Future<void>]。
  Future<void> _pickRadius(BuildContext context, WidgetRef ref, String current) async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final radius in _radiusValues)
              ListTile(
                title: Text(_radiusLabel(radius)),
                trailing: radius == current
                    ? Icon(Icons.check, size: 18, color: Color(AppColors.primary))
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(radius),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current) return;
    try {
      await ref.read(settingsProvider.notifier).setDefaultRadius(radius: picked);
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, asApiException(e).uiMessage);
    }
  }

  /// 档位 → 展示文案（`city` → 全城，其余 → `{n}km`）。
  ///
  /// 参数：[radius] 契约档位。
  /// 返回：String 文案。
  static String _radiusLabel(String radius) =>
      radius == 'city' ? '全城' : '${radius}km';

  /// 联系方式展示策略 → 展示文案（契约恒 `transit_only`）。
  ///
  /// 参数：[value] 契约值。
  /// 返回：String 文案。
  static String _contactDisplayLabel(String value) =>
      value == 'transit_only' ? '仅点击后可见' : value;

  /// 无端点行的统一降级提示。
  ///
  /// 参数：[context] 构建上下文。
  /// 返回：void。
  static void _notOpen(BuildContext context) =>
      _toast(context, '本期内测版暂未开放');

  /// 弹一条 SnackBar。
  ///
  /// 参数：[context] 构建上下文；[message] 文案。
  /// 返回：void。
  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 分组标题。
class _GroupTitle extends StatelessWidget {
  /// 构造分组标题。
  ///
  /// 参数：[label] 标题文案。
  const _GroupTitle(this.label);

  /// 标题文案。
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.md,
        bottom: AppSpacing.xs,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          color: Color(AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// 单条设置行（listRow：左标签 + 右值 + 尾部 chevron）。
class _SettingRow extends StatelessWidget {
  /// 构建设置行。
  ///
  /// 参数：[label] 左标签；[value] 右值（null＝不建文本节点）；[onTap] 点击回调。
  const _SettingRow({required this.label, required this.value, required this.onTap});

  /// 左标签。
  final String label;

  /// 右值（可空）。
  final String? value;

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          border: Border(bottom: BorderSide(color: Color(AppColors.border))),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textPrimary),
                ),
              ),
            ),
            if (value != null)
              Text(
                value!,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
            const SizedBox(width: AppSpacing.xs),
            Icon(Icons.chevron_right, size: 18, color: Color(AppColors.textPlaceholder)),
          ],
        ),
      ),
    );
  }
}
