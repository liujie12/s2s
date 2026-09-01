/// 发布完成页（PRD §8 T6-④ 完整度卡 / §9.8 三档 / §5.11 一小时引导，
/// 页面 ID：publish-success-screen）。
///
/// **它取代的是一个 toast**（§8 T6-④「取代现有单纯『发布成功』toast」）。
/// 理由在 §5.11：🔴/🟡 档的发布，**发布完成的那一刻是唯一还能抓住用户去补全的
/// 时机** —— 一个 2 秒就消失的 toast 里放不下「还差什么 + 补了能得到什么」。
///
/// **本轮降级（写明以免误认为已实现）**：
/// - **未真正入库**：§12.3 `POST /posts` 无服务端，本页展示的是提交前那份
///   表单快照算出来的档位，不是服务器回执；
/// - **「立即补齐」跳回发布页**：§5.11 说的补全页（编辑态）属「我的发布」范围，
///   M4 未排。跳回发布页能让门牌号与三级类目真的补上，但会**丢失已填内容** ——
///   故按钮文案写「回去补齐」而非「立即补齐」，不承诺它保留现场；
/// - **1 小时倒计时不做**（§5.11「发布后 1 小时内完整度提升引导」）：
///   倒计时的起点是服务端的 `created_at`，客户端自己记时清缓存即失效。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../domain/listing_detail.dart';
import '../../domain/publish_completeness.dart';
import '../../router/app_router.dart';
import 'publish_form_state.dart';

/// 发布完成页。
///
/// 参数 [form] 提交时的表单快照，用于算 §9.8 档位。为空时按 🔴 档展示 ——
/// **不默认成 🟢**：拿不到数据就说「完整」，等于把最坏情况显示成最好情况。
class PublishSuccessScreen extends StatelessWidget {
  const PublishSuccessScreen({super.key, this.form});

  final PublishFormState? form;

  @override
  Widget build(BuildContext context) {
    final assessment = form?.completeness ??
        const CompletenessAssessment(
          requiredFieldsComplete: false,
          hasDoorNumber: false,
          leafCategoryPrecise: false,
        );

    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.xl),
          children: [
            const SizedBox(height: AppSpacing.xl),
            const Center(
              child: Icon(
                Icons.check_circle,
                size: 56,
                color: Color(AppColors.successText),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Center(
              child: Text(
                '发布成功',
                style: TextStyle(
                  fontSize: AppTypeScale.h2.size,
                  fontWeight: FontWeight.w600,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                '附近的人将看到你的信息',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            _CompletenessCard(assessment: assessment),
            const SizedBox(height: AppSpacing.lg),
            const _ValidityNote(),
            const SizedBox(height: AppSpacing.lg),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => GoRouter.of(context).go(AppRoutes.home),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      side: const BorderSide(color: Color(AppColors.primary)),
                      foregroundColor: const Color(AppColors.primary),
                      shape: const StadiumBorder(),
                    ),
                    child: const Text('去首页看效果'),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextButton(
                    // ⚠️ 临时降级（2026-09-01 用户裁定）：PRD §5.8 明文「发布成功
                    // 默认跳『我的发布』」，Figma 稿亦忠于该口径。此处偏离**不是**
                    // 设计决定，只因 my-publish-screen 属 §8.3.1、M4 未排、
                    // 路由表里没有它 —— 指向一个不存在的路由会白屏，比少一个出口更糟。
                    //
                    // **移除条件**：my-publish-screen 落地后，此处改回
                    // 「我的发布」+ 指向该页，并从 probe-layout-offline.js 的
                    // KNOWN_BTN_DOWNGRADES 删掉备案（不删则「备案无过期项」那条报红）。
                    onPressed: () => GoRouter.of(context).go(AppRoutes.profile),
                    style: TextButton.styleFrom(
                      minimumSize: const Size.fromHeight(44),
                      foregroundColor: const Color(AppColors.textSecondary),
                    ),
                    child: const Text('去「我的」'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 完整度卡（§8 T6-④「当前档 + 还差哪几项到下一档 + 对应具体权益三条」）。
class _CompletenessCard extends StatelessWidget {
  const _CompletenessCard({required this.assessment});

  final CompletenessAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final level = assessment.level;
    final (accent, textColor) = switch (level) {
      CompletenessLevel.green => (AppColors.success, AppColors.successText),
      CompletenessLevel.yellow => (AppColors.warning, AppColors.warningText),
      CompletenessLevel.red => (AppColors.error, AppColors.errorText),
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Color(accent)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: Color(accent),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                // 档名只从 level.label 取一次。写成「当前完整度 🟡 半完整」
                // 这种档名重复出现两处的写法，改档位时必漏改一处
                '当前完整度：${level.label}',
                style: TextStyle(
                  fontSize: AppTypeScale.h3.size,
                  fontWeight: FontWeight.w600,
                  color: Color(textColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '三条件满足 ${assessment.metCount} / 3（依据 §9.8）',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.textPlaceholder),
            ),
          ),

          // 已达最高档时不显示差项与权益 —— §9.8 表里 🟢 档的「升级引导」列
          // 就是一个破折号，没有下一档可去
          if (assessment.isTop) ...[
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                const Icon(
                  Icons.verified_outlined,
                  size: 16,
                  color: Color(AppColors.successText),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '已是最高档，推荐池权重 ×${assessment.weight.round()}，'
                    '附近人 2 倍概率看到你',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: const Color(AppColors.successText),
                    ),
                  ),
                ),
              ],
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              '还差这些升「${CompletenessLevel.green.label}」',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            // 列全部差项而非只列一项：§5.11 要「30 秒补上」，
            // 前提是用户一眼知道要补几样（与发布页 blocker 只报一条相反 ——
            // 那里是拦截，这里是清单）
            for (final gap in assessment.missing)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '· ${gap.gapLabel}',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.textPrimary),
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '升「${CompletenessLevel.green.label}」能得到',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            for (final benefit in assessment.benefits)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '· $benefit',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.textPrimary),
                  ),
                ),
              ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: 44,
              child: ElevatedButton(
                // 跳回发布页而非补全页：编辑态属「我的发布」范围（见文件头）。
                // 文案不写「立即补齐」—— 它不保留现场，承诺了就是骗人
                onPressed: () => GoRouter.of(context).go(AppRoutes.publish),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(AppColors.primary),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: const StadiumBorder(),
                ),
                child: Text(
                  '回去补齐（约 30 秒）',
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 有效期说明（§5.11「默认 7 天」+「7 天一键刷新」+「14 天不刷新自动下架」）。
///
/// 放在完成页而不只放在发布页：发布页那一行是「将挂多久」，
/// 而用户真正需要记住「7 天后会来问你还在不在」的时刻是刚发完。
class _ValidityNote extends StatelessWidget {
  const _ValidityNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(AppColors.background),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.schedule,
            size: 16,
            color: Color(AppColors.textSecondary),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '有效期 $kDefaultValidDays 天。到期我们会问你「这条还在吗」，'
              '点一下续 $kDefaultValidDays 天；14 天没刷新会自动从推荐里退出，'
              '但不会删除。',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                height: AppTypeScale.caption.lineHeight,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
