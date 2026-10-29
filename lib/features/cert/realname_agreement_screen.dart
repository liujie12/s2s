/// 实名认证服务协议（静态页）。
///
/// 合规背景：实名页会采集姓名与身份证号，**必须有可阅读的告知文本**再让用户勾选。
/// 2026-10-29 真机评审发现原实现只有「同意《实名认证服务协议》」一行文字且点不动，
/// 本项目也没有对应文档，属合规缺口，故补此页。
///
/// 形态选择：**应用内静态页**而非在线 URL —— 该协议只服务于 App 内实名场景，
/// 不像隐私政策那样需要独立可访问 URL 供应用商店审核（见 privacy_gate_screen.dart
/// 的三条约束），因此不引入外部依赖与网络失败面。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// 实名认证服务协议页。
///
/// 用法：由实名表单页以 MaterialPageRoute 推入（见 realname_form_screen.dart
/// 的 `_openAgreement`），关闭即返回实名表单，勾选状态保持不变。
class RealnameAgreementScreen extends StatelessWidget {
  /// 构造协议页。
  ///
  /// 参数：无。
  /// 返回：[RealnameAgreementScreen]。
  const RealnameAgreementScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      appBar: AppBar(title: const Text('实名认证服务协议')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.md,
            AppSpacing.lg,
            AppSpacing.xl,
          ),
          children: const [
            _AgreementSection(
              title: '一、我们收集什么',
              body: '为完成实名认证，我们会收集你的姓名与身份证号码。'
                  '这两项仅用于确认「你是你本人」，不会用于营销，也不会展示给其他用户。',
            ),
            _AgreementSection(
              title: '二、用来做什么',
              body: '实名结果用于判定账号是否具备发布高敏类目信息的资格，'
                  '以及平台对信息发布者的最低真实性要求。未完成实名不影响浏览、收藏等基础功能，'
                  '但无法发布高敏类目信息。',
            ),
            _AgreementSection(
              title: '三、如何核验',
              body: '我们会将姓名与身份证号提交给依法合规的实名核验服务方，'
                  '按「姓名 + 身份证号」二要素进行一致性比对；核验服务方仅返回比对结论，'
                  '不会将你的信息用于其他目的。',
            ),
            _AgreementSection(
              title: '四、如何保存',
              body: '核验通过后，平台保存核验结论与必要的时间记录；'
                  '身份证号按平台加密规范加密存储，仅授权系统在核验与审计场景解密，'
                  '任何解密操作都会留痕。',
            ),
            _AgreementSection(
              title: '五、你的权利',
              body: '你可以随时在「我的 → 信任与认证」查看实名状态；'
                  '如需更正信息或注销账号，可按设置页指引操作，'
                  '注销后我们将按法律法规要求在期限内删除或匿名化相关个人信息。',
            ),
            _AgreementSection(
              title: '六、拒绝提供的后果',
              body: '实名认证为自愿。拒绝提供姓名与身份证号时，你仍可正常浏览、搜索、收藏，'
                  '仅无法发布需要实名的信息。',
            ),
            _AgreementSection(
              title: '七、协议更新',
              body: '本协议内容如发生重大变更，我们会在 App 内以显著方式提示，'
                  '并在你重新确认后再继续提供实名服务。',
            ),
          ],
        ),
      ),
    );
  }
}

/// 协议单段（小标题 + 正文）。
class _AgreementSection extends StatelessWidget {
  /// 构造协议段。
  ///
  /// 参数：
  ///   [title] 小标题；
  ///   [body] 正文。
  /// 返回：[_AgreementSection]。
  const _AgreementSection({required this.title, required this.body});

  /// 小标题。
  final String title;

  /// 正文。
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            body,
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              height: 1.6,
              color: const Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
