/// 详情页顶部媒体轮播（PRD §7.4.1 顶部媒体区 / §7.7「图片点击可全屏查看」）。
///
/// **只做图片**：§7.7 的「视频 + 内置播放器」依赖视频转码与播放器插件，不在
/// 本轮范围内（发布侧同样只收图片，见 `publish/media_section.dart`）。
///
/// **无 Figma 稿（如实登记）**：`code.js` 的详情页 builder 顶部媒体区只有
/// 地图背景图，没有轮播构件；故按 PRD §7.4.1 的版面落地，块高 200 与改造前的
/// 分类色占位块同高，避免下方内容整体位移。
///
/// **空态不消失**：`mediaUrls` 为空时渲染分类色占位块 —— 直接移除会让「无图
/// 信息」少一块版面，与「有图信息」看起来像两个页面；且该版面高度是下方
/// 内容位置的基准。
///
/// **计数器而非圆点**：页码用文字 `1 / 3` 表达（颜色/圆点不是唯一载体，见
/// PRD §1.4.2 无障碍），单张时不显示。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../domain/listing_category.dart';
// 配色与图标是 ListingCategory 的 style 扩展（枚举本体保持纯 Dart，见
// detail_screen.dart 同处说明），占位块取色须引它。
import '../../domain/listing_category_style.dart';
import '../media/media_display_layout.dart';

/// 顶部媒体轮播（图片）。
class MediaCarousel extends StatefulWidget {
  /// 构造媒体轮播。
  ///
  /// 参数：[mediaUrls] 图片 URL 列表（空＝无图，渲染占位块）；
  ///   [category] 空态占位块用的分类色（决定占位块的色与图标）。
  const MediaCarousel({
    super.key,
    required this.mediaUrls,
    required this.category,
  });

  /// 图片 URL 列表。
  final List<String> mediaUrls;

  /// 空态占位块用的分类。
  final ListingCategory category;

  @override
  State<MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends State<MediaCarousel> {
  final PageController _controller = PageController();

  /// 当前页下标（计数器用）。
  int _index = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 打开全屏查看（PRD §7.7「图片点击可全屏查看」）。
  ///
  /// 参数：[index] 进入时展示的下标。
  /// 返回：void。
  void _openFullScreen(int index) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _FullScreenMedia(urls: widget.mediaUrls, initialIndex: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.mediaUrls.isEmpty) {
      // 与有图态同一张卡片的几何：无图时若仍是整宽贴边，两种状态会像两个页面。
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          child: _PlaceholderBlock(category: widget.category),
        ),
      );
    }

    // 卡片化（借鉴美团图集观感）：左右内缩 + 圆角，让媒体区成为页面里的
    // 一张卡片，而不是贴边的黑色条块；左右留白由页面底色承担，不再是黑框。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.xl),
        child: SizedBox(
          height: kDetailMediaBlockHeight,
          child: Stack(
            children: [
              PageView.builder(
                controller: _controller,
                itemCount: widget.mediaUrls.length,
                onPageChanged: (index) => setState(() => _index = index),
                itemBuilder: (context, index) => GestureDetector(
                  onTap: () => _openFullScreen(index),
                  child: _NetworkImage(url: widget.mediaUrls[index]),
                ),
              ),
              // 底部渐变遮罩：计数器压在任意明暗的图上都能读清，视觉重量远小于
              // 整块黑底。单张不显示计数器，也就不需要遮罩。
              if (widget.mediaUrls.length > 1)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: _scrimHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, _scrimBottomColor],
                      ),
                    ),
                  ),
                ),
              // 单张不显示计数器：`1 / 1` 是无信息量的噪声。
              if (widget.mediaUrls.length > 1)
                Positioned(
                  right: AppSpacing.md,
                  bottom: AppSpacing.md,
                  child: MediaCounterPill(index: _index, total: widget.mediaUrls.length),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// 区块高与裁剪比例共用 `media_display_layout.dart`，此处不再另存一份常量。

/// 底部渐变遮罩高度（计数器所在区域，只压暗这一条，不压整图）。
const double _scrimHeight = 40;

/// 渐变遮罩底端颜色（黑 35%，白字计数器在其上满足对比度）。
const Color _scrimBottomColor = Color(0x59000000);

/// 模糊铺底的放大倍数：高斯模糊会在边界采样到透明像素，放大一点把边缘推出
/// 裁剪区，避免卡片四周出现一圈浅色细线。
const double _backdropScale = 1.12;

/// 模糊铺底的高斯半径（像素）。只做色彩延伸，不承载可读信息，取大值更柔和。
const double _backdropBlurSigma = 18;

/// 页码胶囊（`1 / 3`）。
///
/// 公开而非私有：全屏查看页复用同一指示器，两处同一语义须同一形态。
class MediaCounterPill extends StatelessWidget {
  /// 构造页码胶囊。
  ///
  /// 参数：[index] 当前下标（0 起）；[total] 总数。
  const MediaCounterPill({super.key, required this.index, required this.total});

  /// 当前下标（0 起）。
  final int index;

  /// 总数。
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        // 图片明暗不可控，指示器必须自带底色，否则浅色图上读不出来。
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        '${index + 1} / $total',
        style: TextStyle(
          fontSize: AppTypeScale.caption.size,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 单张网络图（加载中与失败各有占位，避免空白或抛异常）。
class _NetworkImage extends StatelessWidget {
  /// 构造单张网络图。
  ///
  /// 参数：[url] 图片地址。
  const _NetworkImage({required this.url});

  /// 图片地址。
  final String url;

  @override
  Widget build(BuildContext context) {
    // 铺满且不变形（2026-10-19 反馈「左右黑色很难看」）：
    //   底层 = 同一张图 cover + 高斯模糊，负责填满整块，留白变成图片自身的色调；
    //   上层 = 原图 contain，保证全貌不被裁切（2026-10-17 反馈「图片未展示完整」，
    //          因此不能退回单层 cover）。
    // 两层同 URL 命中 Flutter 的 ImageCache（含并发请求去重），不会重复下载。
    return Stack(
      fit: StackFit.expand,
      children: [
        ClipRect(
          child: Transform.scale(
            scale: _backdropScale,
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: _backdropBlurSigma,
                sigmaY: _backdropBlurSigma,
              ),
              child: Image.network(
                url,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                // 底层只做色彩延伸：加载中/失败交给上层统一占位，
                // 否则两层占位会叠出双图标。
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const SizedBox.shrink(),
                errorBuilder: (context, error, stack) => const SizedBox.shrink(),
              ),
            ),
          ),
        ),
        Image.network(
          url,
          fit: BoxFit.contain,
          width: double.infinity,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : const _ImageFallback(icon: Icons.image_outlined),
          // 加载失败不抛异常、不留白块：OSS 对象可能已被清理，页面仍须可读。
          errorBuilder: (context, error, stack) =>
              const _ImageFallback(icon: Icons.broken_image_outlined),
        ),
      ],
    );
  }
}

/// 图片中性占位（加载中 / 失败共用）。
class _ImageFallback extends StatelessWidget {
  /// 构造占位。
  ///
  /// 参数：[icon] 占位图标。
  const _ImageFallback({required this.icon});

  /// 占位图标。
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Color(AppColors.border),
      child: Center(
        child: Icon(icon, size: 40, color: Color(AppColors.textPlaceholder)),
      ),
    );
  }
}

