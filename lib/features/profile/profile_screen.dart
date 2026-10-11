/// 个人中心页（PRD §10.1 `profile-screen`；[B2-11]）。
///
/// 结构（对齐设计稿 `buildProfile`）：头部卡（头像 + 昵称/脱敏号 + 实名状态）
/// → 五个入口行（我的发布/我的收藏/通知中心/信任与认证/设置）→ 退出登录。
///
/// 数据两条流：头部取 [myProfileProvider]（`GET /users/me`），入口右侧角标取
/// [myPageBadgesProvider]（并行聚合三路）。角标独立降级：未就绪时不显右值，
/// 入口仍可点——不因角标失败挡住导航。
///
/// 退出登录：二次确认后调 `AuthSessionNotifier.signOut()`（清内存会话 + 持久化
/// Token），不调服务端登出接口（与既有口径一致，见 auth_repository 头注）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import 'profile_dto.dart';
import 'profile_provider.dart';

/// 个人中心页。
class ProfileScreen extends ConsumerWidget {
  /// 构造个人中心页。
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(myProfileProvider);
    final badges = ref.watch(myPageBadgesProvider).asData?.value;

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        automaticallyImplyLeading: false,
        title: Text(
          '我的',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => context.push(AppRoutes.settings),
            child: Text(
              '设置',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.primary),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await Future.wait<void>([
            ref.read(myProfileProvider.notifier).refresh(),
            ref.read(myPageBadgesProvider.notifier).refresh(),
          ]);
        },
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            _HeaderCard(profileAsync: profileAsync),
            _EntryGroup(
              badges: badges,
              realnamePassed: profileAsync.asData?.value.isRealnamePassed ?? false,
              onTapMyPublish: () => context.push(AppRoutes.myPublish),
              onTapFavorites: () => context.push(AppRoutes.favorites),
              onTapNotifications: () => context.push(AppRoutes.notifications),
              onTapTrust: () => context.push(AppRoutes.trust),
              onTapSettings: () => context.push(AppRoutes.settings),
            ),
            const SizedBox(height: AppSpacing.xl),
            _SignOutButton(
              onPressed: () => _confirmSignOut(context, ref),
            ),
          ],
        ),
      ),
    );
  }

  /// 退出登录二次确认；确认后清本地会话并回到首页。
  ///
  /// 参数：[context] 构建上下文（用于弹窗与跳转）；[ref] Riverpod 句柄。
  /// 返回：[Future<void>]。
  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text('退出后需重新登录才能发布与联系。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              '退出登录',
              style: TextStyle(color: Color(AppColors.errorText)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    ref.read(authSessionProvider.notifier).signOut();
    if (context.mounted) context.go(AppRoutes.home);
  }
}

/// 头部卡：头像 + 昵称/脱敏号 + 实名状态行。
class _HeaderCard extends StatelessWidget {
  /// 构造头部卡。
  ///
  /// 参数：[profileAsync] 本人资料三态。
  const _HeaderCard({required this.profileAsync});

