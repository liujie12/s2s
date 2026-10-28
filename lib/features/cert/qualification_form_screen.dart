/// 资质添加 / 编辑表单（契约 `POST /cert/qualification`、`PATCH /cert/qualification/{id}`、
/// `DELETE /cert/qualification/{id}`、`POST /cert/ocr`）。
///
/// 流程（方案 R2–R4、F1/F6）：选类型 → 拍/选证照图并上传 → 自动抽取证名与有效期
/// 预填 → 用户确认或改写 → 提交。抽取失败不是错误：两个字段留空并提示手填，
/// 提交不被阻断。
///
/// **添加与编辑共用本页**（方案 R9/R14）：编辑态由 [initialQualification] 回填，
/// 只有换图才重新抽取；用户本次改过的字段不被新抽取结果覆盖。
/// 删除入口只放在编辑页底部（方案 R10：档案行不给行内删除，减少误触）。
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
import '../auth/auth_repository.dart';
import '../publish/media_section.dart';
import 'cert_models.dart';
import 'cert_name_store.dart';
import 'cert_repository.dart';
import 'cert_type_option.dart';

/// 资质添加 / 编辑表单页。
class QualificationFormScreen extends ConsumerStatefulWidget {
  /// 构造表单页。
  ///
  /// 参数：
  ///   [initialType] 进页默认选中的类型（由档案页「＋ 添加资质」带入，可空）；
  ///   [initialQualification] 编辑态回填记录（非空即编辑态）。
  const QualificationFormScreen({
    super.key,
    this.initialType,
    this.initialQualification,
  });

  /// 默认选中的资质类型。
  final CertTypeOption? initialType;

  /// 编辑态回填记录（null = 添加态）。
  final CertQualification? initialQualification;

  @override
  ConsumerState<QualificationFormScreen> createState() => _QualificationFormScreenState();
}

class _QualificationFormScreenState extends ConsumerState<QualificationFormScreen> {
  late CertTypeOption? _type =
      widget.initialQualification == null
          ? widget.initialType
          : CertTypeOption.fromApi(widget.initialQualification!.certType);

  late final TextEditingController _nameCtrl = TextEditingController(
    text: widget.initialQualification?.certName ?? '',
  );

  /// 进页时的证照图 media_id（编辑态旧图不在媒体段里，故为空）。
  List<String> _mediaIds = const [];

  /// 有效期年月（`permanent` 时忽略）。
  late int? _expireYear = _initialExpire?.year;
  late int? _expireMonth = _initialExpire?.month;

  /// 是否长期有效。
  late bool _permanent = widget.initialQualification?.isPermanent ?? false;

  /// 证名是否来自本次 OCR 且未被用户改写。
  bool _nameFromOcr = false;

  /// 有效期是否来自本次 OCR 且未被用户改写。
  bool _expireFromOcr = false;

  /// 本次会话内用户是否亲手改过证名 / 有效期（R14：不被抽取结果覆盖）。
  bool _nameTouched = false;
  bool _expireTouched = false;

  /// 是否已尝试过抽取（决定是否显示「没读出来，请手动填写」）。
  bool _ocrAttempted = false;
  bool _ocrLoading = false;

  /// 最近一次送抽取的 media_id（同一张不重复抽取）。
  String? _lastOcrMediaId;

  /// 该用户在本类型下用过的自定义证名（本机记忆，仅本人可见）。
  List<String> _rememberedNames = const [];

  /// 是否正在把抽取结果写入输入框（避免被 [TextEditingController] 监听误判为手工改写）。
  bool _applyingOcr = false;

  bool _submitting = false;
  bool _deleting = false;
  String? _error;

  /// 进页时的有效期（编辑态回填）。
  DateTime? get _initialExpire => widget.initialQualification?.expireAt;

  /// 是否编辑态。
  bool get _isEditing => widget.initialQualification != null;

  /// 年份下拉的最小值：当前年、进页回填年、抽取年三者取最早（过期证也能回填）。
  int get _minYear {
    final now = DateTime.now().year;
    final existing = _initialExpire?.year;
    final ocrYear = _expireYear;
    var min = now;
    if (existing != null && existing < min) min = existing;
    if (ocrYear != null && ocrYear < min) min = ocrYear;
    return min;
  }