/// 无图占位块（分类色渐变 + 图标 + 说明）。
///
/// 用分类色而非灰块：灰块在验收时会被误认为「图没加载出来」，带分类色的
/// 渐变一眼能看出是刻意的占位。
class _PlaceholderBlock extends StatelessWidget {
  /// 构造无图占位块。
  ///
  /// 参数：[category] 分类（决定配色与图标）。
  const _PlaceholderBlock({required this.category});

  /// 分类。
  final ListingCategory category;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kDetailMediaBlockHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            category.color.withValues(alpha: 0.85),
            category.deepColor.withValues(alpha: 0.95),
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              category.icon,
              size: 56,
              color: Colors.white.withValues(alpha: 0.9),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '该信息未上传图片',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: Colors.white.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 全屏图片查看（PRD §7.7）。
///
/// 黑底 + 可横滑 + 页码，左上角关闭。不做缩放/保存：PRD 未要求，且保存涉及
/// 权限与相册插件，属另一条目。
class _FullScreenMedia extends StatefulWidget {
  /// 构造全屏查看。
  ///
  /// 参数：[urls] 图片地址列表；[initialIndex] 进入时的下标。
  const _FullScreenMedia({required this.urls, required this.initialIndex});

  /// 图片地址列表。
  final List<String> urls;

  /// 进入时的下标。
  final int initialIndex;

  @override
  State<_FullScreenMedia> createState() => _FullScreenMediaState();
}

class _FullScreenMediaState extends State<_FullScreenMedia> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);

  late int _index = widget.initialIndex;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            PageView.builder(
              controller: _controller,
              itemCount: widget.urls.length,
              onPageChanged: (index) => setState(() => _index = index),
              itemBuilder: (context, index) => Center(
                child: Image.network(
                  widget.urls[index],
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) =>
                      const _ImageFallback(icon: Icons.broken_image_outlined),
                ),
              ),
            ),
            Positioned(
              left: AppSpacing.sm,
              top: AppSpacing.sm,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            if (widget.urls.length > 1)
              Positioned(
                right: AppSpacing.md,
                bottom: AppSpacing.md,
                child: MediaCounterPill(index: _index, total: widget.urls.length),
              ),
          ],
        ),
      ),
    );
  }
}
