/// 裁剪结果归一化测试（发布页可选裁剪的产物必须可上传且不超限）。
///
/// 守三件事：
/// 1. `crop_your_image` 输出 PNG，归一化后必须是 `image/jpeg`（否则 20MB
///    上限与 3M 带宽上传都会被大尺寸 PNG 拖垮）；
/// 2. 长边必须收到 [kCroppedMaxLongEdge]，且宽高比不变（裁剪结果不能变形）；
/// 3. PNG 透明通道按白底合成，不能编码成黑块。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zhaoyazhao/features/media/media_image_encoder.dart';
import 'package:zhaoyazhao/features/media/media_picker.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

void main() {
  group('normalizeCroppedImage（裁剪结果归一化）', () {
    test('PNG 转 JPEG，长边收到上限且保持宽高比', () {
      final source = img.Image(width: 2400, height: 1200);
      img.fill(source, color: img.ColorRgb8(20, 120, 200));
      final png = img.encodePng(source);

      final result = normalizeCroppedImage(
        CropEncodeInput(bytes: png, filename: 'photo.png'),
      );

      expect(result.contentType, 'image/jpeg');
      expect(result.filename, 'photo.jpg');
      expect(result.size, lessThanOrEqualTo(NfrMedia.maxSizeBytes));

      final decoded = img.decodeImage(result.bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, kCroppedMaxLongEdge);
      expect(decoded.height, kCroppedMaxLongEdge ~/ 2);
    });

    test('小图不放大：长边已在限制内时保持原尺寸', () {
      final source = img.Image(width: 320, height: 200);
      img.fill(source, color: img.ColorRgb8(10, 10, 10));
      final png = img.encodePng(source);

      final result = normalizeCroppedImage(
        CropEncodeInput(bytes: png, filename: 'small.png'),
      );

      final decoded = img.decodeImage(result.bytes)!;
      expect(decoded.width, 320);
      expect(decoded.height, 200);
    });

    test('PNG 透明区域按白底合成，不出现黑块', () {
      // 全透明红色：alpha=0，合成后应只剩白底。
      final source = img.Image(width: 60, height: 60, numChannels: 4);
      img.fill(source, color: img.ColorRgba8(255, 0, 0, 0));
      final png = img.encodePng(source);

      final result = normalizeCroppedImage(
        CropEncodeInput(bytes: png, filename: 'alpha.png'),
      );
      final decoded = img.decodeImage(result.bytes)!;
      final pixel = decoded.getPixel(30, 30);
      expect(pixel.r, greaterThan(240));
      expect(pixel.g, greaterThan(240));
      expect(pixel.b, greaterThan(240));
    });

    test('无法解码时抛出 MediaPickException', () {
      expect(
        () => normalizeCroppedImage(
          CropEncodeInput(
            bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
            filename: 'broken.png',
          ),
        ),
        throwsA(isA<MediaPickException>()),
      );
    });
  });

  group('normalizeUploadImage（相机/相册原图归一化）', () {
    test('PNG 原图转 JPEG（统一上传格式）', () {
      final source = img.Image(width: 640, height: 320);
      img.fill(source, color: img.ColorRgb8(20, 120, 200));
      final png = img.encodePng(source);

      final result = normalizeUploadImage(
        CropEncodeInput(bytes: png, filename: 'camera.png'),
      );

      expect(result.contentType, 'image/jpeg');
      expect(result.filename, 'camera.jpg');
      // 小图不放大，尺寸保持。
      final decoded = img.decodeImage(result.bytes)!;
      expect(decoded.width, 640);
      expect(decoded.height, 320);
    });

    test('无法解码抛出 MediaPickException', () {
      expect(
        () => normalizeUploadImage(
          CropEncodeInput(
            bytes: Uint8List.fromList(<int>[1, 2, 3]),
            filename: 'broken.jpg',
          ),
        ),
        throwsA(isA<MediaPickException>()),
      );
    });
  });

  group('readImageSizeAsync（拍后比例体检读宽高）', () {
    test('解码读取宽高', () async {
      final source = img.Image(width: 240, height: 480);
      img.fill(source, color: img.ColorRgb8(20, 120, 200));
      final png = img.encodePng(source);

      final size = await readImageSizeAsync(png);

      expect(size, isNotNull);
      expect(size!.width, 240);
      expect(size.height, 480);
    });

    test('无法解码返回 null（不抛异常）', () async {
      final size = await readImageSizeAsync(Uint8List.fromList(<int>[1, 2, 3]));
      expect(size, isNull);
    });
  });
}
