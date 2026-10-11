/// 媒体上传链路单测（[B2-11]）。
///
/// 覆盖：三步链路（票据 → OSS 直传 → commit）的**真实编排**、直传请求的
/// URL/Content-Type/字节断言、失败分支（直传失败不得 commit、票据业务错误
/// 不得直传），以及选图侧的白名单/体积校验。
///
/// 装配方式沿用 R9「生产同款」：业务侧用 [buildNetworkDio] 真链 + 假
/// HttpClientAdapter（不真发网络）；让「切真服务断言一行不改」成立。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/media/media_picker.dart';
import 'package:zhaoyazhao/features/media/media_repository.dart';
import 'package:zhaoyazhao/features/media/media_upload_service.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

/// 记录请求并可编排响应的假适配器。
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.respond);

  /// 响应编排函数。
  final ResponseBody Function(RequestOptions options) respond;

  /// 收到的请求（含请求体字节，便于断言 PUT 内容）。
  final List<({RequestOptions options, List<int> body})> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final body = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        body.addAll(chunk);
      }
    }
    requests.add((options: options, body: body));
    return respond(options);
  }

  @override
  void close({bool force = false}) {}
}

/// 构造 JSON 响应体。
ResponseBody _json(Object payload, {int statusCode = 200}) => ResponseBody.fromString(
      jsonEncode(payload),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );

/// 构造成功信封。
Map<String, Object?> _envelope(Object? data) => {
      'code': 0,
      'message': 'ok',
      'request_id': 'req-test',
      'data': data,
    };

/// 业务侧 dio（生产同款五拦截器链 + 假适配器）。
Dio _appDio(_RecordingAdapter adapter) {
  final dio = buildNetworkDio(
    config: NetworkConfig(baseUrl: 'http://localhost:1', isRelease: false),
    hooks: NetworkHooks(
      readToken: () async => null,
      readPrivacyConsented: () async => false,
      readDeviceId: () async => null,
      newUuidV4: () => '00000000-0000-4000-8000-000000000000',
      writeToken: (_, _) async {},
      onSessionCleared: () async {},
      readSessionEpoch: () async => 0,
    ),
    // 禁真睡：重试等待即时返回。
    retrySleeper: (_) async {},
    retryRandomRatio: () => 0.5,
  );
  dio.httpClientAdapter = adapter;
  return dio;
}

/// 构造一张已选媒体。
PickedMedia _picked({int size = 8, String contentType = 'image/jpeg'}) => PickedMedia(
      filename: 'IMG_0421.jpg',
      bytes: Uint8List.fromList(List<int>.filled(size, 7)),
      contentType: contentType,
    );

