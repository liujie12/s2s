/// 认证拦截浮层（PRD §4.4 末段 / §5.8「强制认证拦截」，页面 ID：cert-modal）。
///
/// **为什么是独立页面而非发布页里的 showModalBottomSheet**：§10.1 把它登记为
/// 一个页面 ID，Figma 稿里也有对应框。做成 sheet 后它既不在路由表里、
/// 也无法深链，验收时无从对照那张框。
///
/// **为什么不给「已持有资质则直接放行」这条分支**：判定要读用户已通过的资质
/// 列表（§12.4），无服务端时本地没有任何来源。写一个恒为 false 的判定
/// 再套上 if，读代码的人会以为放行逻辑已经有了。发布页在调用前直接拦。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../domain/category_tree.dart';

/// 认证拦截底部抽屉。
///
/// 用法：`context.push<bool>(AppRoutes.certModal, extra: cert)`，
/// 用户点「去认证」返回 true，点「暂不发布」或返回手势返回 null。
class CertModalScreen extends StatelessWidget {
  const CertModalScreen({super.key, required this.cert});

  /// 该分类要求的资质（§2.4 每个叶子上的 `requiredCert`）。
  final RequiredCert cert;

  /// 抽屉标题（§4.4 句式「发布此分类需要家政资质认证」）。
  ///
  /// **为什么不直接拼 `'需要${cert.label}认证'`**：`RequiredCert.label` 里
  /// 「企业认证」「车辆认证」本身已带「认证」二字，直接拼会得到
  /// 「需要企业认证认证」。这类叠字在人眼过页面时会被当成手滑而不是逻辑错，
  /// 于是改文案改一处、下次换个资质又冒出来。
  String get title {
    final need = cert.label.endsWith('认证') ? cert.label : '${cert.label}认证';
    return '发布此分类需要$need';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 半透明底 + 内容贴底，做出底部抽屉的观感（§4.4「弹底部抽屉」）。
      // 用 Scaffold 而非 Dialog：它要作为一条路由存在（见文件头）。
      backgroundColor: Colors.black.withValues(alpha: 0.4),
      body: Column(
        children: [
          // 点空白处关闭，等同「暂不发布」。返回 null 而非 false ——
          // 调用方只关心「是否要去认证」，两种关闭方式没有区别。
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
            ),
          ),
          _Sheet(title: title),
        ],
      ),
    );
  }
}

class _Sheet extends StatelessWidget {
  const _Sheet({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AppRadius.xl),
        ),
      ),
      padding: EdgeInsets.only(
        left: AppSpacing.xl,
        right: AppSpacing.xl,
        top: AppSpacing.xl,
        bottom: AppSpacing.xl + MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  // warning 是图形色，压浅底承载文字须换 warningText
                  //（design_tokens 已实算，contact_screen.dart:550 同配方）
                  color: const Color(AppColors.warning).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.workspace_premium_outlined,
                  size: 20,
                  color: Color(AppColors.warningText),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: AppTypeScale.h3.size,
                    fontWeight: FontWeight.w600,
                    color: const Color(AppColors.textPrimary),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            // §4.4 说明文案，逐字照抄。
            '认证通过后可终身使用（每年年审一次）',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              height: AppTypeScale.small.lineHeight,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppColors.primary),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: const StadiumBorder(),
              ),
              child: Text(
                '去认证',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 48,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                // §4.4 第二个按钮：返回表单而非丢弃已填内容 ——
                // 发布页是 push 上来的，pop 回去表单状态原样保留。
                '暂不发布',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
