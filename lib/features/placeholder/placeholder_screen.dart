/// 页面占位屏。
///
/// 存在意义：路由骨架先于页面实现落地，若用空白 Scaffold 占位，
/// 跑起来看到白屏会分不清是「没实现」还是「实现了但渲染失败」。
/// 本屏显著显示页面 ID 与关键特征，一眼可辨。
///
/// 同时它是 Design Token 的第一个消费位 —— 若 Token 接错，这里会立刻变样。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// 未实现页面的占位显示。
///
/// 参数：
/// - [pageId]：PRD §10.1 的页面 ID，便于与文档对照。
/// - [pageName]：页面中文名。
/// - [note]：关键特征描述，提示这一页要做什么。
class PlaceholderScreen extends StatelessWidget {
  final String pageId;
  final String pageName;
  final String note;

  const PlaceholderScreen({
    super.key,
    required this.pageId,
    required this.pageName,
    required this.note,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      appBar: AppBar(
        title: Text(pageName),
        backgroundColor: const Color(AppColors.primary),
        foregroundColor: const Color(AppColors.surface),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: const Color(AppColors.warning),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  '未实现',
                  style: TextStyle(
                    color: const Color(AppColors.surface),
                    fontSize: AppTypeScale.caption.size,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                pageId,
                style: TextStyle(
                  color: const Color(AppColors.textPrimary),
                  fontSize: AppTypeScale.h2.size,
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                note,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: const Color(AppColors.textSecondary),
                  fontSize: AppTypeScale.body.size,
                  height: AppTypeScale.body.lineHeight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
