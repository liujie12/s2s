/// 「AI 帮我发」入口与快速输入（PRD §6.13 T6-① + §5.9 模式①/④）。
///
/// **入口位置**：首页右下「AI 帮我发」FAB（Accent 专用色，PRD §1.4.2
/// 「Accent 的唯一用途 = AI 猜角标 + AI 帮我发 FAB」）。点击后弹四模式。
///
/// **本期实现**：
/// - ① 多媒体：拍 1 张图（相机优先）+ 说 1 句话 → 上传图 → 进确认页（带 `media_id`）；
/// - ④ 抢发：填标题 + 拍 1 张图 → 上传图 → 进确认页（`flashMode`，可落 🔴）；
/// - ②③ 呈现但禁用（注明「即将开放」），不做假入口（见 [AiPublishModeX.isAvailable]）。
///
/// **为什么快速输入用 BottomSheet 而非新路由**：它不需要出现在深链/返回栈语义里，
/// 且「弹层 → 选完即进确认页」是同一手势上下文，开新页会多一次返回栈折叠。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../nfr_constants.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import '../media/audio_recorder.dart';
import '../media/media_image_encoder.dart';
import '../media/media_picker.dart';
import '../media/media_upload_service.dart';
import 'ai_confirm_args.dart';
import 'ai_publish_mode.dart';
import 'publish_form_state.dart';

/// 打开「AI 帮我发」入口（首页 FAB 的唯一出口）。
///
/// 流程：弹四模式 → 校验可用性 → 未登录先登录 → 快速输入 → 进确认页。
///
/// 参数：
///   [context] 构建上下文（FAB 所在页）；
///   [ref] 供校验登录态与后续上传。
/// 返回：[Future] 完成信号（已 push 确认页或提前返回）。
Future<void> startAiPublish(BuildContext context, WidgetRef ref) async {
  final mode = await showModalBottomSheet<AiPublishMode>(
    context: context,
    backgroundColor: const Color(AppColors.surface),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (_) => const _AiModeSheet(),
  );
  if (mode == null || !context.mounted) return;

  if (!mode.isAvailable) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('「${mode.label}」即将开放')),
    );
    return;
  }

  if (!ref.read(isLoggedInProvider)) {
    final ok = await GoRouter.of(context).push<bool>(AppRoutes.login);
    if (!context.mounted || ok != true) return;
  }
  if (!context.mounted) return;

  // 模式③ 对话式：直接进引导页（每屏 1 问，无需先选图/输入）。
  if (mode == AiPublishMode.dialog) {
    GoRouter.of(context).push(AppRoutes.aiDialog);
    return;
  }

  final args = await showModalBottomSheet<AiConfirmArgs>(
    context: context,
    isScrollControlled: true,
    backgroundColor: const Color(AppColors.surface),
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    // ② 语音零键盘：录一段音频 → 上传 → 带 voice_media_id 进确认页；
    // ①④ 拍图/抢发：选图 + 文本（或标题）→ 上传 → 进确认页。
    builder: (_) => mode == AiPublishMode.voice
        ? const _AiVoiceSheet()
        : _AiQuickSheet(mode: mode),
  );
  if (args == null || !context.mounted) return;
  GoRouter.of(context).push(AppRoutes.aiConfirm, extra: args);
}

/// 「AI 帮我发」悬浮按钮（PRD §6.13 T6-①）。
///
/// 视觉逐条取自 prototype-figma `fab/ai-publish`：Accent 橙底 + 胶囊形 +
/// 白字「AI 帮我发」+ 投影；**不补矢量图标**（AI 语义已由文案 + Accent 专用色
/// 双通道承载，再加装饰星是第三次重复编码，PRD §1.4.2）。
class AiPublishFab extends StatelessWidget {
  /// 构造按钮。
  ///
  /// 参数：[onTap] 点击回调（由 [startAiPublish] 承载全流程）。
  const AiPublishFab({super.key, required this.onTap});

  /// 点击回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(AppColors.accent),
        borderRadius: BorderRadius.circular(AppRadius.full),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            offset: Offset(0, 4),
            blurRadius: 12,
            spreadRadius: 0,
          ),
        ],
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Text(
            'AI 帮我发',
            style: TextStyle(
              fontSize: AppTypeScale.body.size,
              fontWeight: FontWeight.w600,
              // 白字压 Accent：PRD §1.4.2 已把 Accent 压深至 #B4531A 以满足 4.5:1。
              color: const Color(AppColors.surface),
            ),
          ),
        ),
      ),
    );
  }
}

