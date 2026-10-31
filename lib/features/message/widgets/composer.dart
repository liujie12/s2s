/// 会话输入区（计划 U13；R26 / R28 / R30）。
///
/// 三态由调用方经 [disabled] + [hintText] 表达：
///   1. 正常：可输入、可发送；
///   2. 未回复达上限：整体禁用，提示「等待对方回复后可继续发送」；
///   3. 维护只读：整体禁用，顶部横幅由页面负责，这里提示暂不可发送。
///
/// 敏感词拒发后的行内提示也在这里呈现：**只给结论、不展示命中词**，
/// 并附「误拦反馈」入口（R28）。输入框原文由调用方决定是否清空。
library;

import 'package:flutter/material.dart';

import '../../../design_tokens.dart';
import '../../../nfr_constants.dart';

/// 会话输入区。
class Composer extends StatelessWidget {
  /// 构造输入区。
  ///
  /// 参数：[controller] 文本控制器（由页面持有，便于拒发时保留原文）；
  ///   [disabled] 是否整体禁用；[hintText] 占位/禁用提示；
  ///   [onSend] 发送回调（参数为当前原文）；[inlineError] 行内提示（可空）；
  ///   [onMisblockFeedback] 「误拦反馈」回调（null 时不渲染该入口）。
  const Composer({
    super.key,
    required this.controller,
    required this.disabled,
    required this.hintText,
    required this.onSend,
    this.inlineError,
    this.onMisblockFeedback,
  });

  /// 文本控制器。
  final TextEditingController controller;

  /// 是否整体禁用。
  final bool disabled;

  /// 占位/禁用提示。
  final String hintText;

  /// 发送回调。
  final ValueChanged<String> onSend;

  /// 行内提示。
  final String? inlineError;

  /// 误拦反馈回调。
  final VoidCallback? onMisblockFeedback;

  @override
  Widget build(BuildContext context) {
    final error = inlineError;
    return Container(
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        border: Border(top: BorderSide(color: Color(AppColors.border))),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error != null)
                Padding(
                  key: const ValueKey<String>('composer-inline-error'),
                  padding: const EdgeInsets.only(bottom: AppSpacing.xs),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        size: 14,
                        color: Color(AppColors.errorText),
                      ),
                      const SizedBox(width: AppSpacing.xs),
                      Expanded(
                        child: Text(
                          error,
                          style: TextStyle(
                            fontSize: AppTypeScale.caption.size,
                            color: Color(AppColors.errorText),
                          ),
                        ),
                      ),
                      if (onMisblockFeedback != null)
                        TextButton(
                          key: const ValueKey<String>('composer-misblock'),
                          onPressed: onMisblockFeedback,
                          child: const Text('误拦反馈'),
                        ),
                    ],
                  ),
                ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey<String>('composer-field'),
                      controller: controller,
                      enabled: !disabled,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: NfrChat.messageContentMaxLength,
                      textInputAction: TextInputAction.newline,
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        color: Color(AppColors.textPrimary),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        counterText: '',
                        hintText: hintText,
                        hintStyle: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          color: Color(AppColors.textPlaceholder),
                        ),
                        filled: true,
                        fillColor: Color(AppColors.background),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.sm,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(AppRadius.lg),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) {
                      final canSend = !disabled && value.text.trim().isNotEmpty;
                      return IconButton(
                        key: const ValueKey<String>('composer-send'),
                        onPressed: canSend
                            ? () => onSend(controller.text)
                            : null,
                        icon: Icon(
                          Icons.send,
                          size: 22,
                          color: canSend
                              ? Color(AppColors.primary)
                              : Color(AppColors.textPlaceholder),
                        ),
                        tooltip: '发送',
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
