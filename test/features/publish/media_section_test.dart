/// 发布页媒体段：编辑态既有媒体回显 + 可选裁剪入口测试。
///
/// 锁三件事：
/// 1. 编辑既有帖时，`initialMedia` 必须进入计数与缩略图（此前媒体段自持空列表，
///    页面显示 `0 / 9`，但表单里其实带着 media_ids）；
/// 2. 移除/新增后 `onChanged` 上报的是「既有 + 新增」的全量已 commit ID，
///    不能把原媒体 ID 冲掉（否则保存会静默丢图）；
/// 3. 裁剪是可选入口：点缩略图才触发，裁剪框用详情卡比例，裁剪结果重新上传。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zhaoyazhao/features/media/media_cropper.dart';
import 'package:zhaoyazhao/features/media/media_display_layout.dart';
import 'package:zhaoyazhao/features/media/media_image_encoder.dart';
import 'package:zhaoyazhao/features/media/media_picker.dart';
import 'package:zhaoyazhao/features/media/media_upload_service.dart';
import 'package:zhaoyazhao/features/publish/media_section.dart';

void main() {
  testWidgets('编辑态回显既有媒体：计数含既有项，移除后上报剩余 ID', (tester) async {
    final changed = <List<String>>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MediaSection(
              // 空 URL：跳过网络请求，只验证「入列 + 计数 + 上报」。
              initialMedia: const [
                (mediaId: 'm1', url: ''),
                (mediaId: 'm2', url: ''),
              ],
              onChanged: changed.add,
            ),
          ),
        ),
      ),
    );

    expect(find.text('2 / 9 · 第 1 张为详情封面'), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsNWidgets(2));

    // 移除第一条：应上报剩余的 m2，而不是空列表。
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pump();

    expect(find.text('1 / 9 · 第 1 张为详情封面'), findsOneWidget);
    expect(changed, isNotEmpty);
    expect(changed.last, ['m2']);
  });

  testWidgets('点按缩略图裁剪：按详情卡比例启动裁剪并重新上传 JPEG', (tester) async {
    final uploader = _FakeUploadService();
    double? launchedRatio;
    var cropCalls = 0;
    var normalizeCalls = 0;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaPickerProvider.overrideWithValue(
            _FakePicker(
              PickedMedia(
                filename: 'a.png',
                bytes: _solidPng(width: 240, height: 480),
                contentType: 'image/png',
              ),
            ),
          ),
          // 归一化走 isolate，widget 测试注入假实现：模拟「PNG 统一转 JPEG」，
          // 并记录调用次数，验证选图后必经归一化。
          mediaNormalizerProvider.overrideWithValue((input) async {
            normalizeCalls++;
            return PickedMedia(
              filename: 'a.jpg',
              bytes: input.bytes,
              contentType: 'image/jpeg',
            );
          }),
          mediaUploadServiceProvider.overrideWithValue(uploader),
          mediaCropLauncherProvider.overrideWithValue(
            (context, {required source, required aspectRatio}) async {
              cropCalls++;
              launchedRatio = aspectRatio;
              return PickedMedia(
                filename: 'a.jpg',
                bytes: _solidJpeg(width: 360, height: 200),
                contentType: 'image/jpeg',
              );
            },
          ),
        ],
        child: MaterialApp(
          home: Scaffold(body: MediaSection(onChanged: (_) {})),
        ),
      ),
    );

    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 9 · 第 1 张为详情封面'), findsOneWidget);
    expect(find.text('点按缩略图可裁剪，详情页展示更美观（可选）'), findsOneWidget);
    expect(uploader.uploaded.single.contentType, 'image/jpeg');
    expect(normalizeCalls, 1);

    await tester.tap(find.byType(Image).first);
    await tester.pumpAndSettle();

    expect(cropCalls, 1);
    final expectedRatio = detailMediaAspectRatio(
      tester.element(find.byType(MediaSection)),
    );
    expect(launchedRatio, closeTo(expectedRatio, 0.0001));
    expect(uploader.uploaded.length, 2);
    expect(uploader.uploaded.last.contentType, 'image/jpeg');
  });

  testWidgets('缩略图语义标签：编辑态既有远程媒体也能读出「第几张 / 封面」', (tester) async {
    // 回归背景（2026-10-20 登记）：编辑/重发态的既有媒体没有本地字节，此前
    // 既不是按钮也没有 label，读屏用户完全拿不到「第几张/封面」信息。
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: MediaSection(
              initialMedia: const [
                (mediaId: 'm1', url: ''),
                (mediaId: 'm2', url: ''),
                (mediaId: 'm3', url: ''),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel(RegExp('第 1 张图片')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('第 2 张图片')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('第 3 张图片')), findsOneWidget);

    // 标签逐字断言：封面信息由 label 承载，视觉角标已 ExcludeSemantics，
    // 合并不该产生「详情封面 封面」这类重复播报。
    final cover = tester.getSemantics(
      find.bySemanticsLabel(RegExp('第 1 张图片')),
    );
    expect(cover.label, '第 1 张图片，详情封面');

    // 远程既有媒体不可裁剪 ⇒ 不应带「点按可裁剪」提示，也不应被标成按钮。
    final second = tester.getSemantics(
      find.bySemanticsLabel(RegExp('第 2 张图片')),
    );
    expect(second.label, '第 2 张图片');
    expect(second.hint, isEmpty);
    expect(
      second.flagsCollection.isButton,
      isFalse,
      reason: '不可裁剪的缩略图不该被读成按钮',
    );
    handle.dispose();
  });

  testWidgets('缩略图语义标签：本地新选图可读「第几张」且提示可裁剪', (tester) async {
    final handle = tester.ensureSemantics();
    final uploader = _FakeUploadService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaPickerProvider.overrideWithValue(
            _FakePicker(
              PickedMedia(
                filename: 'a.png',
                bytes: _solidPng(width: 240, height: 480),
                contentType: 'image/png',
              ),
            ),
          ),
          mediaNormalizerProvider.overrideWithValue(
            (input) async => PickedMedia(
              filename: input.filename,
              bytes: input.bytes,
              contentType: 'image/jpeg',
            ),
          ),
          mediaUploadServiceProvider.overrideWithValue(uploader),
        ],
        child: MaterialApp(
          home: Scaffold(body: MediaSection(onChanged: (_) {})),
        ),
      ),
    );

    await tester.tap(find.text('相册'));
    await tester.pumpAndSettle();

    final thumb = tester.getSemantics(
      find.bySemanticsLabel(RegExp('第 1 张图片')),
    );
    expect(thumb.hint, '点按可裁剪');
    expect(
      thumb.flagsCollection.isButton,
      isTrue,
      reason: '可裁剪的缩略图是可点动作，应暴露为按钮',
    );
    handle.dispose();
  });

  testWidgets('相机拍超比例图：弹三选一，选「仍然使用」后入列上传', (tester) async {
    final uploader = _FakeUploadService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaPickerProvider.overrideWithValue(
            _FakePicker(
              PickedMedia(
                filename: 'cam.jpg',
                bytes: _solidJpeg(width: 1200, height: 900),
                contentType: 'image/jpeg',
              ),
            ),
          ),
          // 读宽高走 isolate，注入假实现：4:3（1.33）明显偏离详情比例，触发体检。
          imageSizeReaderProvider.overrideWithValue(
            (bytes) async => (width: 1200, height: 900),
          ),
          // 归一化同样走 isolate，透传即可（本测试聚焦体检交互）。
          mediaNormalizerProvider.overrideWithValue(
            (input) async => PickedMedia(
              filename: input.filename,
              bytes: input.bytes,
              contentType: 'image/jpeg',
            ),
          ),
          mediaUploadServiceProvider.overrideWithValue(uploader),
        ],
        child: MaterialApp(
          home: Scaffold(body: MediaSection(onChanged: (_) {})),
        ),
      ),
    );

    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();

    expect(find.text('这张照片的比例和详情页不一致'), findsOneWidget);
    expect(find.text('仍然使用（保留原图）'), findsOneWidget);

    await tester.tap(find.text('仍然使用（保留原图）'));
    await tester.pumpAndSettle();

    expect(find.text('1 / 9 · 第 1 张为详情封面'), findsOneWidget);
    expect(uploader.uploaded.length, 1);
  });

  testWidgets('资质表单（simple）拍超比例图：不弹比例提示，直接入列上传', (tester) async {
    final uploader = _FakeUploadService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          mediaPickerProvider.overrideWithValue(
            _FakePicker(
              PickedMedia(
                filename: 'cam.jpg',
                bytes: _solidJpeg(width: 1200, height: 900),
                contentType: 'image/jpeg',
              ),
            ),
          ),
          imageSizeReaderProvider.overrideWithValue(
            (bytes) async => (width: 1200, height: 900),
          ),
          mediaNormalizerProvider.overrideWithValue(
            (input) async => PickedMedia(
              filename: input.filename,
              bytes: input.bytes,
              contentType: 'image/jpeg',
            ),
          ),
          mediaUploadServiceProvider.overrideWithValue(uploader),
        ],
        child: MaterialApp(
          home: Scaffold(body: MediaSection(onChanged: (_) {}, simple: true)),
        ),
      ),
    );

    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();

    // 资质页不参与详情页比例约束：三选一与「本次发布不再提示」都不应出现。
    expect(find.text('这张照片的比例和详情页不一致'), findsNothing);
    expect(find.text('本次发布不再提示'), findsNothing);
    expect(find.text('1 / 9 · 支持图片'), findsOneWidget);
    expect(uploader.uploaded.length, 1);
  });
}

/// 假选图器：固定返回一张图。
class _FakePicker implements MediaPicker {
  _FakePicker(this.media);

  final PickedMedia media;

  @override
  Future<List<PickedMedia>> pickImages({required int limit}) async => [media];

  @override
  Future<PickedMedia?> pickFromCamera() async => media;
}

/// 假上传服务：记录上传内容，返回递增 mediaId（不触网）。
class _FakeUploadService implements MediaUploadService {
  final List<PickedMedia> uploaded = <PickedMedia>[];

  @override
  Future<UploadedMedia> upload(PickedMedia media) async {
    uploaded.add(media);
    return UploadedMedia(
      mediaId: 'm${uploaded.length}',
      url: '',
      auditStatus: 'pass',
    );
  }
}

/// 生成纯色 PNG（用于测试选图/裁剪链路）。
Uint8List _solidPng({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(30, 60, 90));
  return img.encodePng(image);
}

/// 生成纯色 JPEG（模拟裁剪器归一化后的产物）。
Uint8List _solidJpeg({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(30, 60, 90));
  return img.encodeJpg(image);
}