/// 四模式选择弹层。
class _AiModeSheet extends StatelessWidget {
  const _AiModeSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Text(
              'AI 帮我发',
              style: TextStyle(
                fontSize: AppTypeScale.h3.size,
                fontWeight: FontWeight.w600,
                color: const Color(AppColors.textPrimary),
              ),
            ),
          ),
          for (final mode in AiPublishMode.values)
            _AiModeRow(
              mode: mode,
              onTap: () => Navigator.of(context).pop(mode),
            ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    );
  }
}

/// 单条模式行（可用则主色，不可用则置灰并注明「即将开放」）。
class _AiModeRow extends StatelessWidget {
  const _AiModeRow({required this.mode, required this.onTap});

  final AiPublishMode mode;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final bool enabled = mode.isAvailable;
    final Color titleColor = enabled
        ? const Color(AppColors.textPrimary)
        : const Color(AppColors.textPlaceholder);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              switch (mode) {
                AiPublishMode.media => Icons.add_a_photo_outlined,
                AiPublishMode.voice => Icons.mic_none_outlined,
                AiPublishMode.dialog => Icons.forum_outlined,
                AiPublishMode.flash => Icons.bolt_outlined,
              },
              size: 22,
              color: enabled
                  ? const Color(AppColors.primary)
                  : const Color(AppColors.textPlaceholder),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    mode.label,
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      fontWeight: FontWeight.w600,
                      color: titleColor,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    mode.description,
                    style: TextStyle(
                      fontSize: AppTypeScale.caption.size,
                      color: const Color(AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
            if (enabled)
              const Icon(
                Icons.chevron_right,
                size: 20,
                color: Color(AppColors.textPlaceholder),
              )
            else
              Text(
                '即将开放',
                style: TextStyle(
                  fontSize: AppTypeScale.caption.size,
                  color: const Color(AppColors.textPlaceholder),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 快速输入弹层（模式① 拍图 + 一句话 / 模式④ 标题 + 拍照）。
///
/// 职责：拍 1 张图（相机优先）→ 上传（票据 → OSS 直传 → commit）→ 以
/// [AiConfirmArgs] 形式 pop 出去（导航由 [startAiPublish] 统一做，避免用弹层
/// context push）。照片同时进入 [AiConfirmArgs.form] 的 `mediaIds` 与确认页的
/// 媒体图集展示，不会被丢弃。
class _AiQuickSheet extends ConsumerStatefulWidget {
  const _AiQuickSheet({required this.mode});

  /// 目标模式（仅 media / flash）。
  final AiPublishMode mode;

  @override
  ConsumerState<_AiQuickSheet> createState() => _AiQuickSheetState();
}

class _AiQuickSheetState extends ConsumerState<_AiQuickSheet> {
  /// 已选图片字节（未上传）；null 表示还没选。
  Uint8List? _bytes;

  /// 已选文件的 MIME 与文件名（上传时需要）。
  String? _filename;
  String? _contentType;

  /// 模式④ 的标题输入。
  final TextEditingController _titleCtrl = TextEditingController();

  /// 模式① 的一句话输入。
  final TextEditingController _sentenceCtrl = TextEditingController();

  /// 选图/上传中（防重入）。
  bool _busy = false;

  /// 拍照/归一化中（防重入；与上传态分开，避免按钮文案在拍照时变成「上传中…」）。
  bool _picking = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _sentenceCtrl.dispose();
    super.dispose();
  }

  /// 拍 1 张图（相机优先；相机不可用时降级相册）。
  ///
  /// 拍摄产物先做上传前归一化（烘焙 EXIF 方向 + 长边限幅 + 统一 JPEG）：
  /// 相机竖拍照片常以「横像素 + orientation」存储，直接上传详情页会横躺。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _pick() async {
    if (_busy || _picking) return;
    setState(() => _picking = true);
    try {
      final picked = await _takePhoto();
      if (picked == null || !mounted) return;
      final normalized = await ref.read(mediaNormalizerProvider)(
        CropEncodeInput(bytes: picked.bytes, filename: picked.filename),
      );
      if (!mounted) return;
      setState(() {
        _bytes = normalized.bytes;
        _filename = normalized.filename;
        _contentType = normalized.contentType;
      });
    } on MediaPickException catch (error) {
      _toast(error.userMessage);
    } catch (error) {
      _toast(asApiException(error).uiMessage);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 调系统相机拍一张；相机不可用（权限被拒 / 无摄像头 / 平台异常）时降级相册。
  ///
  /// 返回：[PickedMedia?] 拍摄或选择结果；用户取消返回 null。
  /// 抛出：[MediaPickException] 产物格式不在白名单 / 单文件超限（不降级）。
  Future<PickedMedia?> _takePhoto() async {
    final picker = ref.read(mediaPickerProvider);
    try {
      return await picker.pickFromCamera();
    } on MediaPickException {
      rethrow;
    } catch (_) {
      // 相机打不开时不把用户卡死：明确告知后给相册出口。
      if (mounted) _toast('相机不可用，已改为从相册选');
      final picked = await picker.pickImages(limit: 1);
      return picked.isEmpty ? null : picked.first;
    }
  }

  /// 上传图片并 pop 出 [AiConfirmArgs]。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _submit() async {
    if (_busy) return;
    final bytes = _bytes;
    final filename = _filename;
    final contentType = _contentType;
    if (bytes == null || filename == null || contentType == null) {
      _toast('先拍 1 张图');
      return;
    }
    final bool flash = widget.mode == AiPublishMode.flash;
    final String title = _titleCtrl.text.trim();
    final String sentence = _sentenceCtrl.text.trim();
    if (flash && title.isEmpty) {
      _toast('抢发要有标题');
      return;
    }
    if (!flash && sentence.isEmpty) {
      _toast('说一句，例如「楼下超市卖苹果 5 元」');
      return;
    }

    setState(() => _busy = true);
    try {
      final uploaded = await ref.read(mediaUploadServiceProvider).upload(
        PickedMedia(filename: filename, bytes: bytes, contentType: contentType),
      );
      if (!mounted) return;
      final form = PublishFormState(
        mediaIds: <String>[uploaded.mediaId],
        title: flash ? title : '',
      );
      Navigator.of(context).pop(
        AiConfirmArgs(
          form: form,
          initialText: flash ? null : sentence,
          initialMediaId: uploaded.mediaId,
          // 确认页「媒体图集」要显示这张照片：带访问地址，用户才看得见它没被丢弃。
          initialMediaUrl: uploaded.url,
          flashMode: flash,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(asApiException(error).uiMessage);
      }
    }
  }

  /// 轻量提示。
  ///
  /// 参数：[message] 文案。
  /// 返回：[void]。
  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final bool flash = widget.mode == AiPublishMode.flash;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            flash ? '抢发：先占位，再补全' : '拍张图，说一句',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            flash
                ? '只填标题 + 拍照即可发布，24 小时内补全（未补全会退出推荐池）'
                : '拍 1 张图 + 说 1 句话，AI 自动填好；结果可逐项改',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          if (flash) ...[
            TextField(
              controller: _titleCtrl,
              maxLength: 30,
              decoration: const InputDecoration(
                isDense: true,
                labelText: '标题',
                hintText: '例如：九成新实木餐桌',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
          _ImagePickRow(
            bytes: _bytes,
            busy: _busy || _picking,
            onPick: _pick,
          ),
          const SizedBox(height: AppSpacing.md),
          if (!flash) ...[
            TextField(
              controller: _sentenceCtrl,
              decoration: const InputDecoration(
                isDense: true,
                hintText: '说一句，例如「楼下超市卖苹果 5 元」',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _busy ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(AppColors.primary),
                foregroundColor: Colors.white,
                disabledBackgroundColor: const Color(AppColors.border),
                disabledForegroundColor: const Color(AppColors.textPlaceholder),
                elevation: 0,
                shape: const StadiumBorder(),
              ),
              child: Text(
                _busy ? '上传中…' : (flash ? '拍好了，去发布' : '开始识别'),
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 语音录制弹层（模式② 语音零键盘）。
///
/// 交互：点一下开始 → 说一句话 → 再点停止 → 上传音频 → 以 [AiConfirmArgs]
/// 带 `voiceMediaId` pop 出去（导航由 [startAiPublish] 统一做）。
/// 上限于 [NfrMedia.maxAudioSeconds]（实现护栏，见该常量注释），到点自动停。
class _AiVoiceSheet extends ConsumerStatefulWidget {
  const _AiVoiceSheet();

  @override
  ConsumerState<_AiVoiceSheet> createState() => _AiVoiceSheetState();
}

class _AiVoiceSheetState extends ConsumerState<_AiVoiceSheet> {
  /// 正在录音。
  bool _recording = false;

  /// 上传中（防重入）。
  bool _busy = false;

  /// 已录秒数（计时显示 + 上限自动停）。
  int _seconds = 0;

  /// 秒表。
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  /// 开始录音（先申请麦克风权限）。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _start() async {
    if (_recording || _busy) return;
    final recorder = ref.read(audioRecorderProvider);
    try {
      final granted = await recorder.hasPermission();
      if (!mounted) return;
      if (!granted) {
        _toast('需要麦克风权限才能语音发布，请在系统设置里开启');
        return;
      }
      await recorder.start();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _seconds = 0;
      });
      _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!mounted) return;
        setState(() => _seconds++);
        if (_seconds >= NfrMedia.maxAudioSeconds) {
          _stop();
        }
      });
    } on AudioRecordException catch (error) {
      _toast(error.userMessage);
    } catch (error) {
      _toast(asApiException(error).uiMessage);
    }
  }

  /// 停止录音并上传，成功后 pop 出 [AiConfirmArgs]。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _stop() async {
    if (!_recording) return;
    _ticker?.cancel();
    _ticker = null;
    setState(() => _recording = false);
    final recorder = ref.read(audioRecorderProvider);
    try {
      final clip = await recorder.stop();
      if (!mounted) return;
      if (clip == null) {
        _toast('没录到声音，再试一次');
        return;
      }
      setState(() => _busy = true);
      final uploaded = await ref.read(mediaUploadServiceProvider).upload(
        PickedMedia(
          filename: clip.filename,
          bytes: clip.bytes,
          contentType: clip.contentType,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(
        AiConfirmArgs(
          // 音频只作解析输入，不进帖子的 image media_ids（媒体段只收图片）。
          initialVoiceMediaId: uploaded.mediaId,
        ),
      );
    } on AudioRecordException catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(error.userMessage);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        _toast(asApiException(error).uiMessage);
      }
    }
  }

  /// 放弃录音并关闭弹层。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _cancel() async {
    _ticker?.cancel();
    _ticker = null;
    if (_recording) {
      await ref.read(audioRecorderProvider).cancel();
    }
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  /// 轻量提示。
  ///
  /// 参数：[message] 文案。
  /// 返回：[void]。
  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final remaining = NfrMedia.maxAudioSeconds - _seconds;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '语音说，零键盘',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            _recording
                ? '正在听…说一句话，再点停止（还剩 $remaining 秒）'
                : '点一下开始，说一句话，再点停止；AI 会识别并填好',
            style: TextStyle(
              fontSize: AppTypeScale.caption.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Center(
            child: Column(
              children: [
                _MicButton(
                  recording: _recording,
                  busy: _busy,
                  onTap: _recording ? _stop : _start,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  _recording
                      ? '${_seconds}s · 点击停止'
                      : (_busy ? '上传中…' : '点击开始录音'),
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: const Color(AppColors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextButton(
            onPressed: _busy ? null : _cancel,
            child: Text(
              '取消',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 圆形麦克风按钮（录音中主管色实心，否则白底描边）。
class _MicButton extends StatelessWidget {
  const _MicButton({
    required this.recording,
    required this.busy,
    required this.onTap,
  });

  final bool recording;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: busy ? null : onTap,
      customBorder: const CircleBorder(),
      child: Container(
        width: 96,
        height: 96,
        decoration: BoxDecoration(
          color: recording
              ? const Color(AppColors.primary)
              : const Color(AppColors.surface),
          shape: BoxShape.circle,
          border: Border.all(
            color: recording
                ? const Color(AppColors.primary)
                : const Color(AppColors.border),
            width: 2,
          ),
        ),
        child: busy
            ? const SizedBox(
                width: 36,
                height: 36,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Color(AppColors.primary),
                ),
              )
            : Icon(
                recording ? Icons.stop : Icons.mic_none,
                size: 40,
                color: recording
                    ? const Color(AppColors.surface)
                    : const Color(AppColors.primary),
              ),
      ),
    );
  }
}

/// 图片选择行：未选显示虚线占位按钮，已选显示缩略图 + 「换一张」。
class _ImagePickRow extends StatelessWidget {
  const _ImagePickRow({
    required this.bytes,
    required this.busy,
    required this.onPick,
  });

  final Uint8List? bytes;
  final bool busy;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    final data = bytes;
    return SizedBox(
      height: 96,
      child: data == null
          ? OutlinedButton(
              onPressed: busy ? null : onPick,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(AppColors.border)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.photo_camera_outlined, size: 20, color: Color(AppColors.primary)),
                  SizedBox(width: AppSpacing.sm),
                  Text('拍 1 张图'),
                ],
              ),
            )
          : Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Image.memory(
                    data,
                    width: 96,
                    height: 96,
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                  ),
                ),
                Positioned(
                  right: AppSpacing.xs,
                  top: AppSpacing.xs,
                  child: TextButton(
                    onPressed: busy ? null : onPick,
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(AppColors.surface),
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                    ),
                    child: const Text('重拍'),
                  ),
                ),
              ],
            ),
    );
  }
}
