/// 信任与认证页（PRD §4.4 `trust-screen`；本轮资质改「档案列表」）。
///
/// 结构（对齐设计稿 `buildTrust`）：
///   ① 第一层 · 个人实名（成功描边卡，通过态 doneTag；未通过则给「去完成实名」入口）
///   ② 第二层 · 资质认证 —— **资质档案列表**（每张证一行：证名 + 已添加 + 编辑 ›，
///      左滑删除，底部「＋ 添加资质」）
///   ③ 我的信任指标（仅在架信息完整度分布；不含实名/资质重复摘要与 T4 声明）
///
/// 交互口径（资质方案 R1/R9/R10）：添加与编辑共用 `qualification_form_screen`；
/// 删除只走档案行左滑（二次确认），编辑页不再承载删除。表单提交成功以 `true`
/// 回传，本页据此刷新总览。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../../domain/listing_detail.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import 'cert_models.dart';
import 'cert_provider.dart';
import 'cert_repository.dart';

/// 信任与认证页。
class TrustScreen extends ConsumerWidget {
  /// 构造信任与认证页。
  const TrustScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overviewAsync = ref.watch(trustOverviewProvider);

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
          '信任与认证',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: overviewAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ListErrorView(
          error: asApiException(error),
          onRetry: () => ref.read(trustOverviewProvider.notifier).refresh(),
        ),
        data: (overview) => RefreshIndicator(
          onRefresh: () => ref.read(trustOverviewProvider.notifier).refresh(),
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.lg),
            children: [
              _Layer1Card(
                cert: overview.cert,
                showRealnameEntry: ref.watch(isLoggedInProvider),
                onGoRealname: () => _openRealname(context, ref),
              ),
              const SizedBox(height: AppSpacing.md),
              _Layer2Card(
                cert: overview.cert,
                onEdit: (item) => _openForm(context, ref, qualification: item),
                onAdd: () => _openForm(context, ref),
                onDelete: (item) => _deleteQualification(context, ref, item),
              ),
              const SizedBox(height: AppSpacing.md),
              _MetricsCard(overview: overview),
            ],
          ),
        ),
      ),
    );
  }

  /// 左滑删除一张资质：二次确认 → 调删除接口 → 刷新总览。
  ///
  /// 删除入口只在档案列表（本页），编辑页不再承载删除，避免表单底部出现
  /// 与主按钮同级的高危操作。返回 true 让 Dismissible 完成滑出动画；
  /// 失败保持行可见并提示。
  ///
  /// 参数：
  ///   [context] 构建上下文；[ref] Provider 容器；[item] 待删除资质。
  /// 返回：[Future<bool>] 是否删除成功。
  static Future<bool> _deleteQualification(
    BuildContext context,
    WidgetRef ref,
    CertQualification item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这张资质？'),
        content: const Text('删除后，已发布的帖子不再展示这张证，且不能撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: Color(AppColors.errorText)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return false;

    try {
      await ref.read(certRepositoryProvider).deleteQualification(item.certId);
      await ref.read(trustOverviewProvider.notifier).refresh();
      return true;
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(asApiException(error).uiMessage)),
        );
      }
      return false;
    }
  }

  /// 打开实名认证页；返回后刷新状态总览。
  ///
  /// 为什么必须刷新：实名结果在返回本页时才可见，若不重拉总览，
  /// 「第一层 · 个人实名」会一直停在「未完成」并继续展示「去完成实名」入口。
  ///
  /// 参数：
  ///   [context] 构建上下文；[ref] Provider 容器。
  /// 返回：[Future<void>]。
  static Future<void> _openRealname(
    BuildContext context,
    WidgetRef ref,
  ) async {
    await context.push(AppRoutes.trustRealname);
    if (!context.mounted) return;
    await ref.read(trustOverviewProvider.notifier).refresh();
  }

  /// 打开资质表单（添加或编辑）；提交/删除成功返回后刷新状态总览。
  ///
  /// 参数：
  ///   [context] 构建上下文；[ref] Provider 容器；
  ///   [qualification] 编辑目标（null = 添加）。
  /// 返回：[Future<void>]。
  static Future<void> _openForm(
    BuildContext context,
    WidgetRef ref, {
    CertQualification? qualification,
  }) async {
    final changed = await context.push<bool>(
      AppRoutes.trustQualification,
      extra: qualification,
    );
    if (changed == true) {
      await ref.read(trustOverviewProvider.notifier).refresh();
    }
  }
}

/// 第一层卡（个人实名）。
class _Layer1Card extends StatelessWidget {
  /// 构造第一层卡。
  ///
  /// 参数：
  ///   [cert] 认证状态；
  ///   [showRealnameEntry] 是否展示「去完成实名」入口（**未登录时不展示**：
  ///     未登录点进去提交只会得到 40101，用户却看到「网络异常」，属误导）；
  ///   [onGoRealname] 未通过时的「去完成实名」回调。
  const _Layer1Card({
    required this.cert,
    required this.showRealnameEntry,
    required this.onGoRealname,
  });

  /// 认证状态。
  final CertStatus cert;

  /// 是否展示「去完成实名」入口（登录后才展示）。
  final bool showRealnameEntry;

  /// 去完成实名回调。
  final VoidCallback onGoRealname;

