/// 资质添加 / 编辑表单（契约 `POST /cert/qualification`、`PATCH /cert/qualification/{id}`、
/// `DELETE /cert/qualification/{id}`、`POST /cert/ocr`）。
///
/// 口径（2026-10-28 产品简化）：资质 = **名称 + 图片**，没有证件类型、没有有效期。
/// 流程：拍/选证照图并上传 → 首张自动抽取证名预填 → 用户确认或改写 → 提交。
/// 抽取失败不是错误：证名留空并提示手填，提交不被阻断。
///
/// **添加与编辑共用本页**：编辑态由 [initialQualification] 回填，只有换图才
/// 重新抽取；用户本次改过的证名不被新抽取结果覆盖。
/// 删除入口只放在编辑页底部（档案行不给行内删除，减少误触）。
///
/// **如实登记**：`QualificationItem` 只回 `image_url`、不回 `media_id`，故编辑态
/// 无法把旧图灌进媒体段；旧图单独展示，媒体段只承担「重新上传」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../nfr_constants.dart';
import '../publish/media_section.dart';
import 'cert_models.dart';
import 'cert_provider.dart';
import 'cert_repository.dart';

/// 资质添加 / 编辑表单页。
class QualificationFormScreen extends ConsumerStatefulWidget {
  /// 构造表单页。
  ///
  /// 参数：[initialQualification] 编辑态回填记录（非空即编辑态）。
  const QualificationFormScreen({
    super.key,
    this.initialQualification,
  });

  /// 编辑态回填记录（null = 添加态）。
  final CertQualification? initialQualification;

  @override
  ConsumerState<QualificationFormScreen> createState() => _QualificationFormScreenState();
}

