/// 本地录音（B2-4 模式② 语音零键盘）：把 `record` 插件收敛为可测的抽象。
///
/// 设计理由与 [MediaPicker] 同源：`record` 依赖平台通道（麦克风），widget 测试
/// 无法驱动；故把「录一段音频」收敛为 [AudioRecorder] 接口，生产用
/// [DeviceAudioRecorder]（包 `record` + `path_provider`），测试注入假实现。
///
/// **格式口径**：AAC-LC / m4a → MIME `audio/mp4`（在后端 `NfrMedia.AUDIO_CONTENT_TYPES`
/// 白名单内）。选它是因为它是 `record` 的默认编码器、且各平台通用；
/// 后端 ASR 走通义千问多模态通道（已备案覆盖，见进度记录 2026-10-13）。
///
/// **为什么给 `record` 加前缀**：插件导出的类名也叫 `AudioRecorder`，
/// 与本域对外接口同名；不加前缀会让 `implements AudioRecorder` 解析到插件类。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as record;
import 'package:uuid/uuid.dart';

/// 录音失败（本域自有的用户可见错误，不套 API 异常）。
class AudioRecordException implements Exception {
  /// 构造录音异常。
  ///
  /// 参数：[userMessage] 面向用户的提示文案。
  const AudioRecordException(this.userMessage);

  /// 面向用户的提示文案。
  final String userMessage;

  @override
  String toString() => 'AudioRecordException($userMessage)';
}

/// 录好的一段音频（尚未上传）。
class RecordedClip {
  /// 构造录音产物。
  const RecordedClip({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  /// 文件名（含 m4a 后缀）。
  final String filename;

  /// 音频字节。
  final Uint8List bytes;

  /// MIME 类型（恒 `audio/mp4`）。
  final String contentType;

  /// 字节数。
  int get size => bytes.length;
}

/// 录音器抽象。
abstract interface class AudioRecorder {
  /// 申请/查询麦克风权限。
  ///
  /// 返回：是否已获授权。
  Future<bool> hasPermission();

  /// 开始录音（写入应用临时目录）。
  ///
  /// 返回：[Future] 完成信号。
  /// 抛出：[AudioRecordException] 平台不可用等。
  Future<void> start();

  /// 停止并取得录音产物。
  ///
  /// 返回：录到的片段；无产物（空文件/文件不存在）时为 null。
  Future<RecordedClip?> stop();

  /// 放弃本次录音（删除临时文件）。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> cancel();

  /// 释放平台资源。
  ///
  /// 返回：[Future] 完成信号。
  Future<void> dispose();
}

/// 基于 `record` + `path_provider` 的生产实现。
class DeviceAudioRecorder implements AudioRecorder {
  /// 构造生产录音器。
  ///
  /// 参数：[device] 可注入的 `record` 实例（测试可省略，默认新建）。
  DeviceAudioRecorder({record.AudioRecorder? device})
      : _device = device ?? record.AudioRecorder();

  final record.AudioRecorder _device;

  /// 当前录音的落盘路径（stop 时读它取字节）。
  String? _path;

  @override
  Future<bool> hasPermission() => _device.hasPermission();

  @override
  Future<void> start() async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/${const Uuid().v4()}.m4a';
    _path = path;
    await _device.start(
      const record.RecordConfig(encoder: record.AudioEncoder.aacLc),
      path: path,
    );
  }

  @override
  Future<RecordedClip?> stop() async {
    final stoppedPath = await _device.stop();
    final path = stoppedPath ?? _path;
    _path = null;
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) return null;
    final bytes = await file.readAsBytes();
    if (bytes.isEmpty) return null;
    return RecordedClip(
      filename: file.uri.pathSegments.last,
      bytes: bytes,
      contentType: 'audio/mp4',
    );
  }

  @override
  Future<void> cancel() async {
    await _device.cancel();
    final path = _path;
    _path = null;
    if (path == null) return;
    final file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  }

  @override
  Future<void> dispose() => _device.dispose();
}

/// 录音器 Provider（测试用假实现覆盖）。
final audioRecorderProvider = Provider<AudioRecorder>(
  (ref) => DeviceAudioRecorder(),
);
