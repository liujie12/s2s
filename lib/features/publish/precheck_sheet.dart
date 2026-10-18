/// precheck 阻断项弹层（PRD §12.3「blocks[] 一次性给全」的呈现侧）。
///
/// **为什么抽成共享组件**：手动发布页与 AI 确认页都要在 `precheck` 被阻断时
/// 把服务端的 blocks 一次性列给用户。两处各写一份会出现「同一阻断项在两个
/// 入口文案/动作不一致」，而这种不一致没有任何自动化能检出。
///
/// 每项展示服务端 [PrecheckBlockDto.message]（契约「可直接呈现的中文提示」，
/// 逐字照贴不重写 —— 文案口径在服务端）。五码中两码带动作入口（PRD §12.5）：
/// 40302（资质未认证 → 去认证；未绑手机号 → 去绑定）、40304「去实名」，
/// 其余码只陈述（40901 改文案、40902 无媒体时不出现、40303 禁发无出口）。
/// **40302 的双语义**由 [phoneBound] 区分（B2-6a，2026-10-18 裁定扩展该码）。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../router/app_router.dart';
import '../post/post_dto.dart';

/// 弹出 precheck 阻断项列表（模态，必须点「知道了」才关闭）。
///
/// **为什么不是 SnackBar**：阻断是「发布没发生」，4 秒自动消失的提示会让
/// 用户以为按钮没反应（2026-10-17 真机实证）。模态弹层保证用户看到原因。
///
/// 参数：
///   [context] 构建上下文；
///   [blocks] 服务端一次性给全的阻断项；
///   [phoneBound] 当前账号是否已绑手机号（区分 40302 的资质/绑定双语义）。
/// 返回：[Future]，弹层关闭时完成。
Future<void> showPrecheckBlocks(
  BuildContext context,
  List<PrecheckBlockDto> blocks, {
  bool phoneBound = true,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: const Color(AppColors.surface),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (_) => PrecheckSheet(blocks: blocks, phoneBound: phoneBound),
  );
}

/// precheck 阻断项弹层内容。
class PrecheckSheet extends StatelessWidget {
  const PrecheckSheet({
    super.key,
    required this.blocks,
    this.phoneBound = true,
  });

  /// 服务端一次性给全的阻断项。
  final List<PrecheckBlockDto> blocks;

  /// 当前账号是否已绑手机号（B2-6a）。
  final bool phoneBound;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.lg,
          AppSpacing.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '发布前需处理以下问题',
              style: TextStyle(
                fontSize: AppTypeScale.h3.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            for (final block in blocks)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: const Color(AppColors.warningText),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        block.message,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          height: AppTypeScale.body.lineHeight,
                          color: const Color(AppColors.textPrimary),
                        ),
                      ),
                    ),
                    if (_actionRouteOf(block) != null)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: TextButton(
                          // 关弹层再跳：sheet 挂在 root navigator 上，
                          // 不关直接 push 会叠在弹层下面
                          onPressed: () {
                            Navigator.of(context).pop();
                            GoRouter.of(context).push(_actionRouteOf(block)!);
                          },
                          child: Text(
                            _actionLabelOf(block),
                            style: const TextStyle(
                              color: Color(AppColors.primary),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              height: 44,
              child: OutlinedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 五码 → 动作路由映射（唯一实现处；PRD §12.5 客户端行为列）。
  ///
  /// 参数：[block] 阻断项。
  /// 返回：[String?] 路由路径；无动作码（40901/40902/40303）为 null。
  String? _actionRouteOf(PrecheckBlockDto block) {
    return switch (block.code) {
      // 40302 双语义：未绑手机号 → 绑定页；否则 → 信任与认证中心（资质）
      40302 => phoneBound ? AppRoutes.trust : AppRoutes.bindPhone,
      40304 => AppRoutes.trust, // 未实名上限 → 同上（实名在认证中心）
      _ => null,
    };
  }

  /// 五码 → 动作按钮文案。
  ///
  /// 参数：[block] 阻断项。
  /// 返回：[String] 按钮文案（仅 [_actionRouteOf] 非 null 的码会取到）。
  String _actionLabelOf(PrecheckBlockDto block) {
    return switch (block.code) {
      40302 => phoneBound ? '去认证' : '去绑定',
      40304 => '去实名',
      _ => '',
    };
  }
}
