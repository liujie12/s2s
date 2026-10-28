/// 资质添加 / 编辑表单（契约 `POST /cert/qualification`（批量）、
/// `PATCH /cert/qualification/{id}`、`DELETE /cert/qualification/{id}`、`POST /cert/ocr`）。
///
/// 口径（2026-10-28 产品简化）：
/// - 资质 = **一张证照图 + 一个证书名**，没有证件类型、没有有效期；
/// - 添加态支持**一次录多张证**：每组 = 1 图 + 1 名，点「＋ 继续添加证件」加一组，
///   最后一次「提交」整批保存（同一事务，任一条非法或重名则整批不写）；
/// - 每组首张图自动 OCR 预填该组证书名，可手改；抽取失败不阻断提交。
///
/// **添加与编辑共用本页**：编辑态只有一组，由 [initialQualification] 回填；
/// 只有换图才重新抽取；删除入口只在编辑态底部。
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

/// 单组资质草稿（1 图 + 1 名）。
class _CertDraft {
  /// 构造草稿。
  ///
  /// 参数：[certName] 初始证书名（编辑态回填）；[imageUrl] 编辑态旧图地址。
  _CertDraft({String? certName, this.imageUrl})
      : nameCtrl = TextEditingController(text: certName ?? '');

  /// 证书名输入控制器。
  final TextEditingController nameCtrl;

  /// 编辑态旧证照图地址（添加态为 null）。
  final String? imageUrl;

  /// 已上传的证照图 media_id。
  List<String> mediaIds = const [];

  /// 证名是否来自本次 OCR 且未被改写。
  bool nameFromOcr = false;

  /// 用户是否亲手改过证名（改过即不被抽取结果覆盖）。
  bool nameTouched = false;

  /// 是否已尝试过抽取（决定是否提示「没读出来」）。
  bool ocrAttempted = false;

  /// 是否正在抽取。
  bool ocrLoading = false;

  /// 最近一次送抽取的 media_id（同一张不重复抽取）。
  String? lastOcrMediaId;

  /// 已 trim 的证书名。
  String get name => nameCtrl.text.trim();

  /// 契约证名来源（空名不给来源）。
  String? get nameSource => name.isEmpty
      ? null
      : (nameFromOcr && !nameTouched
          ? CertQualification.nameSourceOcr
          : CertQualification.nameSourceManual);

  /// 释放控制器。
  void dispose() => nameCtrl.dispose();
}

/// 资质添加 / 编辑表单页。
class QualificationFormScreen extends ConsumerStatefulWidget {
  /// 构造表单页。
  ///
  /// 参数：[initialQualification] 编辑态回填记录（非空即编辑态）。
  const QualificationFormScreen({super.key, this.initialQualification});

  /// 编辑态回填记录（null = 添加态）。
  final CertQualification? initialQualification;

  @override
  ConsumerState<QualificationFormScreen> createState() => _QualificationFormScreenState();
}

class _QualificationFormScreenState extends ConsumerState<QualificationFormScreen> {
  late final List<_CertDraft> _drafts = [
    _CertDraft(
      certName: widget.initialQualification?.certName,
      imageUrl: widget.initialQualification?.imageUrl,
    ),
  ];

  bool _submitting = false;
  bool _deleting = false;
  String? _error;

  /// 添加成功后停留在本页的「已添加」态。
  bool _justAdded = false;

  /// 本次进页是否至少添加成功过（返回时据此刷新档案列表）。
  bool _added = false;

  /// 最近一次添加成功的证书名（「已添加」态回显）。
  List<String> _lastAddedNames = const [];

  /// 媒体段重建代数：清空表单时换 key，确保缩略图与上传态一并清掉。
  int _formEpoch = 0;

  /// 是否编辑态。
  bool get _isEditing => widget.initialQualification != null;

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  /// 追加一组空白资质（添加态）。
  ///
  /// 参数：无。
  /// 返回：void。
  void _addDraft() {
    if (_drafts.length >= NfrMedia.maxMediaCount) return;
    setState(() {
      _drafts.add(_CertDraft());
      _error = null;
    });
  }

  /// 移除一组（仅添加态且至少留一组）。
  ///
  /// 参数：[index] 组下标。
  /// 返回：void。
  void _removeDraft(int index) {
    if (_drafts.length <= 1) return;
    setState(() {
      _drafts.removeAt(index).dispose();
      _error = null;
    });
  }

