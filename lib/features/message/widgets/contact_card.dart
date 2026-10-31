/// 联系方式卡（计划 U13；R22 / R24）。
///
/// 卡片只在发布者同意后出现，且由服务端按 `visible_to` 过滤为「仅申请人可见」；
/// **卡上不承载完整号码**，号码仍只由 `GET /posts/{id}/contact` 返回。
library;

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';

/// 联系方式卡。
class ContactCard extends StatelessWidget {
  /// 构造联系方式卡。
  ///
  /// 参数：[onViewContact] 跳中转页取号；null 表示缺少帖子上下文（按钮置灰）。
  const ContactCard({super.key, required this.onViewContact});

  /// 查看完整号码（跳中转页）。
  final VoidCallback? onViewContact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('contact-card'),
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Color(AppColors.border)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_open_outlined,
                size: 18,
                color: Color(AppColors.successText),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '对方已同意查看联系方式',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '完整号码仅你可见，请勿外传',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: Color(AppColors.textPlaceholder),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              key: const ValueKey<String>('contact-view'),
              onPressed: onViewContact,
              child: const Text('查看完整号码'),
            ),
          ),
        ],
      ),
    );
  }
}