  /// 本人资料三态。
  final AsyncValue<MyProfileDto> profileAsync;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Color(AppColors.surface),
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: profileAsync.when(
        loading: () => const _HeaderSkeleton(),
        error: (error, _) => _HeaderError(error: asApiException(error)),
        data: (profile) => Row(
          children: [
            _Avatar(url: profile.avatarUrl),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _displayName(profile),
                    style: TextStyle(
                      fontSize: AppTypeScale.h3.size,
                      fontWeight: FontWeight.w600,
                      color: Color(AppColors.textPrimary),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Row(
                    children: [
                      if (profile.isRealnamePassed)
                        Icon(Icons.check, size: 14, color: Color(AppColors.success)),
                      if (profile.isRealnamePassed) const SizedBox(width: AppSpacing.xs),
                      Text(
                        profile.isRealnamePassed ? '已实名' : '未实名',
                        style: TextStyle(
                          fontSize: AppTypeScale.small.size,
                          color: Color(AppColors.textSecondary),
                        ),
                      ),
                      Text(
                        '· 资质认证待完成',
                        style: TextStyle(
                          fontSize: AppTypeScale.small.size,
                          color: Color(AppColors.textSecondary),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 昵称 + 脱敏手机号（契约 `phone_mask` 为空时只显昵称，不补空串）。
  ///
  /// 参数：[profile] 本人资料。
  /// 返回：String 展示名。
  static String _displayName(MyProfileDto profile) {
    final mask = profile.phoneMask;
    if (mask == null || mask.isEmpty) return profile.nickname;
    return '${profile.nickname} $mask';
  }
}

/// 头像（无图时纯色占位圆）。
class _Avatar extends StatelessWidget {
  /// 构造头像。
  ///
  /// 参数：[url] 头像 URL（可空）。
  const _Avatar({required this.url});

  /// 头像 URL。
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: Color(AppColors.primaryLight),
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: url == null
          ? null
          : Image.network(
              url!,
              fit: BoxFit.cover,
              // 头像加载失败退回占位圆，不显示破图。
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
    );
  }
}

/// 头部骨架（首屏加载态）。
class _HeaderSkeleton extends StatelessWidget {
  /// 构造头部骨架。
  const _HeaderSkeleton();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: Color(AppColors.border),
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Container(width: 140, height: 18, color: Color(AppColors.border)),
      ],
    );
  }
}

/// 头部错误态（本人资料拉取失败）。
class _HeaderError extends StatelessWidget {
  /// 构造头部错误态。
  ///
  /// 参数：[error] 归一后的 API 异常。
  const _HeaderError({required this.error});

  /// 归一后的 API 异常。
  final ApiException error;

  @override
  Widget build(BuildContext context) {
    return Text(
      error.uiMessage,
      style: TextStyle(fontSize: AppTypeScale.body.size, color: Color(AppColors.textSecondary)),
    );
  }
}

/// 入口行组（五个入口，每行右侧角标 + chevron）。
class _EntryGroup extends StatelessWidget {
  /// 构造入口行组。
  ///
  /// 参数：[badges] 角标快照（null＝未就绪，不显右值）；[realnamePassed] 是否已实名；
  ///   [onTapMyPublish]/[onTapFavorites]/[onTapNotifications]/[onTapTrust]/[onTapSettings]
  ///   各入口点击回调。
  const _EntryGroup({
    required this.badges,
    required this.realnamePassed,
    required this.onTapMyPublish,
    required this.onTapFavorites,
    required this.onTapNotifications,
    required this.onTapTrust,
    required this.onTapSettings,
  });

  /// 角标快照。
  final MyPageBadges? badges;

  /// 是否已实名（决定「信任与认证」是否显示「去完善」）。
  final bool realnamePassed;

  /// 我的发布入口回调。
  final VoidCallback onTapMyPublish;

  /// 我的收藏入口回调。
  final VoidCallback onTapFavorites;

  /// 通知中心入口回调。
  final VoidCallback onTapNotifications;

  /// 信任与认证入口回调。
  final VoidCallback onTapTrust;

  /// 设置入口回调。
  final VoidCallback onTapSettings;

  @override
  Widget build(BuildContext context) {
    final badge = badges;
    return Column(
      children: [
        _EntryRow(
          label: '我的发布',
          value: badge == null ? null : '${badge.activePosts} 在架',
          onTap: onTapMyPublish,
        ),
        _EntryRow(
          label: '我的收藏',
          value: badge == null ? null : '${badge.favorites}',
          onTap: onTapFavorites,
        ),
        _EntryRow(
          label: '通知中心',
          value: badge == null ? null : '${badge.unread} 未读',
          onTap: onTapNotifications,
        ),
        _EntryRow(
          label: '信任与认证',
          value: realnamePassed ? null : '去完善',
          onTap: onTapTrust,
        ),
        _EntryRow(label: '设置', value: null, onTap: onTapSettings),
      ],
    );
  }
}

/// 单条入口行（listRow：左标签 + 右值 + 尾部 chevron）。
class _EntryRow extends StatelessWidget {
  /// 构造入口行。
  ///
  /// 参数：[label] 左标签；[value] 右值（null＝不建文本节点，chevron 仍渲染）；
  ///   [onTap] 点击回调。
  const _EntryRow({required this.label, required this.value, required this.onTap});

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

/// 退出登录按钮（danger，独立成段）。
class _SignOutButton extends StatelessWidget {
  /// 构造退出登录按钮。
  ///
  /// 参数：[onPressed] 点击回调（二次确认入口）。
  const _SignOutButton({required this.onPressed});

  /// 点击回调。
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(AppColors.errorText),
            foregroundColor: Colors.white,
            elevation: 0,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
          ),
          child: Text(
            '退出登录',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
