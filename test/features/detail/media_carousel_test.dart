/// 详情页媒体轮播 widget 测试（PRD §7.4.1 顶部媒体区 / §7.7 全屏查看）。
///
/// **守的是什么**：轮播的三种形态各有各的静默失效 —— 无图时若直接不渲染，
/// 页面会「少一块版面」而编译与运行都不报错；单图时若照常显示 `1 / 1`，
/// 是给用户看无信息量的噪声；多图时计数器若绑错下标（如 `onPageChanged`
/// 忘写 setState），滑到第二张仍显示 `1 / 3`，只有手划才看得出来。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/detail/media_carousel.dart';

void main() {
  /// 在 MaterialApp 中挂载轮播（图片走网络，测试环境下恒失败 → 落到 errorBuilder）。
  ///
  /// 参数：[tester] 测试器；[urls] 图片地址列表。
  /// 返回：[Future] 首帧完成。
  Future<void> pumpCarousel(WidgetTester tester, List<String> urls) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaCarousel(
            mediaUrls: urls,
            category: ListingCategory.life,
          ),
        ),
      ),
    );
  }

  /// 三张图的样本（多图形态）。
  const threeUrls = [
    'https://oss.example.com/1.jpg',
    'https://oss.example.com/2.jpg',
    'https://oss.example.com/3.jpg',
  ];

  group('MediaCarousel（PRD §7.4.1 顶部媒体区）', () {
    testWidgets('无图：渲染占位块且不出现 PageView', (tester) async {
      await pumpCarousel(tester, const []);
      await tester.pump();

      expect(find.text('该信息未上传图片'), findsOneWidget);
      expect(find.byType(PageView), findsNothing);
    });

    testWidgets('多图：PageView 页数 = 图片数，计数器从 1 / N 起', (tester) async {
      await pumpCarousel(tester, threeUrls);
      await tester.pump();

      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.childrenDelegate.estimatedChildCount, 3);
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('滑一页：计数器跟到 2 / 3（onPageChanged 确实回写了下标）', (tester) async {
      await pumpCarousel(tester, threeUrls);
      await tester.pump();

      // fling 而非 drag：PageView 按「过半或带速度」吸附，纯位移在
      // 800 宽视图里不到半页会被吸回原页，断言就成了假红。
      await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
      await tester.pumpAndSettle();

      expect(find.text('2 / 3'), findsOneWidget);
      expect(find.text('1 / 3'), findsNothing);
    });

    testWidgets('单图：不显示计数器（1 / 1 是无信息量噪声）', (tester) async {
      await pumpCarousel(tester, const ['https://oss.example.com/1.jpg']);
      await tester.pump();

      expect(find.textContaining(' / '), findsNothing);
    });
  });

  group('全屏查看（PRD §7.7「图片点击可全屏查看」）', () {
    testWidgets('点击图片进入全屏，且有可关闭的出口', (tester) async {
      await pumpCarousel(tester, threeUrls);
      await tester.pump();

      // 点 PageView 而非 Image：现在每页有两层图（模糊底 + 前景），
      // 底层被前景覆盖、命中测试会落到前景占位上，直接找 Image 会产生
      // 「would not hit test」告警。
      await tester.tap(find.byType(PageView));
      await tester.pumpAndSettle();

      // 全屏页黑底 + 关闭按钮：进入后原页面已被覆盖。
      expect(find.byIcon(Icons.close), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('全屏页点关闭回到详情页', (tester) async {
      await pumpCarousel(tester, threeUrls);
      await tester.pump();

      // 点 PageView 而非 Image：现在每页有两层图（模糊底 + 前景），
      // 底层被前景覆盖、命中测试会落到前景占位上，直接找 Image 会产生
      // 「would not hit test」告警。
      await tester.tap(find.byType(PageView));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.close), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
    });
  });
}
