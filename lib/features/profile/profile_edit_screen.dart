/// 编辑资料页（PRD §3.4.2 `profile-edit-screen`，2026-11-02）。
///
/// 入口：个人中心头部卡整体点击（头像右下角相机角标提示）。本期只编辑
/// **昵称 + 头像**；默认范围仍在设置页修改，避免同一字段出现两个入口。
///
/// 数据链路：头像走既有媒体直传（选图 → 归一化 → ticket/PUT/commit），
/// 保存时 `PATCH /users/me` 局部提交；成功后由 [MyProfileNotifier.updateProfile]
/// 直接覆盖内存态，返回个人中心即显示新资料。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../../nfr_constants.dart';
import '../auth/auth_repository.dart';
import '../media/media_image_encoder.dart';
import '../media/media_picker.dart';
import '../media/media_upload_service.dart';
import 'profile_dto.dart';
import 'profile_provider.dart';

/// 编辑资料页。
class ProfileEditScreen extends ConsumerWidget {
  /// 构造编辑资料页。
  const ProfileEditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final loggedIn = ref.watch(isLoggedInProvider);
    final profileAsync = ref.watch(myProfileProvider);
    // 未登录（深链/登出后返回）：不进入无限 loading，直接给登录提示。
    if (!loggedIn) {
      return Scaffold(
        backgroundColor: Color(AppColors.background),
        appBar: AppBar(
          toolbarHeight: 48,
          backgroundColor: Color(AppColors.surface),
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          leading: IconButton(
            icon: Icon(Icons.arrow_back_ios_new,
                size: 18, color: Color(AppColors.textPrimary)),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(
            '编辑资料',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.textPrimary),
            ),
          ),
        ),
        body: Center(
          child: Text(
            '登录后可编辑资料',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new,
              size: 18, color: Color(AppColors.textPrimary)),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '编辑资料',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ListErrorView(
          error: asApiException(error),
          onRetry: () => ref.read(myProfileProvider.notifier).refresh(),
        ),
        data: (profile) => _EditForm(profile: profile),
      ),
    );
  }
}

/// 编辑表单（昵称 + 头像 + 保存）。
class _EditForm extends ConsumerStatefulWidget {
  /// 构造编辑表单。
  ///
  /// 参数：[profile] 当前本人资料（用于回填与判断是否有变更）。
  const _EditForm({required this.profile});

  /// 当前本人资料。
  final MyProfileDto profile;

  @override
  ConsumerState<_EditForm> createState() => _EditFormState();
}

class _EditFormState extends ConsumerState<_EditForm> {
  /// 昵称输入控制器。
  late final TextEditingController _nicknameController;

  /// 本次新上传、尚未保存的头像。
  UploadedMedia? _pendingAvatar;

  /// 是否正在上传头像（防重入 + 显示进度）。
  bool _uploading = false;