  /// 清空表单（提交成功后继续新增时复用同一页面）。
  ///
  /// 参数：无。
  /// 返回：void（调用方负责 setState）。
  void _resetForm() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    _drafts
      ..clear()
      ..add(_CertDraft());
    _error = null;
    _formEpoch++;
  }

  /// 某组媒体变化：记录 media_id，并对该组首张图做一次抽取。
  ///
  /// 参数：[index] 组下标；[ids] 媒体段上报的已 commit media_id 列表。
  /// 返回：void。
  void _onMediaChanged(int index, List<String> ids) {
    final draft = _drafts[index];
    setState(() {
      draft.mediaIds = ids;
      _error = null;
    });
    if (ids.isEmpty) {
      draft.lastOcrMediaId = null;
      return;
    }
    final first = ids.first;
    if (first == draft.lastOcrMediaId) return;
    draft.lastOcrMediaId = first;
    _runOcr(draft, first);
  }

  /// 调 `POST /cert/ocr` 预填该组证书名。
  ///
  /// 参数：[draft] 目标组；[mediaId] 该组首张证照图 media_id。
  /// 返回：[Future<void>]。
  Future<void> _runOcr(_CertDraft draft, String mediaId) async {
    setState(() {
      draft.ocrLoading = true;
      draft.ocrAttempted = false;
    });
    try {
      final result = await ref.read(certRepositoryProvider).ocrQualification(mediaId: mediaId);
      if (!mounted) return;
      setState(() {
        draft.ocrLoading = false;
        draft.ocrAttempted = true;
        _applyOcr(draft, result);
      });
    } catch (_) {
      // 抽取失败按「没读出来」处理，不报错、不阻断提交。
      if (!mounted) return;
      setState(() {
        draft.ocrLoading = false;
        draft.ocrAttempted = true;
        draft.nameFromOcr = false;
      });
    }
  }

  /// 把抽取结果写入该组输入框（不覆盖用户本次已改过的证名）。
  ///
  /// 参数：[draft] 目标组；[result] 抽取结果。
  /// 返回：void（在 setState 内调用）。
  void _applyOcr(_CertDraft draft, CertOcrResult result) {
    final name = result.certName?.trim() ?? '';
    if (draft.nameTouched) return;
    if (name.isEmpty) {
      draft.nameFromOcr = false;
      return;
    }
    draft.nameCtrl.text = name;
    draft.nameFromOcr = true;
  }

  /// 本次提交里是否出现重名（批内 + 库内，编辑时排除自己）。
  ///
  /// 参数：[name] 已 trim 的证名；[selfIndex] 当前组下标（跳过自己）。
  /// 返回：bool。
  bool _isDuplicateName(String name, int selfIndex) {
    if (name.isEmpty) return false;
    for (var i = 0; i < _drafts.length; i++) {
      if (i != selfIndex && _drafts[i].name == name) return true;
    }
    final cert = ref.read(trustOverviewProvider).value?.cert;
    if (cert == null) return false;
    final selfId = widget.initialQualification?.certId;
    for (final item in cert.qualifications) {
      if (selfId != null && item.certId == selfId) continue;
      if ((item.certName ?? '').trim() == name) return true;
    }
    return false;
  }

  /// 提交（添加态整批 POST，编辑态单条 PATCH）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _submit() async {
    for (final draft in _drafts) {
      if (draft.mediaIds.isEmpty) {
        setState(() => _error = '请至少上传一张证照图');
        return;
      }
    }
    for (var i = 0; i < _drafts.length; i++) {
      final name = _drafts[i].name;
      if (_isDuplicateName(name, i)) {
        setState(() => _error = '「$name」已存在，请换一个名称');
        return;
      }
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      if (_isEditing) {
        final draft = _drafts.first;
        await ref.read(certRepositoryProvider).updateQualification(
              widget.initialQualification!.certId,
              QualificationUpdateRequest(
                mediaIds: draft.mediaIds.isEmpty ? null : draft.mediaIds,
                certName: draft.name,
                nameSource: draft.nameSource,
              ),
            );
      } else {
        await ref.read(certRepositoryProvider).submitQualification(
              items: [
                for (final draft in _drafts)
                  QualificationSubmitItem(
                    mediaIds: draft.mediaIds,
                    certName: draft.name.isEmpty ? null : draft.name,
                    nameSource: draft.nameSource,
                  ),
              ],
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
        _lastAddedNames = [for (final draft in _drafts) draft.name];
        _resetForm();
        _justAdded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _error = _messageOf(error);
      });
    }
  }

  /// 二次确认后删除这张资质（仅编辑态）。
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
          if (_lastAddedNames.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              _lastAddedNames.join('、'),
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

  /// 单组资质的表单片段（证照图 + 证书名 + 继续添加入口）。
  ///
  /// 参数：[index] 组下标；[busy] 是否提交/删除中。
  /// 返回：[Widget]。
  Widget _buildDraftSection(int index, bool busy) {
    final draft = _drafts[index];
    final isLast = index == _drafts.length - 1;
    return Column(
      key: ValueKey('cert-draft-$index-$_formEpoch'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (index > 0) ...[
          const SizedBox(height: AppSpacing.md),
          Divider(height: 1, color: const Color(AppColors.border)),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(child: _SectionLabel('证件 ${index + 1}')),
              if (!_isEditing)
                TextButton(
                  onPressed: busy ? null : () => _removeDraft(index),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: Size.zero),
                  child: Text(
                    '删除这组',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: const Color(AppColors.errorText),
                    ),
                  ),
                ),
            ],
          ),
        ] else
          _SectionLabel('证照照片'),
        if (index > 0) _SectionLabel('证照照片'),
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
        if (_isEditing && (draft.imageUrl ?? '').isNotEmpty) ...[
          const SizedBox(height: AppSpacing.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Image.network(
              draft.imageUrl!,
              width: 96,
              height: 96,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(width: 96, height: 96),
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        MediaSection(
          key: ValueKey('cert-media-$index-$_formEpoch'),
          maxCount: NfrMedia.maxMediaCount,
          simple: true,
          onChanged: (ids) => _onMediaChanged(index, ids),
        ),
        if (draft.ocrLoading)
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
          controller: draft.nameCtrl,
          enabled: !busy,
          maxLength: 64,
          onChanged: (value) => setState(() {
            draft.nameTouched = true;
            _error = null;
          }),
          decoration: const InputDecoration(
            hintText: '例如：养老护理员证',
            counterText: '',
            border: OutlineInputBorder(),
          ),
        ),
        if (draft.ocrAttempted && draft.name.isEmpty && !draft.ocrLoading)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              '没读出来，请手动填写',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textPlaceholder),
              ),
            ),
          ),
        if (isLast && !_isEditing)
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: busy ? null : _addDraft,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                child: Text(
                  '＋ 继续添加证件',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.primary),
                  ),
                ),
              ),
            ),
          ),
      ],
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
                for (var i = 0; i < _drafts.length; i++) _buildDraftSection(i, busy),
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
}

/// 表单小节标题。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

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