  @override
  void initState() {
    super.initState();
    // 证名变化影响「已读取 / 手工填写」标注与提交的 name_source，故监听重绘。
    _nameCtrl.addListener(_onNameChanged);
    _loadRememberedNames();
  }

  /// 读取当前用户在当前资质类型下记住的自定义证名。
  ///
  /// 未登录或未选类型时清空（没有可归属的候选来源）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _loadRememberedNames() async {
    final type = _type;
    final userId = ref.read(authSessionProvider)?.userId;
    if (type == null || userId == null) {
      // 初始即空（未选类型/未登录）：无需 setState，首帧本就是空列表。
      _rememberedNames = const [];
      return;
    }
    final names = await ref.read(certNameStoreProvider).read(userId, type.apiType);
    if (!mounted) return;
    setState(() => _rememberedNames = names);
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

  /// 调 `POST /cert/ocr` 预填证名与有效期。
  ///
  /// 抽取失败不改提交能力：两个字段留空，由用户手填（方案 F2）。
  ///
  /// 参数：[mediaId] 首张证照图 media_id。
  /// 返回：[Future<void>]。
  Future<void> _runOcr(String mediaId) async {
    setState(() {
      _ocrLoading = true;
      _ocrAttempted = false;
    });
    try {
      final result = await ref.read(certRepositoryProvider).extractCertProfile(mediaId: mediaId);
      if (!mounted) return;
      setState(() {
        _ocrLoading = false;
        _ocrAttempted = true;
        _applyOcr(result);
      });
    } catch (_) {
      // F7：抽取失败按「没读出来」处理，不报错、不阻断提交。
      if (!mounted) return;
      setState(() {
        _ocrLoading = false;
        _ocrAttempted = true;
        _nameFromOcr = false;
        _expireFromOcr = false;
      });
    }
  }

  /// 把抽取结果写入表单（不覆盖用户本次已改过的字段）。
  ///
  /// 参数：[result] 抽取结果。
  /// 返回：void（在 setState 内调用）。
  void _applyOcr(CertOcrResult result) {
    final name = result.certName?.trim() ?? '';
    if (!_nameTouched) {
      if (name.isNotEmpty) {
        _applyingOcr = true;
        _nameCtrl.text = name;
        _applyingOcr = false;
        _nameFromOcr = true;
      } else {
        _nameFromOcr = false;
      }
    }
    final at = result.expireAt;
    if (!_expireTouched) {
      if (at != null) {
        final ym = yearMonthOf(at);
        _expireYear = ym.year;
        _expireMonth = ym.month;
        _permanent = false;
        _expireFromOcr = true;
      } else {
        _expireFromOcr = false;
      }
    }
  }

  /// 认证类型的候选证名（内置候选 + 本人历史自定义名，去重保序）。
  ///
  /// 参数：无。
  /// 返回：[List<String>]；未选类型时为空。
  List<String> get _nameCandidates {
    final type = _type;
    if (type == null) return const [];
    final seen = <String>{};
    return [
      for (final name in [...type.suggestedNames, ..._rememberedNames])
        if (seen.add(name)) name,
    ];
  }

  /// 点选候选证名：填入输入框并按「手工确认」提交来源。
  ///
  /// 参数：[name] 候选名称。
  /// 返回：void。
  void _pickName(String name) {
    _applyingOcr = true;
    _nameCtrl.text = name;
    _applyingOcr = false;
    setState(() {
      _nameTouched = true;
      _nameFromOcr = false;
      _error = null;
    });
  }

