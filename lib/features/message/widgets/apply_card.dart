/// 联系方式申请卡（计划 U13；R20 / R21a / R22 / R23）。
///
/// 卡片状态来自 [ContactApplyStateDto]（`conversation.apply_status` 的唯一投影），
/// 不读消息正文 —— 申请卡消息的 `content` 恒为 null。发布者看到「同意 / 拒绝」，
/// 发起人看到申请或倒计时置灰的再申请入口；卡片本身不含号码。
library;

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../message_dto.dart';

/// 申请卡。
class ApplyCard extends StatelessWidget {
  /// 构造申请卡。
  ///
  /// 参数：[apply] 卡片状态（可空：拉取失败时只展示占位说明）；
  ///   [busy] 审批/申请请求在途（禁用全部按钮）；[onApply] 发起或再次申请；
  ///   [onApprove] 发布者同意；[onReject] 发布者拒绝。
  const ApplyCard({
    super.key,
    required this.apply,
    this.busy = false,
    this.onApply,
    this.onApprove,
    this.onReject,
  });

  /// 卡片状态。
  final ContactApplyStateDto? apply;

  /// 请求在途。
  final bool busy;

  /// 发起或再次申请。
  final VoidCallback? onApply;

  /// 发布者同意。
  final VoidCallback? onApprove;

  /// 发布者拒绝。
  final VoidCallback? onReject;

  @override
  Widget build(BuildContext context) {
    final state = apply;
    return Container(
      key: const ValueKey<String>('apply-card'),
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
                Icons.assignment_ind_outlined,
                size: 18,
                color: Color(AppColors.primary),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '联系方式申请',
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
            state == null ? '卡片状态暂不可用，请稍后刷新' : _statusText(state),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              height: 1.4,
              color: Color(AppColors.textSecondary),
            ),
          ),
          if (state != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _actions(state),
          ],
        ],
      ),
    );
  }

  /// 组装卡片按钮区（发布者审批 / 发起人申请或倒计时置灰）。
  ///
  /// 参数：[state] 卡片状态。
  /// 返回：Widget；无可用动作时为空占位。
  Widget _actions(ContactApplyStateDto state) {
    if (state.owner) {
      if (state.applyStatus != 'pending') return const SizedBox.shrink();
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton(
            key: const ValueKey<String>('apply-reject'),
            onPressed: busy ? null : onReject,
            child: const Text('拒绝'),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            key: const ValueKey<String>('apply-approve'),
            onPressed: busy ? null : onApprove,
            child: const Text('同意'),
          ),
        ],
      );
    }
    if (state.applyStatus == 'approved') return const SizedBox.shrink();
    final label = _applyButtonLabel(state);
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        key: const ValueKey<String>('apply-reapply'),
        onPressed: busy || !state.canApply ? null : onApply,
        child: Text(label),
      ),
    );
  }

  /// 发起人按钮文案。
  ///
  /// 参数：[state] 卡片状态。
  /// 返回：Widget 按钮上呈现的文案。
  String _applyButtonLabel(ContactApplyStateDto state) {
    if (!state.canApply) {
      if (state.applyStatus == 'rejected') {
        final days = _remainingDays(state.reapplyAt);
        return days > 0 ? '$days 天后可再次申请' : '冷却结束后可再次申请';
      }
      return '等待对方处理';
    }
    return state.applyStatus == 'none' ? '申请查看联系方式' : '再次申请';
  }

  /// 状态说明文案。
  ///
  /// 参数：[state] 卡片状态。
  /// 返回：一行用户可读说明（R21a 的剩余天数在此拼接）。
  String _statusText(ContactApplyStateDto state) {
    if (state.owner) {
      return switch (state.applyStatus) {
        'pending' => '对方申请查看你的联系方式',
        'approved' => '已同意对方查看联系方式',
        'rejected' => '已拒绝本次申请',
        _ => '对方尚未申请查看联系方式',
      };
    }
    return switch (state.applyStatus) {
      'pending' => '申请已提交，等待对方处理',
      'approved' => '已同意查看联系方式',
      'rejected' => _rejectedText(state),
      _ => '对方设置了查看联系方式需申请',
    };
  }

  /// 被拒文案（含剩余天数）。
  ///
  /// 参数：[state] 卡片状态。
  /// 返回：形如「未同意 · 剩余 3 天可再次申请」。
  String _rejectedText(ContactApplyStateDto state) {
    final days = _remainingDays(state.reapplyAt);
    if (days <= 0) return '未同意 · 现在可以再次申请';
    return '未同意 · 剩余 $days 天可再次申请';
  }

  /// 计算距离可再次申请还有几天（向上取整，不足一天按 1 天）。
  ///
  /// 参数：[at] 服务端给出的 `reapply_at`（可空）。
  /// 返回：非负整数天；null 或已过期返回 0。
  static int _remainingDays(DateTime? at) {
    if (at == null) return 0;
    final diff = at.difference(DateTime.now());
    if (diff.isNegative) return 0;
    return (diff.inHours / 24).ceil();
  }
}