  @override
  Widget build(BuildContext context) {
    final passed = cert.isRealnamePassed;
    return Container(
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        // 设计稿：通过态卡描边用 color/success（图形色），文字用 success-text，两者不同 hex。
        border: Border.all(
          color: Color(passed ? AppColors.success : AppColors.border),
        ),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (passed)
                Icon(Icons.check, size: 18, color: Color(AppColors.success)),
              if (passed) const SizedBox(width: AppSpacing.xs),
              Text(
                passed ? '第一层 · 个人实名 已通过' : '第一层 · 个人实名 未完成',
                style: TextStyle(
                  fontSize: AppTypeScale.h3.size,
                  fontWeight: FontWeight.w600,
                  color: Color(passed ? AppColors.successText : AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '身份证二要素 + 手机号一致性，发布前置门槛',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          if (!passed && showRealnameEntry) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: onGoRealname,
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
              child: Text(
                '去完成实名 ›',
                style: TextStyle(fontSize: AppTypeScale.small.size, color: Color(AppColors.primary)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 第二层卡（资质档案列表）。
class _Layer2Card extends StatelessWidget {  /// 构造第二层卡。
  ///
  /// 参数：[cert] 认证状态；[onEdit] 编辑某张资质；[onAdd] 添加资质；
  /// [onDelete] 左滑删除某张资质（返回是否删除成功）。
  const _Layer2Card({
    required this.cert,
    required this.onEdit,
    required this.onAdd,
    required this.onDelete,
  });

  /// 认证状态。
  final CertStatus cert;

  /// 编辑回调。
  final ValueChanged<CertQualification> onEdit;

  /// 添加回调。
  final VoidCallback onAdd;

  /// 删除回调：二次确认与请求由页面负责，返回 true 才让行滑出。
  final Future<bool> Function(CertQualification) onDelete;

  @override
  Widget build(BuildContext context) {
    final items = cert.qualifications;
    return Container(
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Color(AppColors.border)),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '第二层 · 资质认证',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '由你自行提供；不添加也不影响发布',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.md),
              child: Text(
                '还没有添加资质',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
            )
          else
            for (final item in items) ...[
              const SizedBox(height: AppSpacing.md),
              Dismissible(
                key: ValueKey('cert-row-${item.certId}'),
                direction: DismissDirection.endToStart,
                background: const _DeleteBackground(),
                confirmDismiss: (_) => onDelete(item),
                child: _CertRow(item: item, onEdit: () => onEdit(item)),
              ),
            ],
          const SizedBox(height: AppSpacing.sm),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: onAdd,
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
              child: Text(
                '＋ 添加资质',
                style: TextStyle(fontSize: AppTypeScale.small.size, color: Color(AppColors.primary)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 左滑露出的删除底色。
class _DeleteBackground extends StatelessWidget {
  /// 构造删除底色。
  const _DeleteBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(AppColors.errorText),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Text(
        '删除',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// 资质档案行（证名 + 已添加 + 编辑 ›）。
class _CertRow extends StatelessWidget {
  /// 构造资质档案行。
  ///
  /// 参数：[item] 资质记录；[onEdit] 编辑回调。
  const _CertRow({required this.item, required this.onEdit});

  /// 资质记录。
  final CertQualification item;

  /// 编辑回调。
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.displayName,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '已添加',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onEdit,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
          child: Text(
            '编辑 ›',
            style: TextStyle(fontSize: AppTypeScale.small.size, color: Color(AppColors.primary)),
          ),
        ),
      ],
    );
  }
}

/// 我的信任指标卡（只留在架信息完整度分布）。
class _MetricsCard extends StatelessWidget {
  /// 构造信任指标卡。
  ///
  /// 参数：[overview] trust 页视图模型。
  const _MetricsCard({required this.overview});

  /// trust 页视图模型。
  final TrustOverview overview;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Color(AppColors.border)),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '我的信任指标',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (overview.activeCount > 0) ...[
            _plain('我在架的 ${overview.activeCount} 条信息完整度分布'),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                for (final level in [
                  CompletenessLevel.green,
                  CompletenessLevel.yellow,
                  CompletenessLevel.red,
                ]) ...[
                  _levelTag(level),
                  const SizedBox(width: AppSpacing.xs),
                  _plain('${overview.countOf(level)} 条'),
                  const SizedBox(width: AppSpacing.md),
                ],
              ],
            ),
          ] else
            _plain('暂无在架信息'),
        ],
      ),
    );
  }

  /// 普通小字（text-secondary）。
  ///
  /// 参数：[text] 文案。
  /// 返回：Widget。
  Widget _plain(String text) => Text(
        text,
        style: TextStyle(fontSize: AppTypeScale.small.size, color: Color(AppColors.textSecondary)),
      );

  /// 完整度档位标记（色点 + 档名，色随档位）。
  ///
  /// 参数：[level] 档位。
  /// 返回：Widget。
  Widget _levelTag(CompletenessLevel level) {
    final (dot, text) = switch (level) {
      CompletenessLevel.green => (AppColors.success, AppColors.successText),
      CompletenessLevel.yellow => (AppColors.warning, AppColors.warningText),
      CompletenessLevel.red => (AppColors.error, AppColors.errorText),
    };
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: Color(dot), shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          level.label,
          style: TextStyle(fontSize: AppTypeScale.small.size, color: Color(text)),
        ),
      ],
    );
  }
}
