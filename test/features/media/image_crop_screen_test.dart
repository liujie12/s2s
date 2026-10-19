/// 裁剪页冒烟测试：可选说明、出口与取消返回。
///
/// 这里不驱动真实裁剪手势（第三方 `Crop` 的手势细节不属于本项目的契约），
/// 只锁「入口能打开、文案说清可选、取消能回到上一页」三件事。
library;

import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zhaoyazhao/features/media/image_crop_screen.dart';
import 'package:zhaoyazhao/features/media/media_picker.dart';

void main() {
  testWidgets('裁剪页展示可选说明，取消可返回', (tester) async {
    final png = _solidPng(width: 240, height: 480);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).push<PickedMedia>(
                  MaterialPageRoute<PickedMedia>(
                    builder: (_) => ImageCropScreen(
                      source: PickedMedia(
                        filename: 'a.png',
                        bytes: png,
                        contentType: 'image/png',
                      ),
                      aspectRatio: 1.8,
                    ),
                  ),
                ),
                child: const Text('打开裁剪'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开裁剪'));
    // 不用 pumpAndSettle：裁剪器解码期间有一个不确定进度的指示器，会一直
    // 排帧导致 settle 超时；这里只需要等路由转场结束。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(ImageCropScreen), findsOneWidget);
    expect(find.byType(Crop), findsOneWidget);
    expect(find.text('裁剪图片'), findsOneWidget);
    expect(
      find.text('按详情页比例裁剪，展示更美观；不裁剪也能直接发布'),
      findsOneWidget,
    );

    await tester.tap(find.text('取消'));
    // 退出后裁剪器连同进度指示器一起被移除，此时再 settle 不会无限排帧。
    await tester.pumpAndSettle();

    expect(find.byType(ImageCropScreen), findsNothing);
  });
}

/// 生成纯色 PNG。
Uint8List _solidPng({required int width, required int height}) {
  final image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(30, 60, 90));
  return img.encodePng(image);
}
