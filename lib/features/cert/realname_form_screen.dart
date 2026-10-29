/// 实名认证表单页（[149]；PRD §4.5 用户旅程步骤 2，路由 `/trust`）。
///
/// 本轮 `trust` 聚焦个人实名（B2-1「实名为主、资质留占位」）：姓名 + 身份证号
/// 二要素 + 协议勾选，提交后调 `POST /cert/realname` 核验。资质二层认证由
/// B2-11「我的页实装」补入，本轮不展开（人工审核未上线）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import 'cert_repository.dart';
import 'realname_agreement_screen.dart';

/// 实名认证表单页。
class RealnameFormScreen extends ConsumerStatefulWidget {
  const RealnameFormScreen({super.key});

  @override
  ConsumerState<RealnameFormScreen> createState() => _RealnameFormScreenState();
}

class _RealnameFormScreenState extends ConsumerState<RealnameFormScreen> {
  /// 身份证号格式（18 位，末位可 X，对齐契约 pattern）。
  static final RegExp _idCardPattern = RegExp(r'^\d{17}[\dXx]$');

  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _idCardController = TextEditingController();

  /// 是否已勾选协议（未勾选按钮禁用，PRD §4.5 步骤 2「勾选协议」）。
  bool _agreed = false;

  /// 提交中。
  bool _submitting = false;

  /// 错误提示（核验不通过 / 服务不可用等）。
  String? _error;

  /// 成功状态（核验通过后为 passed）。
  String? _success;

  @override
  void dispose() {
    _nameController.dispose();
    _idCardController.dispose();
    super.dispose();
  }

  /// 提交实名认证。
  ///
  /// 客户端先自检格式（姓名非空 + 身份证 18 位），再调服务端二要素核验；
  /// 成功置 [_success]、失败按错误码映射 [_error]。
  Future<void> _submit() async {
    final name = _nameController.text.trim();
    final idCard = _idCardController.text.trim();
    if (name.isEmpty || !_idCardPattern.hasMatch(idCard)) {
      setState(() => _error = '请填写姓名与 18 位身份证号');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
      _success = null;
    });
    try {
      final status = await ref.read(certRepositoryProvider).submitRealname(
            realName: name,
            idCard: idCard,
            agreementAccepted: _agreed,
          );
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _success = status;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _messageOf(error);
      });
    }
  }

  /// 把异常映射为面向用户的提示文案。
  ///
  /// 参数：[error] catch 到的对象（ApiException 或传输层异常）。
  /// 返回：[String] 用户可读文案。
  String _messageOf(Object error) {
    final api = error is ApiException ? error : null;
    if (api == null) return '网络异常，请稍后重试';
    final text = switch (api.code) {
      ApiErrorCode.agreementRequired => '请先勾选并同意实名认证相关协议',
      ApiErrorCode.certUnavailable => '认证服务暂时不可用，请稍后重试',
      ApiErrorCode.paramInvalid => '身份信息核验未通过，请检查姓名与身份证号',
      _ => api.message,
    };
    // 统一回显 request_id（§5.3 UI 报错唯一格式 {message}（{request_id}））
    return api.requestId == null ? text : '$text（${api.requestId}）';
  }

  /// 打开《实名认证服务协议》静态页。
  ///
  /// 参数：无。
  /// 返回：[Future] 页面关闭后完成。
  Future<void> _openAgreement() {
    return Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const RealnameAgreementScreen(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('实名认证')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Text(
              '完成实名认证后可无限查看详情、发布不再受限',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.xl),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '真实姓名'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _idCardController,
              keyboardType: TextInputType.visiblePassword,
              decoration: const InputDecoration(labelText: '身份证号'),
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Checkbox(
                  value: _agreed,
                  onChanged: (value) =>
                      setState(() => _agreed = value ?? false),
                ),
                Expanded(
                  child: GestureDetector(
                    onTap: _openAgreement,
                    behavior: HitTestBehavior.opaque,
                    child: Text(
                      '同意《实名认证服务协议》',
                      style: TextStyle(
                        fontSize: AppTypeScale.body.size,
                        color: const Color(AppColors.primary),
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              _Text(
                _error!,
                style: const TextStyle(color: Color(AppColors.warningText)),
              ),
            ],
            if (_success != null) ...[
              const SizedBox(height: AppSpacing.md),
              _Text(
                '实名认证已通过',
                style: const TextStyle(color: Color(AppColors.successText)),
              ),
            ],
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              height: 48,
              child: ElevatedButton(
                onPressed: _agreed && !_submitting ? _submit : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(AppColors.primary),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: const StadiumBorder(),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('提交认证'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 简化文本组件：包裹 overflow 处理，避免长文案溢出。
class _Text extends StatelessWidget {
  const _Text(this.text, {this.style});

  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: style ??
          TextStyle(
            fontSize: AppTypeScale.body.size,
            color: const Color(AppColors.textPrimary),
          ),
    );
  }
}