class _QualificationFormScreenState extends ConsumerState<QualificationFormScreen> {
  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.initialQualification?.certName ?? '',
  );

  /// 进页时的证照图 media_id（编辑态旧图不在媒体段里，故为空）。
  List<String> _mediaIds = const [];

  /// 证名是否来自本次 OCR 且未被用户改写。
  bool _nameFromOcr = false;

  /// 本次会话内用户是否亲手改过证名（不被抽取结果覆盖）。
  bool _nameTouched = false;

  /// 是否已尝试过抽取（决定是否显示「没读出来，请手动填写」）。
  bool _ocrAttempted = false;
  bool _ocrLoading = false;

  /// 最近一次送抽取的 media_id（同一张不重复抽取）。
  String? _lastOcrMediaId;

  /// 是否正在把抽取结果写入输入框（避免被 [TextEditingController] 监听误判为手工改写）。
  bool _applyingOcr = false;

  bool _submitting = false;
  bool _deleting = false;
  String? _error;

  /// 添加成功后停留在本页的「已添加」态（可继续新增下一张）。
  bool _justAdded = false;

  /// 本次进页是否至少添加成功过一张（返回时据此让档案列表刷新）。
  bool _added = false;

  /// 最近一次添加成功的证书名（「已添加」态回显）。
  String? _lastAddedName;

  /// 媒体段重建代数：清空表单时换 key，确保缩略图与内部上传态一并清掉。
  int _formEpoch = 0;

  /// 清空表单（添加成功后再新增一张时复用同一页面）。
  ///
  /// 参数：无。
  /// 返回：void（调用方负责 setState）。
  void _resetForm() {
    _mediaIds = const [];
    _lastOcrMediaId = null;
    _nameFromOcr = false;
    _nameTouched = false;
    _ocrAttempted = false;
    _ocrLoading = false;
    _applyingOcr = true;
    _nameCtrl.clear();
    _applyingOcr = false;
    _error = null;
    _formEpoch++;
  }

  /// 是否编辑态。
  bool get _isEditing => widget.initialQualification != null;

  @override
  void initState() {
    super.initState();
    // 证名变化影响「已读取 / 手工填写」标注与提交的 name_source，故监听重绘。
    _nameCtrl.addListener(_onNameChanged);
  }

  @override
  void dispose() {
    _nameCtrl.removeListener(_onNameChanged);
    _nameCtrl.dispose();
    super.dispose();
  }

  /// 证名输入变化：标记为手工填写并重绘标注。
  ///
  /// 参数：无。
  /// 返回：void。
  void _onNameChanged() {
    if (!mounted || _applyingOcr) return;
    setState(() => _nameTouched = true);
  }

  /// 媒体列表变化：记录已 commit 的 media_id，并对首张图做一次抽取。
  ///
  /// 参数：[ids] 媒体段上报的已 commit media_id 列表。
  /// 返回：void。
  void _onMediaChanged(List<String> ids) {
    setState(() {
      _mediaIds = ids;
      _error = null;
    });
    if (ids.isEmpty) {
      // 清空后允许重传同一张图再次触发抽取。
      _lastOcrMediaId = null;
      return;
    }
    final first = ids.first;
    if (first == _lastOcrMediaId) return;
    _lastOcrMediaId = first;
    _runOcr(first);
  }

  /// 调 `POST /cert/ocr` 预填证书名称。
  ///
  /// 抽取失败不改提交能力：证名留空，由用户手填。
  ///
  /// 参数：[mediaId] 首张证照图 media_id。
  /// 返回：[Future<void>]。
  Future<void> _runOcr(String mediaId) async {
    setState(() {
      _ocrLoading = true;
      _ocrAttempted = false;
    });
    try {
      final result = await ref.read(certRepositoryProvider).ocrQualification(mediaId: mediaId);
      if (!mounted) return;
      setState(() {
        _ocrLoading = false;
        _ocrAttempted = true;
        _applyOcr(result);
      });
    } catch (_) {
      // 抽取失败按「没读出来」处理，不报错、不阻断提交。
      if (!mounted) return;
      setState(() {
        _ocrLoading = false;
        _ocrAttempted = true;
        _nameFromOcr = false;
      });
    }
  }

  /// 把抽取结果写入表单（不覆盖用户本次已改过的证名）。
  ///
  /// 参数：[result] 抽取结果。
  /// 返回：void（在 setState 内调用）。
  void _applyOcr(CertOcrResult result) {
    final name = result.certName?.trim() ?? '';
    if (_nameTouched) return;
    if (name.isEmpty) {
      _nameFromOcr = false;
      return;
    }
    _applyingOcr = true;
    _nameCtrl.text = name;
    _applyingOcr = false;
    _nameFromOcr = true;
  }

  /// 该用户是否已有同名资质（同用户证书名不可重复）。
  ///
  /// 客户端只做前置提示，最终以服务端唯一约束为准。
  ///
  /// 参数：[name] 已 trim 的证书名。
  /// 返回：bool；编辑态会排除自己。
  bool _isDuplicateName(String name) {
    if (name.isEmpty) return false;
    final cert = ref.read(trustOverviewProvider).value?.cert;
    if (cert == null) return false;
    final selfId = widget.initialQualification?.certId;
    for (final item in cert.qualifications) {
      if (selfId != null && item.certId == selfId) continue;
      if ((item.certName ?? '').trim() == name) return true;
    }
    return false;
  }

  /// 提交（添加走 POST，编辑走 PATCH）。
  ///
  /// 参数：[continueAfterSave] 添加成功后是否留在表单继续添加下一张。
  /// 返回：[Future<void>]。
  Future<void> _submit({bool continueAfterSave = false}) async {
    if (!_isEditing && _mediaIds.isEmpty) {
      setState(() => _error = '请至少上传一张证照图');
      return;
    }
    final name = _nameCtrl.text.trim();
    if (_isDuplicateName(name)) {
      setState(() => _error = '该证书名称已存在，请换一个名称');
      return;
    }
    // name_source 由客户端显式回传（契约：服务端不二次猜测）：用户改过即 manual。
    final nameSource = name.isEmpty
        ? null
        : (_nameFromOcr && !_nameTouched
            ? CertQualification.nameSourceOcr
            : CertQualification.nameSourceManual);

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (_isEditing) {
        await ref.read(certRepositoryProvider).updateQualification(
              widget.initialQualification!.certId,
              QualificationUpdateRequest(
                mediaIds: _mediaIds.isEmpty ? null : _mediaIds,
                certName: name,
                nameSource: nameSource,
              ),
            );
      } else {
        await ref.read(certRepositoryProvider).submitQualification(
              mediaIds: _mediaIds,
              certName: name.isEmpty ? null : name,
              nameSource: nameSource,
            );
      }
      if (!mounted) return;
      if (_isEditing) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已更新')),
        );
        context.pop(true);
        return;
      }
      // 添加成功：留在本页，可「继续新增资质」，不必返回档案页再进一次。
      setState(() {
        _added = true;
        _submitting = false;
        _lastAddedName = name;
        _resetForm();
        _justAdded = !continueAfterSave;
      });
      if (continueAfterSave) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已添加，可继续添加下一张')),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _messageOf(error);
      });
    }
  }

  /// 二次确认后删除这张资质。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这张资质？'),
        content: const Text('删除后，已发布的帖子不再展示这张证。这个操作不能撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _deleting = true;
      _error = null;
    });
    try {
      await ref
          .read(certRepositoryProvider)
          .deleteQualification(widget.initialQualification!.certId);
      if (!mounted) return;
      context.pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _deleting = false;
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

  /// 「已添加」态：可继续新增下一张资质，或完成后返回档案页。
  ///
  /// 参数：无。
  /// 返回：[Widget]。
  Widget _buildAddedPanel() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: AppSpacing.xl),
          Icon(Icons.check_circle, size: 48, color: const Color(AppColors.success)),
          const SizedBox(height: AppSpacing.md),
          Text(
            '已添加',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          if ((_lastAddedName ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _lastAddedName!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: () => setState(() {
                _justAdded = false;
                _resetForm();
              }),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppColors.primary),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: const StadiumBorder(),
              ),
              child: const Text('继续新增资质'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextButton(
            onPressed: () => context.pop(_added),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final busy = _submitting || _deleting;
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
          onPressed: () => context.pop(_added),
        ),
        title: Text(
          _isEditing ? '编辑资质' : '添加资质',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: _justAdded
          ? _buildAddedPanel()
          : ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _SectionLabel('证照照片'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _isEditing
                ? '换图会重新读取证书名称；不换图可跳过'
                : '最多 ${NfrMedia.maxMediaCount} 张，首张用于自动识别证书名称',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          if (_isEditing && (widget.initialQualification!.imageUrl ?? '').isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Image.network(
                widget.initialQualification!.imageUrl!,
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const SizedBox(width: 96, height: 96),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          MediaSection(
            key: ValueKey('cert-media-$_formEpoch'),
            maxCount: NfrMedia.maxMediaCount,
            simple: true,
            onChanged: _onMediaChanged,
          ),
          if (_ocrLoading)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sm),
              child: Row(
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '正在读取照片…',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          _SectionLabel('证书名称'),
          const SizedBox(height: AppSpacing.xs),
          TextField(
            controller: _nameCtrl,
            enabled: !busy,
            maxLength: 64,
            decoration: InputDecoration(
              hintText: '例如：养老护理员证',
              counterText: '',
              border: const OutlineInputBorder(),
              helperText: _nameHelper,
              helperStyle: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(_error!, style: const TextStyle(color: Color(AppColors.errorText))),
          ],
          const SizedBox(height: AppSpacing.xl),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: busy ? null : _submit,
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
                  : const Text('提交'),
            ),
          ),
          if (!_isEditing) ...[
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              height: 48,
              child: OutlinedButton(
                onPressed: busy ? null : () => _submit(continueAfterSave: true),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(AppColors.primary),
                  side: const BorderSide(color: Color(AppColors.primary)),
                  shape: const StadiumBorder(),
                ),
                child: const Text('继续添加证件'),
              ),
            ),
          ],
          if (_isEditing) ...[
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: busy ? null : _delete,
              style: TextButton.styleFrom(
                foregroundColor: const Color(AppColors.errorText),
              ),
              child: const Text('删除这张资质'),
            ),
          ],
        ],
      ),
    );
  }

  /// 证书名称下方的来源标注。
  ///
  /// 参数：无。
  /// 返回：[String?]；无标注时为 null。
  String? get _nameHelper {
    if (_nameCtrl.text.trim().isEmpty) {
      return _ocrAttempted ? '没读出来，请手动填写' : null;
    }
    if (_nameFromOcr && !_nameTouched) return '已从照片读取，可修改';
    return '手工填写';
  }
}

/// 表单分组标题。
class _SectionLabel extends StatelessWidget {
  /// 构造分组标题。
  ///
  /// 参数：[text] 标题文案。
  const _SectionLabel(this.text);

  /// 标题文案。
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: AppTypeScale.h3.size,
        fontWeight: FontWeight.w600,
        color: const Color(AppColors.textPrimary),
      ),
    );
  }
}