void main() {
  group('MediaUploadService.upload（三步链路，[B2-11]）', () {
    test('票据 → 直传 → commit：直传 URL/Content-Type/字节正确，返回 commit 结果', () async {
      final appAdapter = _RecordingAdapter((options) {
        if (options.path == '/media/upload/ticket') {
          return _json(_envelope({
            'media_id': 'mda_1',
            'upload_url': 'https://oss.example.com/upload/obj-key',
            'expire_at': '2026-10-11T12:00:00Z',
          }));
        }
        if (options.path == '/media/mda_1/commit') {
          return _json(_envelope({
            'media_id': 'mda_1',
            'url': 'https://oss.example.com/access/display/obj-key',
            'audit_status': 'pass',
            'reject_reason': null,
          }));
        }
        fail('未预期的业务请求：${options.path}');
      });
      final ossAdapter = _RecordingAdapter((_) => _json(const {}));

      final service = MediaUploadService(
        repository: MediaRepository(_appDio(appAdapter)),
        ossDio: Dio()..httpClientAdapter = ossAdapter,
      );

      final result = await service.upload(_picked(size: 8));

      expect(result.mediaId, 'mda_1');
      expect(result.auditStatus, 'pass');
      expect(result.url, contains('display/obj-key'));

      // 票据请求体字段逐字对齐契约（filename/size/content_type）。
      final ticketBody = jsonDecode(utf8.decode(appAdapter.requests.first.body)) as Map;
      expect(ticketBody['filename'], 'IMG_0421.jpg');
      expect(ticketBody['size'], 8);
      expect(ticketBody['content_type'], 'image/jpeg');

      // 直传：URL 用票据给的签名地址，Content-Type 与签发一致，字节原样。
      expect(ossAdapter.requests, hasLength(1));
      final put = ossAdapter.requests.single;
      expect(put.options.uri.toString(), 'https://oss.example.com/upload/obj-key');
      expect(put.options.headers[Headers.contentTypeHeader], 'image/jpeg');
      expect(put.body, hasLength(8));

      // 业务侧共两次调用（票据 + commit）。
      expect(appAdapter.requests.map((r) => r.options.path), [
        '/media/upload/ticket',
        '/media/mda_1/commit',
      ]);
    });

    test('直传失败 → 抛 DioException 且不 commit（不留半截媒体）', () async {
      final appAdapter = _RecordingAdapter((_) => _json(_envelope({
            'media_id': 'mda_1',
            'upload_url': 'https://oss.example.com/upload/obj-key',
            'expire_at': '2026-10-11T12:00:00Z',
          })));
      final ossAdapter = _RecordingAdapter((options) => _json(const {}, statusCode: 403));

      final service = MediaUploadService(
        repository: MediaRepository(_appDio(appAdapter)),
        ossDio: Dio()..httpClientAdapter = ossAdapter,
      );

      await expectLater(service.upload(_picked()), throwsA(isA<DioException>()));

      // 只发过票据，绝无 commit（403 由 validateStatus 恒 true 的裸 dio 收，
      // 但裸 dio 未开 validateStatus，故 403 由 dio 自身抛 badResponse）。
      expect(appAdapter.requests.map((r) => r.options.path), ['/media/upload/ticket']);
    });

    test('票据业务错误（40001）→ 抛 ApiException 且不直传', () async {
      final appAdapter = _RecordingAdapter((_) => _json({
            'code': 40001,
            'message': 'content_type 不在白名单',
            'request_id': 'req-1',
          }));
      final ossAdapter = _RecordingAdapter((_) => _json(const {}));

      final service = MediaUploadService(
        repository: MediaRepository(_appDio(appAdapter)),
        ossDio: Dio()..httpClientAdapter = ossAdapter,
      );

      // 观察（如实记录）：生产同款链路上，EnvelopeInterceptor 抛出的
      // ApiException 会被 dio 包进 DioException(error:)，故这里断言「ApiException
      // 可达」而非直接 is ApiException —— 与各 feature 在 Provider 边界统一走
      // asApiException(e) 归一的既有约定一致。
      await expectLater(
        service.upload(_picked()),
        throwsA(predicate(
          (Object? e) =>
              e is ApiException || (e is DioException && e.error is ApiException),
        )),
      );
      expect(ossAdapter.requests, isEmpty);
    });
  });

  group('ImagePickerMediaPicker 白名单与体积校验（[B2-11]）', () {
    test('白名单外格式（HEIC）→ MediaPickException', () async {
      final picker = ImagePickerMediaPicker(
        picker: _FakeImagePicker([
          XFile.fromData(
            Uint8List.fromList([1, 2, 3]),
            name: 'IMG.HEIC',
            mimeType: 'image/heic',
          ),
        ]),
      );

      await expectLater(
        picker.pickImages(limit: NfrMedia.maxMediaCount),
        throwsA(isA<MediaPickException>().having(
          (e) => e.userMessage,
          'userMessage',
          '仅支持 JPG / PNG / WebP 图片',
        )),
      );
    });

    test('单文件超上限 → MediaPickException（文案上限由常量算出）', () async {
      final oversized = Uint8List.fromList(List<int>.filled(NfrMedia.maxSizeBytes + 1, 1));
      final picker = ImagePickerMediaPicker(
        picker: _FakeImagePicker([
          XFile.fromData(oversized, name: 'IMG.jpg', mimeType: 'image/jpeg'),
        ]),
      );

      final limitMb = NfrMedia.maxSizeBytes ~/ (1024 * 1024);
      await expectLater(
        picker.pickImages(limit: NfrMedia.maxMediaCount),
        throwsA(isA<MediaPickException>().having(
          (e) => e.userMessage,
          'userMessage',
          '单张图片不能超过 ${limitMb}MB',
        )),
      );
    });

    test('白名单内 jpeg 原样产出字节与 MIME', () async {
      final picker = ImagePickerMediaPicker(
        picker: _FakeImagePicker([
          XFile.fromData(
            Uint8List.fromList([1, 2, 3, 4]),
            name: 'IMG_0421.jpg',
            mimeType: 'image/jpeg',
          ),
        ]),
      );

      final result = await picker.pickImages(limit: NfrMedia.maxMediaCount);
      expect(result, hasLength(1));
      expect(result.single.contentType, 'image/jpeg');
      expect(result.single.size, 4);
    });
  });
}

/// 假 ImagePicker（覆写平台通道方法，避免真调图库）。
class _FakeImagePicker extends ImagePicker {
  _FakeImagePicker(this._files);

  final List<XFile> _files;

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    bool requestFullMetadata = true,
    int? limit,
  }) async =>
      _files;
}
