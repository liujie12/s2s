/// 资质认证提交页（[B2-11]；契约 `POST /cert/qualification`）。
///
/// **无 Figma 稿（如实登记）**：`code.js` 的 21 个 builder 里**没有**资质提交页
/// （认证类只有 `trust-screen` 状态页与 `cert-modal` 拦截浮层），故本页按仓库
/// 既有**同类表单页**的形态落地（对齐 `realname_form_screen.dart`：顶部说明 +
/// 表单项 + 底部主按钮），字段口径全部取自契约：
///   - `cert_type`：`CertTypeEnum` 的三类资质（选其一，必填）；
///   - `media_ids`：OCR 证照图（**必填**，须先经上传链路 commit 成功）。
///
/// 契约未规定 `media_ids` 的张数上限（`maxItems` 只在 `PostCreateRequest`
/// 上有 9），故本页复用 [NfrMedia.maxMediaCount] 作上限并在 UI 注明。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../nfr_constants.dart';
import '../publish/media_section.dart';
import 'cert_repository.dart';
import 'cert_type_option.dart';

/// 资质认证提交页。
class QualificationFormScreen extends ConsumerStatefulWidget {
  /// 构造资质提交页。
  ///
  /// 参数：[initialType] 进页默认选中的资质类型（由信任页按行带入，可空）。
  const QualificationFormScreen({super.key, this.initialType});

  /// 默认选中的资质类型。
  final CertTypeOption? initialType;

  @override
  ConsumerState<QualificationFormScreen> createState() => _QualificationFormScreenState();
}

class _QualificationFormScreenState extends ConsumerState<QualificationFormScreen> {
  late CertTypeOption? _type = widget.initialType;

  /// 已上传的证照图 media_id。
  List<String> _mediaIds = const [];

  bool _submitting = false;
  String? _error;

  /// 提交资质。
  ///
  /// 客户端先做两项自检（类型必选、材料至少一张），再调服务端。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _submit() async {
    final type = _type;
    if (type == null) {
      setState(() => _error = '请选择资质类型');
      return;
    }
    if (_mediaIds.isEmpty) {
      setState(() => _error = '请至少上传一张证照图');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final result = await ref.read(certRepositoryProvider).submitQualification(
            certType: type.apiType,
            mediaIds: _mediaIds,
          );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已提交，预计 ${result.slaHours} 小时内出结果')),
      );
      context.pop(true);
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
      ApiErrorCode.qualificationNeeded => '请先完成实名认证（高敏类目要求实名前置）',
      ApiErrorCode.certUnavailable => '认证服务暂时不可用，请稍后重试',
      ApiErrorCode.paramInvalid => '提交信息有误，请检查后重试',
      _ => api.message,
    };
    // 统一回显 request_id（§5.3 UI 报错唯一格式 {message}（{request_id}））
    return api.requestId == null ? text : '$text（${api.requestId}）';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: const Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 18, color: Color(AppColors.textPrimary)),
          onPressed: () => context.pop(),
        ),
        title: const Text(
          '资质认证',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Text(
            '提交后由平台人工审核，审核期间不影响发布普通类目',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          Text(
            '资质类型',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          for (final option in CertTypeOption.values)
            RadioListTile<CertTypeOption>(
              value: option,
              // ignore: deprecated_member_use
              groupValue: _type,
              // ignore: deprecated_member_use
              onChanged: _submitting
                  ? null
                  : (value) => setState(() {
                        _type = value;
                        _error = null;
                      }),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(
                option.label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: const Color(AppColors.textPrimary),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            '证照材料',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '最多 ${NfrMedia.maxMediaCount} 张，需能看清证照编号与有效期',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          MediaSection(
            maxCount: NfrMedia.maxMediaCount,
            onChanged: (ids) => setState(() {
              _mediaIds = ids;
              _error = null;
            }),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _error!,
              style: const TextStyle(color: Color(AppColors.errorText)),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _submitting ? null : _submit,
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
                  : const Text('提交审核'),
            ),
          ),
        ],
      ),
    );
  }
}