  /// 是否正在保存（防重复提交）。
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.profile.nickname);
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  /// 当前展示的头像 URL：优先本次新上传，其次已保存头像。
  ///
  /// 参数：无。
  /// 返回：String? 头像 URL；未设置时为 null。
  String? get _avatarUrl => _pendingAvatar?.url ?? widget.profile.avatarUrl;

  /// 是否存在待保存的变更。
  ///
  /// 参数：无。
  /// 返回：bool。
  bool get _hasChanges =>
      _nicknameController.text.trim() != widget.profile.nickname ||
      _pendingAvatar != null;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const SizedBox(height: AppSpacing.lg),
              _buildAvatarSection(),
              const SizedBox(height: AppSpacing.xl),
              _buildNicknameField(),
            ],
          ),
        ),
        _buildSaveBar(),
      ],
    );
  }

  /// 头像编辑区（圆形头像 + 相机角标 + 上传进度）。
  ///
  /// 参数：无。
  /// 返回：Widget。
  Widget _buildAvatarSection() {
    return Center(
      child: Column(
        children: [
          GestureDetector(
            onTap: _uploading ? null : _chooseAvatarSource,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 88,
                  height: 88,
                  decoration: BoxDecoration(
                    color: Color(AppColors.primaryLight),
                    shape: BoxShape.circle,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _avatarUrl == null
                      ? Icon(Icons.person,
                          size: 44, color: Color(AppColors.primary))
                      : Image.network(
                          _avatarUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stack) => Icon(
                            Icons.person,
                            size: 44,
                            color: Color(AppColors.primary),
                          ),
                        ),
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Color(AppColors.primary),
                      shape: BoxShape.circle,
                      border: Border.all(color: Color(AppColors.surface), width: 2),
                    ),
                    child: const Icon(Icons.photo_camera,
                        size: 14, color: Colors.white),
                  ),
                ),
                if (_uploading)
                  Positioned.fill(
                    child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.black38,
                        shape: BoxShape.circle,
                      ),
                      child: const Center(
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _uploading ? '上传中…' : '点击更换头像',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  /// 昵称输入区（1–20 字符，实时字数）。
  ///
  /// 参数：无。
  /// 返回：Widget。
  Widget _buildNicknameField() {
    return Container(
      color: Color(AppColors.surface),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '昵称',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          TextField(
            controller: _nicknameController,
            maxLength: NfrProfile.nicknameMaxLength,
            textInputAction: TextInputAction.done,
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: Color(AppColors.textPrimary),
            ),
            decoration: InputDecoration(
              hintText: '请输入昵称',
              hintStyle: TextStyle(color: Color(AppColors.textPlaceholder)),
              counterStyle: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textSecondary),
              ),
              border: InputBorder.none,
              isDense: true,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
    );
  }

  /// 底部保存按钮（无变更时禁用，保存中显示进度）。
  ///
  /// 参数：无。
  /// 返回：Widget。
  Widget _buildSaveBar() {
    final enabled = _hasChanges && !_saving && !_uploading;
    return SafeArea(
      top: false,
      child: Container(
        color: Color(AppColors.surface),
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: enabled ? _save : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(AppColors.primary),
              disabledBackgroundColor: Color(AppColors.border),
              foregroundColor: Colors.white,
              elevation: 0,
              minimumSize: const Size(0, 48),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
            child: _saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Text(
                    '保存',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
          ),
        ),
      ),
    );
  }

  /// 选择头像来源（拍照 / 相册）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _chooseAvatarSource() async {
    final fromCamera = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.of(sheetContext).pop(false),
            ),
          ],
        ),
      ),
    );
    if (fromCamera == null) return;
    await _pickAndUpload(fromCamera: fromCamera);
  }

  /// 选图并上传头像（选图、归一化、直传三步分别兜底）。
  ///
  /// 参数：[fromCamera] true＝系统相机，false＝相册。
  /// 返回：[Future<void>]。
  Future<void> _pickAndUpload({required bool fromCamera}) async {
    if (_uploading) return;

    final PickedMedia? picked;
    try {
      if (fromCamera) {
        picked = await ref.read(mediaPickerProvider).pickFromCamera();
      } else {
        final list = await ref.read(mediaPickerProvider).pickImages(limit: 1);
        picked = list.isEmpty ? null : list.first;
      }
    } on MediaPickException catch (error) {
      _toast(error.userMessage);
      return;
    } catch (_) {
      _toast('无法打开相机，请从相册选择');
      return;
    }
    if (picked == null) return; // 用户取消

    setState(() => _uploading = true);
    try {
      // 归一化：烘焙 EXIF 方向 + 限制长边 + 统一 JPEG（与发布链路同一入口）。
      final normalized = await ref.read(mediaNormalizerProvider)(
        CropEncodeInput(bytes: picked.bytes, filename: picked.filename),
      );
      final uploaded = await ref.read(mediaUploadServiceProvider).upload(normalized);
      if (!mounted) return;
      setState(() => _pendingAvatar = uploaded);
    } on MediaPickException catch (error) {
      _toast(error.userMessage);
    } on ApiException catch (error) {
      _toast(error.uiMessage);
    } catch (_) {
      _toast('头像上传失败，请重试');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 保存昵称与头像（`PATCH /users/me` 局部提交）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _save() async {
    if (_saving) return;
    final nickname = _nicknameController.text.trim();
    if (nickname.length < NfrProfile.nicknameMinLength) {
      _toast('昵称不能为空');
      return;
    }
    if (nickname.length > NfrProfile.nicknameMaxLength) {
      _toast('昵称不能超过 ${NfrProfile.nicknameMaxLength} 个字符');
      return;
    }

    final nicknameChanged = nickname != widget.profile.nickname;
    if (!nicknameChanged && _pendingAvatar == null) {
      Navigator.of(context).pop();
      return;
    }

    setState(() => _saving = true);
    try {
      await ref.read(myProfileProvider.notifier).updateProfile(
            nickname: nicknameChanged ? nickname : null,
            avatarMediaId: _pendingAvatar?.mediaId,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      _toast(_saveErrorMessage(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 保存失败的用户文案：头像与昵称给专用提示，其余沿用服务端文案。
  ///
  /// 参数：[error] 归一后的 API 异常。
  /// 返回：String 用户可见文案。
  String _saveErrorMessage(ApiException error) {
    if (error.code == ApiErrorCode.imageRejected) {
      return '该头像未通过审核，请更换';
    }
    return error.uiMessage;
  }

  /// 轻提示。
  ///
  /// 参数：[message] 用户可见文案。
  /// 返回：void。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}
