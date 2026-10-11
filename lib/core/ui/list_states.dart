/// 列表通用状态件（[B2-11] 在收藏页出现第二处需求后上浮为唯一实现处，
/// 编码规范 §1.1「同一逻辑第二次出现即抽公共件」）。
///
/// 收录两类完全同形的列表状态：
///   - [ListEndRow]：分页收尾条「没有更多了」；
///   - [ListErrorView]：`AsyncValue.error` 的三态渲染（文案 + 按行为表给重试）。
///
/// 页面各自的**空态**文案差异大（如我的发布按页签、收藏页按有无数据），故空态
/// 仍留在各页私有实现，不上浮。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../network/api_error_code.dart';
import '../network/api_exception.dart';

/// 分页收尾条。
class ListEndRow extends StatelessWidget {
  /// 构造收尾条。
  const ListEndRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xl),
      child: Center(
        child: Text(
          '没有更多了',
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}

/// 列表错误态（按 §12.2 行为表区分「确定性失败」与「可重试」）。
class ListErrorView extends StatelessWidget {
  /// 构造错误态。
  ///
  /// 参数：[error] 归一后的 API 异常；[onRetry] 重试回调。
  const ListErrorView({super.key, required this.error, required this.onRetry});

  /// 归一后的 API 异常。
  final ApiException error;

  /// 重试回调。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    // 仅这两种行为给用户显式重试入口：autoRetry（链路已自动退避过 2 次）
    // 与 promptWithRetryAfter（按 Retry-After 提示后由用户发起）；
    // 其余（如 40903 forceRefetch、40101 refreshToken）由各自流程接管，
    // 兜底桶 deterministicFail 只给文案。
    final behavior = error.code.behavior;
    final canRetry = behavior == ErrBehavior.autoRetry
        || behavior == ErrBehavior.promptWithRetryAfter;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              error.uiMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
            if (canRetry) ...[
              const SizedBox(height: AppSpacing.md),
              TextButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
