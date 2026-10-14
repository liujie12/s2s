/// 媒体域测试替身（B2-4 语音链路新增）。
///
/// 与 `fake_repositories.dart` 同取向：继承生产类保单一调用面（签名漂移编译期炸），
/// 全部纯微任务（fake async 下 pumpAndSettle 可推进），绝不出网、绝不碰平台通道。
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:zhaoyazhao/features/media/audio_recorder.dart';
import 'package:zhaoyazhao/features/media/media_picker.dart';
import 'package:zhaoyazhao/features/media/media_repository.dart';
import 'package:zhaoyazhao/features/media/media_upload_service.dart';

/// 假录音器：权限与产物可控，调用次数可断言。
class FakeAudioRecorder implements AudioRecorder {
  /// 权限是否授予（默认 true）。
  bool permissionGranted = true;

  /// stop 返回的片段；null 表示「没录到声音」。
  RecordedClip? clipToReturn = RecordedClip(
    filename: 'voice.m4a',
    bytes: Uint8List.fromList(const <int>[1, 2, 3, 4]),
    contentType: 'audio/mp4',
  );

  /// start 调用次数。
  var startCount = 0;

  /// stop 调用次数。
  var stopCount = 0;

  /// cancel 调用次数。
  var cancelCount = 0;

  /// 是否正在录音。
  var recording = false;

  @override
  Future<bool> hasPermission() async => permissionGranted;

  @override
  Future<void> start() async {
    startCount++;
    recording = true;
  }

  @override
  Future<RecordedClip?> stop() async {
    stopCount++;
    recording = false;
    return clipToReturn;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    recording = false;
  }

  @override
  Future<void> dispose() async {}
}

/// 假媒体上传服务：不直传 OSS，直接返回固定 mediaId。
class FakeMediaUploadService extends MediaUploadService {
  /// 构造。dio/repository 均为占位（本替身不发真请求）。
  FakeMediaUploadService({this.mediaId = 'media_voice_1'})
      : super(repository: MediaRepository(Dio()), ossDio: Dio());

  /// 返回的媒体 ID。
  final String mediaId;

  /// 最后一次上传的入参（断言音频走了上传链路）。
  PickedMedia? lastUploaded;

  /// upload 调用次数。
  var uploadCount = 0;

  @override
  Future<UploadedMedia> upload(PickedMedia media) async {
    uploadCount++;
    lastUploaded = media;
    return UploadedMedia(mediaId: mediaId, url: 'https://x/$mediaId', auditStatus: 'pending');
  }
}
