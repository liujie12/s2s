/// 会话气泡与日分组标题（计划 U13；R6 / R17）。
///
/// 气泡只负责「一行消息长什么样」，左右由 [mine] 决定；已读回执与本地
/// 发送状态由调用方算好放进 [footnote]，本文件不读 Provider、不做判定 ——
/// 白盒测试因此可以直接断言文案，不必装配网络。
library;

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';

/// 跨日分组标题（今天 / 昨天 / 更早）。
class DayDivider extends StatelessWidget {
  /// 构造分组标题。
  ///
  /// 参数：[label] 分组文案（由调用方按日期算出）。
  const DayDivider({super.key, required this.label});

  /// 分组文案。
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: Color(AppColors.background),
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: Color(AppColors.textPlaceholder),
            ),
          ),
        ),
      ),
    );
  }
}

/// 文本消息气泡（含发送中 / 发送失败 / 已读未读脚注）。
class MessageBubble extends StatelessWidget {
  /// 构造气泡。
  ///
  /// 参数：[content] 正文；[mine] 是否我方发出（左侧为对方、右侧为我方）；
  ///   [footnote] 气泡下方脚注（可空）；[footnoteIsError] 脚注是否用错误色；
  ///   [onRetry] 点击脚注重发（仅失败态传入）。
  const MessageBubble({
    super.key,
    required this.content,
    required this.mine,
    this.footnote,
    this.footnoteIsError = false,
    this.onRetry,
  });

  /// 正文。
  final String content;

  /// 是否我方发出。
  final bool mine;

  /// 气泡下方脚注。
  final String? footnote;

  /// 脚注是否用错误色。
  final bool footnoteIsError;

  /// 点击脚注重发。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final maxWidth = MediaQuery.sizeOf(context).width * 0.72;
    final bubble = Container(
      constraints: BoxConstraints(maxWidth: maxWidth),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: mine ? Color(AppColors.primary) : Color(AppColors.surface),
        border: mine ? null : Border.all(color: Color(AppColors.border)),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadius.lg),
          topRight: const Radius.circular(AppRadius.lg),
          bottomLeft: Radius.circular(mine ? AppRadius.lg : AppRadius.sm),
          bottomRight: Radius.circular(mine ? AppRadius.sm : AppRadius.lg),
        ),
      ),
      child: Text(
        content,
        style: TextStyle(
          fontSize: AppTypeScale.body.size,
          height: 1.4,
          color: mine ? Color(AppColors.surface) : Color(AppColors.textPrimary),
        ),
      ),
    );

    final note = footnote;
    final noteWidget = note == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              note,
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: footnoteIsError
                    ? Color(AppColors.errorText)
                    : Color(AppColors.textPlaceholder),
              ),
            ),
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: mine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          if (noteWidget != null) InkWell(onTap: onRetry, child: noteWidget),
        ],
      ),
    );
  }
}
