/// 裁剪框初始几何测试。
///
/// 2026-10-19 真机反馈：竖图进入裁剪页时，裁剪框只占屏宽约 70%。根因是用
/// 第三方库的默认初始框（它按「图片适配高度后的宽度」计算），而不是按视口
/// 取最大。本测试锁住「按比例铺满可用区域」这一口径。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/design_tokens.dart';
import 'package:zhaoyazhao/features/media/media_display_layout.dart';

void main() {
  group('initialCropRect（裁剪框初始矩形）', () {
    test('宽视口：宽度铺满可用区域，高度按比例，四周留安全边距', () {
      const viewport = Size(1080, 1800);
      const ratio = 1.803;

      final rect = initialCropRect(viewport, ratio);

      expect(rect.width, closeTo(1080 - 2 * AppSpacing.sm, 0.001));
      expect(rect.height, closeTo(rect.width / ratio, 0.001));
      expect(rect.center.dx, closeTo(540, 0.001));
      expect(rect.center.dy, closeTo(900, 0.001));
    });

    test('矮视口：高度成为约束时按高度取最大，宽高比不变', () {
      const viewport = Size(1080, 300);
      const ratio = 1.803;

      final rect = initialCropRect(viewport, ratio);

      expect(rect.height, closeTo(300 - 2 * AppSpacing.sm, 0.001));
      expect(rect.width, closeTo(rect.height * ratio, 0.001));
      expect(rect.width, lessThanOrEqualTo(1080 - 2 * AppSpacing.sm));
    });
  });

  group('aspectMismatchExceeds（拍后比例体检判定）', () {
    test('16:9 与详情比例 1.79 偏差约 0.7%，不超阈值', () {
      final exceeds = aspectMismatchExceeds(
        width: 1600,
        height: 900, // 16:9 = 1.778
        targetAspect: 1.79,
        tolerance: kAspectMismatchTolerance,
      );
      expect(exceeds, isFalse);
    });

    test('4:3 偏差约 26%，超阈值', () {
      final exceeds = aspectMismatchExceeds(
        width: 1200,
        height: 900, // 4:3 = 1.333
        targetAspect: 1.79,
        tolerance: kAspectMismatchTolerance,
      );
      expect(exceeds, isTrue);
    });

    test('竖拍 3:4 偏差约 58%，超阈值', () {
      final exceeds = aspectMismatchExceeds(
        width: 900,
        height: 1200, // 3:4 = 0.75
        targetAspect: 1.79,
        tolerance: kAspectMismatchTolerance,
      );
      expect(exceeds, isTrue);
    });

    test('零高度或零目标比例不误判为超阈值', () {
      expect(
        aspectMismatchExceeds(
          width: 100,
          height: 0,
          targetAspect: 1.79,
          tolerance: kAspectMismatchTolerance,
        ),
        isFalse,
      );
      expect(
        aspectMismatchExceeds(
          width: 100,
          height: 100,
          targetAspect: 0,
          tolerance: kAspectMismatchTolerance,
        ),
        isFalse,
      );
    });
  });
}