  /// 提交（添加走 POST，编辑走 PATCH）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _submit() async {
    final type = _type;
    if (type == null) {
      setState(() => _error = '请选择资质类型');
      return;
    }
    if (!_isEditing && _mediaIds.isEmpty) {
      setState(() => _error = '请至少上传一张证照图');
      return;
    }
    final expireType = _permanent
        ? CertQualification.expireTypePermanent
        : CertQualification.expireTypeDated;
    if (!_permanent && (_expireYear == null || _expireMonth == null)) {
      setState(() => _error = '请选择有效期至（或勾选长期有效）');
      return;
    }
    final expireAt = _permanent
        ? null
        : expireAtWireFromYearMonth(_expireYear!, _expireMonth!);
    final name = _nameCtrl.text.trim();
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
                expireType: expireType,
                expireAt: expireAt,
              ),
            );
      } else {
        await ref.read(certRepositoryProvider).submitQualification(
              certType: type.apiType,
              mediaIds: _mediaIds,
              certName: name.isEmpty ? null : name,
              nameSource: nameSource,
              expireType: expireType,
              expireAt: expireAt,
            );
      }
      if (!mounted) return;
      // 记住用户自定义的证名（内置候选不重复存；仅本机、仅本人）。
      final userId = ref.read(authSessionProvider)?.userId;
      if (userId != null && name.isNotEmpty) {
        await ref.read(certNameStoreProvider).remember(
              userId,
              type.apiType,
              name,
              exclude: type.suggestedNames,
            );
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_isEditing ? '已更新，新的有效期立即生效' : '已添加，发布时可以选择这张证')),
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

  /// 二次确认后删除这张资质。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除这张资质？'),
        content: const Text('删除后，用过它的信息会显示「该资质已不再有效」。这个操作不能撤销。'),
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
          onPressed: () => context.pop(),
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
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Text(
            '资质由你自行提供，平台未做核验；不添加也不影响发布其他内容',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.xl),
          _SectionLabel('证件类型'),
          const SizedBox(height: AppSpacing.sm),
          if (_isEditing)
            Text(
              _type?.label ?? widget.initialQualification!.certType,
              style: TextStyle(fontSize: AppTypeScale.body.size, color: const Color(AppColors.textPrimary)),
            )
          else
            for (final option in CertTypeOption.values)
              RadioListTile<CertTypeOption>(
                value: option,
                // ignore: deprecated_member_use
                groupValue: _type,
                // ignore: deprecated_member_use
                onChanged: busy
                    ? null
                    : (value) {
                        setState(() {
                          _type = value;
                          _error = null;
                        });
                        // 候选证名随类型切换（内置候选 + 本人该类型的历史自定义名）。
                        _loadRememberedNames();
                      },
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
          _SectionLabel('证照照片'),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _isEditing
                ? '换图会重新读取证名与有效期；不换图可跳过'
                : '最多 ${NfrMedia.maxMediaCount} 张，首张用于自动识别证名与有效期',
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
            maxCount: NfrMedia.maxMediaCount,
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
          if (_nameCandidates.isNotEmpty) ...[
            Text(
              '选一个常用名称，或直接输入新的',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final candidate in _nameCandidates)
                  ChoiceChip(
                    label: Text(candidate),
                    selected: _nameCtrl.text.trim() == candidate,
                    onSelected: busy ? null : (_) => _pickName(candidate),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
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
          const SizedBox(height: AppSpacing.lg),
          _SectionLabel('有效期至'),
          const SizedBox(height: AppSpacing.xs),
          if (!_permanent)
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    // ignore: deprecated_member_use
                    value: _expireYear,
                    decoration: const InputDecoration(
                      labelText: '年',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (var y = _minYear; y <= DateTime.now().year + 20; y++)
                        DropdownMenuItem(value: y, child: Text('$y')),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                              _expireYear = value;
                              _expireTouched = true;
                              _error = null;
                            }),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    // ignore: deprecated_member_use
                    value: _expireMonth,
                    decoration: const InputDecoration(
                      labelText: '月',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      for (var m = 1; m <= 12; m++)
                        DropdownMenuItem(
                          value: m,
                          child: Text(m.toString().padLeft(2, '0')),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) => setState(() {
                              _expireMonth = value;
                              _expireTouched = true;
                              _error = null;
                            }),
                  ),
                ),
              ],
            ),
          Row(
            children: [
              Switch(
                value: _permanent,
                onChanged: busy
                    ? null
                    : (value) => setState(() {
                          _permanent = value;
                          _expireTouched = true;
                          _error = null;
                        }),
              ),
              Text(
                '长期有效',
                style: TextStyle(fontSize: AppTypeScale.body.size, color: const Color(AppColors.textPrimary)),
              ),
            ],
          ),
          if (_expireHelper != null)
            Text(
              _expireHelper!,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
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

  /// 证书名称下方的来源标注（方案文案表逐字）。
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

  /// 有效期下方的来源标注。
  ///
  /// 参数：无。
  /// 返回：[String?]；无标注时为 null。
  String? get _expireHelper {
    if (_permanent) return null;
    if (_expireFromOcr && !_expireTouched) return '已从照片读取，可修改';
    if (_ocrAttempted && !_expireFromOcr) return '没读出来，请手动填写';
    return null;
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
