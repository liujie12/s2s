/// 语音搜索面板（地图语音语义搜索 U6，方案 R1/R2/R3/R15）。
///
/// 交互：按住说话 → 松开后转写并解析。**面板内不设打字框**（2026-10-28 用户裁定：
/// 搜索栏已是文字入口，面板里再放一份是重复入口，还会让「这是语音面板」变得含糊；
/// 文字搜索一律走搜索栏）。
/// 音频去向（KTD7/KTD9）：
/// - 登录用户：上传得 `voice_media_id`，服务端签名后 ASR，转写成功即删除；
/// - 游客：base64 随请求直传，不落 OSS、不建媒体记录、转写即弃。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../design_tokens.dart';
import '../auth/auth_repository.dart';
import '../discovery/effective_filter_provider.dart';
import '../discovery/search_conditions.dart';
import '../media/audio_recorder.dart';
import '../media/media_picker.dart';
import '../media/media_upload_service.dart';

/// 弹出语音搜索面板。
///
/// 参数：
/// - [context] 构建上下文；
/// - [anchorLat]/[anchorLng] 长按/当前视野中心作为地点锚点。
/// 返回：[Future] 面板关闭信号（解析成功或取消）。
Future<void> showVoiceSearchSheet(
  BuildContext context, {
  required double anchorLat,
  required double anchorLng,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => VoiceSearchSheet(anchorLat: anchorLat, anchorLng: anchorLng),
  );
}

/// 语音搜索面板。
class VoiceSearchSheet extends ConsumerStatefulWidget {
  /// 构造语音搜索面板。
  ///
  /// 参数：[anchorLat]/[anchorLng] 地点锚点（当前视野中心）。
  const VoiceSearchSheet({
    super.key,
    required this.anchorLat,
    required this.anchorLng,
  });

  /// 地点锚点纬度。
  final double anchorLat;

  /// 地点锚点经度。
  final double anchorLng;

  @override
  ConsumerState<VoiceSearchSheet> createState() => _VoiceSearchSheetState();
}

class _VoiceSearchSheetState extends ConsumerState<VoiceSearchSheet> {
  bool _recording = false;
  bool _busy = false;
  bool _permissionDenied = false;
  String? _hint;

  /// 开始录音（先查权限；被拒给跳系统设置指引）。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _start() async {
    if (_recording || _busy) return;
    final recorder = ref.read(audioRecorderProvider);
    final granted = await recorder.hasPermission();
    if (!mounted) return;
    if (!granted) {
      setState(() {
        _permissionDenied = true;
        _hint = '需要麦克风权限才能语音搜索';
      });
      return;
    }
    try {
      await recorder.start();
      if (!mounted) return;
      setState(() {
        _recording = true;
        _permissionDenied = false;
        _hint = '正在听…松开结束';
      });
    } on AudioRecordException catch (error) {
      if (mounted) setState(() => _hint = error.userMessage);
    }
  }

  /// 停止录音并提交解析。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> _stop() async {
    if (!_recording) return;
    final recorder = ref.read(audioRecorderProvider);
    setState(() {
      _recording = false;
      _busy = true;
      _hint = '正在识别…';
    });
    try {
      final clip = await recorder.stop();
      if (clip == null) {
        setState(() {
          _busy = false;
          _hint = '没录到声音，再试一次';
        });
        return;
      }
      await _submitVoice(clip);
    } on AudioRecordException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _hint = error.userMessage;
        });
      }
    }
  }

  /// 按登录态选择音频通道并触发解析。
  ///
  /// 参数：[clip] 录音产物。
  /// 返回：[Future] 完成信号。
  Future<void> _submitVoice(RecordedClip clip) async {
    final loggedIn = ref.read(isLoggedInProvider);
    String? mediaId;
    String? base64Audio;
    if (loggedIn) {
      final uploaded = await ref.read(mediaUploadServiceProvider).upload(
        PickedMedia(
          filename: clip.filename,
          bytes: clip.bytes,
          contentType: clip.contentType,
        ),
      );
      mediaId = uploaded.mediaId;
    } else {
      base64Audio = base64Encode(clip.bytes);
    }
    await _resolve(
      voiceMediaId: mediaId,
      voiceBase64: base64Audio,
      voiceContentType: clip.contentType,
    );
  }

  /// 调解析并处理结果（成功即关闭面板）。
  ///
  /// 参数：见 [SearchIntentNotifier.resolve]。
  /// 返回：[Future] 完成信号。
  Future<void> _resolve({
    String? text,
    String? voiceMediaId,
    String? voiceBase64,
    String? voiceContentType,
  }) async {
    // 经条件门面提交：它负责交互标识与文本回显，语音链不再自建一份入口。
    await ref.read(searchConditionsProvider.notifier).submit(
      text: text,
      voiceMediaId: voiceMediaId,
      voiceBase64: voiceBase64,
      voiceContentType: voiceContentType,
      anchorLat: widget.anchorLat,
      anchorLng: widget.anchorLng,
    );
    if (!mounted) return;
    final status = ref.read(searchStatusProvider);
    if (status.error != null) {
      setState(() {
        _busy = false;
        _hint = status.error;
      });
      return;
    }
    // 解析成功（有槽位或已判「没听懂」）都关闭面板，结果由条件带呈现。
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(searchStatusProvider);
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '说出你要找的',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w700,
              color: const Color(AppColors.textPrimary),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '例如：我在锦绣小区要租房，1 公里内 2000 以内，要合租',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Center(
            child: GestureDetector(
              onLongPressStart: (_) => _start(),
              onLongPressEnd: (_) => _stop(),
              onTap: _recording ? _stop : _start,
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _recording
                      ? const Color(AppColors.accent)
                      : const Color(AppColors.primary),
                ),
                child: Icon(
                  _recording ? Icons.stop : Icons.mic_none,
                  color: Colors.white,
                  size: 32,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _recording ? '松开结束' : '按住说话',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: const Color(AppColors.textSecondary),
            ),
          ),
          if (_busy || status.busy) ...[
            const SizedBox(height: AppSpacing.md),
            const LinearProgressIndicator(minHeight: 2),
          ],
          if (_hint != null) ...[
            const SizedBox(height: AppSpacing.md),
            Text(
              _hint!,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ],
          if (_permissionDenied) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: openAppSettings,
              child: const Text('去系统设置开启麦克风权限'),
            ),
          ],
          if (status.error != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              status.error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(AppColors.errorText)),
            ),
          ],
        ],
      ),
    );
  }
}
