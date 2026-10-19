/// 图片裁剪页（发布页媒体段的可选入口）。
///
/// **可选而非必经**：用户点缩略图才进入；直接发布不裁剪也能成功。裁剪框按
/// 详情页媒体卡比例初始化（[detailMediaAspectRatio]），裁剪后详情页可完整
/// 填充、不出现左右留白，同时不裁掉主体。
///
/// **输出**：`crop_your_image` 返回 PNG，交给 [normalizeCroppedImageAsync]
/// 转 JPEG 并限制长边后再回到媒体段重新上传。
library;

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import 'media_display_layout.dart';
import 'media_image_encoder.dart';
import 'media_picker.dart';

/// 裁剪页。
class ImageCropScreen extends StatefulWidget {
  /// 构造裁剪页。
  ///
  /// 参数：
  /// - [source] 待裁剪的本地图片；
  /// - [aspectRatio] 裁剪框宽高比（由详情页媒体卡尺寸算出）。
  const ImageCropScreen({
    super.key,
    required this.source,
    required this.aspectRatio,
  });

  /// 待裁剪的本地图片。
  final PickedMedia source;

  /// 裁剪框宽高比。
  final double aspectRatio;

  @override
  State<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends State<ImageCropScreen> {
  final CropController _controller = CropController();

  /// 正在编码裁剪结果（防重入 + 显示遮罩）。
  bool _processing = false;

  /// 裁剪器是否已把图片解码完成；未就绪时点「完成」没有意义。
  bool _ready = false;

  /// 处理裁剪结果：成功则带着新图片返回上一页。
  ///
  /// 参数：[result] `crop_your_image` 的回调结果。
  /// 返回：[Future<void>]。
  Future<void> _onCropped(CropResult result) async {
    switch (result) {
      case CropSuccess(:final croppedImage):
        setState(() => _processing = true);
        try {
          final cropped = await normalizeCroppedImageAsync(
            CropEncodeInput(
              bytes: croppedImage,
              filename: widget.source.filename,
            ),
          );
          if (!mounted) return;
          Navigator.of(context).pop(cropped);
        } on MediaPickException catch (error) {
          _fail(error.userMessage);
        } catch (error) {
          _fail(asApiException(error).uiMessage);
        }
      case CropFailure():
        _fail('裁剪失败，请重试');
    }
  }

  /// 失败时恢复按钮并提示。
  ///
  /// 参数：[message] 用户可见文案。
  /// 返回：void。
  void _fail(String message) {
    if (!mounted) return;
    setState(() => _processing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// 触发裁剪（具体结果在 [Crop.onCropped] 回调里取）。
  ///
  /// 返回：void。
  void _confirm() {
    if (_processing) return;
    setState(() => _processing = true);
    _controller.crop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text('裁剪图片'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.info_outline,
                  size: 16,
                  color: Colors.white70,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '按详情页比例裁剪，展示更美观；不裁剪也能直接发布',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Stack(
              children: [
                Crop(
                  image: widget.source.bytes,
                  controller: _controller,
                  aspectRatio: widget.aspectRatio,
                  interactive: true,
                  // 锁定裁剪框、让用户拖动/缩放图片：比「拖框选区域」更符合
                  // 手机上的单指操作习惯，也不会裁出比例不符的结果。
                  fixCropRect: true,
                  // 默认初始框只按「图片适配后的宽度」取最大，竖图会只占约
                  // 70% 屏宽；这里改为按视口取最大，框宽度铺满可用区域。
                  initialRectBuilder: InitialRectBuilder.withBuilder(
                    (viewportRect, imageRect) => initialCropRect(
                      viewportRect.size,
                      widget.aspectRatio,
                    ),
                  ),
                  maskColor: Colors.black54,
                  baseColor: Colors.black,
                  radius: AppRadius.md,
                  progressIndicator: const Center(
                    child: CircularProgressIndicator(),
                  ),
                  onStatusChanged: (status) {
                    if (!mounted) return;
                    setState(() => _ready = status == CropStatus.ready);
                  },
                  onCropped: _onCropped,
                ),
                if (_processing)
                  const Positioned.fill(
                    child: ColoredBox(
                      color: Colors.black54,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _processing
                          ? null
                          : () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white38),
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md,
                        ),
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: FilledButton(
                      onPressed: (_processing || !_ready) ? null : _confirm,
                      style: FilledButton.styleFrom(
                        backgroundColor: Color(AppColors.primary),
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md,
                        ),
                      ),
                      child: const Text('完成'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
