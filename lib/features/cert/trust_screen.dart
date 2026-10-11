/// 信任与认证页（PRD §4.4 `trust-screen`；[B2-11] 由实名表单改为状态总览）。
///
/// 结构（对齐设计稿 `buildTrust`）：三张卡 ——
///   ① 第一层 · 个人实名（成功描边卡，通过态 doneTag；未通过则给「去完成实名」入口）
///   ② 第二层 · 资质认证（企业认证 / 家政资质 / 车辆认证 三行）
///   ③ 我的信任指标（实名 / 资质 N 项 / 完整度 + 在架信息完整度分布 + T4 红线注）
///
/// **降级（如实登记）**：资质行的动作（`去认证`/`查看`/`管理`）与资质**提交**均依赖
/// 媒体上传链路，而该链路在 Batch1 **未实现**（`publish_screen` 同因：上传依赖
/// `post_media` 与 CDN，发布侧 `media_ids` 恒空），`POST /cert/qualification` 的
/// `media_ids` 为必填 ⇒ 资质提交无法端到端。故本轮资质行动作按既有降级口径
/// 提示「本期内测版暂未开放」，不做假上传。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../../domain/listing_detail.dart';
import '../../router/app_router.dart';
import 'cert_models.dart';
import 'cert_provider.dart';

/// 资质行的契约类型（设计稿三行固定：企业认证 / 家政资质 / 车辆认证）。
enum _QualificationRow {
  /// 企业认证。
  enterprise('enterprise', '企业认证'),

  /// 家政资质（契约 `personal_qualification`）。
  personalQualification('personal_qualification', '家政资质'),

  /// 车辆认证。
  vehicle('vehicle', '车辆认证');

  const _QualificationRow(this.apiType, this.label);

  /// 契约类型值。
  final String apiType;

  /// 展示名。
  final String label;
}

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
                onGoRealname: () => context.push(AppRoutes.trustRealname),
              ),
              const SizedBox(height: AppSpacing.md),
              _Layer2Card(cert: overview.cert, onAction: () => _notOpen(context)),
              const SizedBox(height: AppSpacing.md),
              _MetricsCard(overview: overview),
            ],
          ),
        ),
      ),
    );
  }

  /// 未开放提示（资质提交/管理类动作的降级落点）。
  ///
  /// 参数：[context] 构建上下文。
  /// 返回：void。
  static void _notOpen(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('本期内测版暂未开放')),
    );
  }
}

/// 第一层卡（个人实名）。
class _Layer1Card extends StatelessWidget {
  /// 构造第一层卡。
  ///
  /// 参数：[cert] 认证状态；[onGoRealname] 未通过时的「去完成实名」回调。
  const _Layer1Card({required this.cert, required this.onGoRealname});

  /// 认证状态。
  final CertStatus cert;

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
          if (!passed) ...[
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

/// 第二层卡（资质认证三行）。
class _Layer2Card extends StatelessWidget {
  /// 构造第二层卡。
  ///
  /// 参数：[cert] 认证状态；[onAction] 行动作回调（本轮统一降级提示）。
  const _Layer2Card({required this.cert, required this.onAction});

  /// 认证状态。
  final CertStatus cert;

  /// 行动作回调。
  final VoidCallback onAction;

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
            '第二层 · 资质认证',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.textPrimary),
            ),
          ),
          for (final row in _QualificationRow.values) ...[
            const SizedBox(height: AppSpacing.md),
            _CertRow(
              label: row.label,
              qualification: cert.qualificationOf(row.apiType),
              onAction: onAction,
            ),
          ],
        ],
      ),
    );
  }
}

/// 资质行（标签 + 状态点/文案 + 右侧动作 + chevron）。
class _CertRow extends StatelessWidget {
  /// 构造资质行。
  ///
  /// 参数：[label] 类型展示名；[qualification] 该类型记录（未提交为 null）；
  ///   [onAction] 右侧动作回调。
  const _CertRow({
    required this.label,
    required this.qualification,
    required this.onAction,
  });

  /// 类型展示名。
  final String label;

  /// 该类型记录（未提交为 null）。
  final CertQualification? qualification;

  /// 右侧动作回调。
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final status = qualification?.status;
    final view = _viewOf(status);
    // 元信息：已通过且有有效期 → 回显到期日；其余状态契约无对应字段，不伪造。
    final meta = status == 'passed' && qualification?.expireAt != null
        ? _formatDate(qualification!.expireAt!)
        : null;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Row(
                children: [
                  Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(color: Color(view.dotColor), shape: BoxShape.circle),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    view.label,
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: Color(view.textColor),
                    ),
                  ),
                  if (meta != null) ...[
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      meta,
                      style: TextStyle(
                        fontSize: AppTypeScale.small.size,
                        color: Color(AppColors.textSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
        TextButton(
          onPressed: onAction,
          style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
          child: Text(
            '${view.action} ›',
            style: TextStyle(fontSize: AppTypeScale.small.size, color: Color(AppColors.primary)),
          ),
        ),
      ],
    );
  }

  /// 状态 → 展示（点色 / 文字色 / 文案 / 动作）。
  ///
  /// 参数：[status] 契约状态值（null＝未提交）。
  /// 返回：`(dotColor, textColor, label, action)`。
  static ({int dotColor, int textColor, String label, String action}) _viewOf(String? status) =>
      switch (status) {
        'passed' => (
            dotColor: AppColors.success,
            textColor: AppColors.successText,
            label: '已通过',
            action: '管理',
          ),
        'pending' => (
            dotColor: AppColors.warning,
            textColor: AppColors.warningText,
            label: '审核中',
            action: '查看',
          ),
        'rejected' => (
            dotColor: AppColors.error,
            textColor: AppColors.errorText,
            label: '未通过',
            action: '重新提交',
          ),
        _ => (
            dotColor: AppColors.error,
            textColor: AppColors.errorText,
            label: '未认证',
            action: '去认证',
          ),
      };

  /// 日期格式化为 `yyyy-MM-dd`。
  ///
  /// 参数：[value] 时间。
  /// 返回：String。
  static String _formatDate(DateTime value) {
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    return '${value.year}-$month-$day';
  }
}

/// 我的信任指标卡。
class _MetricsCard extends StatelessWidget {
  /// 构造信任指标卡。
  ///
  /// 参数：[overview] trust 页视图模型。
  const _MetricsCard({required this.overview});

  /// trust 页视图模型。
  final TrustOverview overview;

  @override
  Widget build(BuildContext context) {
    final cert = overview.cert;
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
          Row(
            children: [
              if (cert.isRealnamePassed) ...[
                Icon(Icons.check, size: 14, color: Color(AppColors.success)),
                const SizedBox(width: AppSpacing.xs),
                _plain('实名'),
              ],
              const SizedBox(width: AppSpacing.md),
              Icon(Icons.check, size: 14, color: Color(AppColors.success)),
              const SizedBox(width: AppSpacing.xs),
              _plain('资质 ${cert.passedQualificationCount} 项'),
              const SizedBox(width: AppSpacing.md),
              _plain('完整度'),
              const SizedBox(width: AppSpacing.xs),
              _levelTag(overview.dominantLevel),
            ],
          ),
          if (overview.activeCount > 0) ...[
            const SizedBox(height: AppSpacing.sm),
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
          ],
          const SizedBox(height: AppSpacing.sm),
          Text(
            '只看信息真实性与完整性，不做人的信誉评级（T4 红线）',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
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
