/// 发布页第 6 段「媒体」（§5.4.1「0 / 9 · 支持图片」；[B2-11] 由占位转真）。
///
/// **UI 基准（如实登记）**：Figma 高保真稿 `code.js` **未画媒体区**（21 个
/// builder 中搜 `媒体/图片/上传/0 / 9/carousel` 全零命中），故本段按仓库既有
/// **HTML 高保真原型** `prototype/index.html` 的 `.upload-area` 方案落地：
/// 2px 虚线添加入口 + 80×80 圆角缩略图 + 计数。
/// 用户 2026-10-11 裁定：本轮**仅图片**（视频 ≤3 待单列条目），故文案去掉
/// 「/ 视频」，不做拖拽（移动端为点按）。
///
/// **架构**：本组件**自持**上传条目（含本地字节与上传态），只把**已 commit 的
/// mediaId 列表**经 [onChanged] 上报给发布表单——表单不该承载「字节/进度」这类
/// UI 瞬态，只承载可提交的契约载荷。
///
/// **已知遗留**：契约无「删除媒体」端点，移除已 commit 的条目只从 `media_ids`
/// 摘除，服务端对象成孤儿（24h 定时清理只覆盖 `pending` 未 commit 记录）。
/// 该缺口属服务端 GC 议题，未在客户端伪造删除。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../media/media_picker.dart';
import '../media/media_upload_service.dart';
import 'publish_form_state.dart';

/// 单条上传条目（UI 瞬态）。
class _MediaUpload {
  _MediaUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  });

  /// 原始文件名。
  final String filename;

  /// 本地字节（缩略图直接用，不另存磁盘）。
  final Uint8List bytes;

  /// MIME 类型。
  final String contentType;

  /// 是否上传中。
  bool uploading = true;

  /// 是否已 commit 成功。
  bool done = false;

  /// 成功后的 mediaId。
  String? mediaId;

  /// 失败原因（用户可见）。
  String? error;
}

/// 媒体上传段。
class MediaSection extends ConsumerStatefulWidget {
  /// 构造媒体段。
  ///
  /// 参数：[onChanged] 已成功上传的 mediaId 列表变化回调；
  ///   [maxCount] 上限，默认 [kMaxImageCount]。
  const MediaSection({
    super.key,
    required this.onChanged,
    this.maxCount = kMaxImageCount,
  });

  /// 已成功上传的 mediaId 列表变化回调。
  final ValueChanged<List<String>> onChanged;

  /// 张数上限。
  final int maxCount;

  @override
  ConsumerState<MediaSection> createState() => _MediaSectionState();
}

class _MediaSectionState extends ConsumerState<MediaSection> {
  final List<_MediaUpload> _items = [];

  /// 正在选图（防重复触发系统图库）。
  bool _picking = false;

  /// 选图并逐张上传（**串行**：弱网下并发上传更易失败，且进度更可读）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _pickAndUpload() async {
    if (_picking) return;
    final remaining = widget.maxCount - _items.length;
    if (remaining <= 0) return;

    setState(() => _picking = true);
    try {
      final picked = await ref.read(mediaPickerProvider).pickImages(limit: remaining);
      for (final media in picked) {
        if (!mounted) return;
        final item = _MediaUpload(
          filename: media.filename,
          bytes: media.bytes,
          contentType: media.contentType,
        );
        setState(() => _items.add(item));
        await _upload(item);
      }
    } on MediaPickException catch (error) {
      _toast(error.userMessage);
    } catch (error) {
      _toast(asApiException(error).uiMessage);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 上传单条（失败不自动重试，交由用户点按重试——红线：前端唯一自动重试点是
  /// RetryInterceptor，features 内禁循环重试）。
  ///
  /// 参数：[item] 待上传条目。
  /// 返回：[Future<void>]。
  Future<void> _upload(_MediaUpload item) async {
    if (mounted) {
      setState(() {
        item.uploading = true;
        item.error = null;
      });
    }
    try {
      final uploaded = await ref.read(mediaUploadServiceProvider).upload(
            PickedMedia(
              filename: item.filename,
              bytes: item.bytes,
              contentType: item.contentType,
            ),
          );
      if (!mounted) return;
      setState(() {
        item.uploading = false;
        item.done = true;
        item.mediaId = uploaded.mediaId;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        item.uploading = false;
        item.done = false;
        item.mediaId = null;
        item.error = asApiException(error).uiMessage;
      });
    }
    _sync();
  }

  /// 移除条目（仅从列表摘除，见文件头「已知遗留」）。
  ///
  /// 参数：[item] 待移除条目。
  /// 返回：void。
  void _remove(_MediaUpload item) {
    setState(() => _items.remove(item));
    _sync();
  }

  /// 上报已 commit 的 mediaId 列表。
  ///
  /// 参数：无。
  /// 返回：void。
  void _sync() {
    widget.onChanged([
      for (final item in _items)
        if (item.done && item.mediaId != null) item.mediaId!,
    ]);
  }

  /// 弹出提示。
  ///
  /// 参数：[message] 文案。
  /// 返回：void。
  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final canAdd = _items.length < widget.maxCount && !_picking;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final item in _items)
              _Thumb(
                item: item,
                onRemove: () => _remove(item),
                onRetry: () => _upload(item),
              ),
            if (_items.length < widget.maxCount)
              _AddTile(enabled: canAdd, onTap: _pickAndUpload),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          '${_items.length} / ${widget.maxCount} · 支持图片',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: const Color(AppColors.textPlaceholder),
          ),
        ),
      ],
    );
  }
}

/// 缩略图槽（80×80，含上传中/失败态与移除角标）。
class _Thumb extends StatelessWidget {
  /// 构造缩略图槽。
  ///
  /// 参数：[item] 条目；[onRemove] 移除回调；[onRetry] 失败重试回调。
  const _Thumb({required this.item, required this.onRemove, required this.onRetry});

  /// 条目。
  final _MediaUpload item;

  /// 移除回调。
  final VoidCallback onRemove;

  /// 失败重试回调。
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _tileSize,
      height: _tileSize,
      child: Stack(
        children: [
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Image.memory(item.bytes, fit: BoxFit.cover),
            ),
          ),
          if (item.uploading)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  ),
                ),
              ),
            ),
          if (item.error != null)
            Positioned.fill(
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: onRetry,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(AppColors.error).withValues(alpha: 0.72),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.refresh, size: 20, color: Colors.white),
                        SizedBox(height: AppSpacing.xs),
                        Text(
                          '重试',
                          style: TextStyle(fontSize: 11, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            top: 0,
            right: 0,
            child: Material(
              color: Colors.black.withValues(alpha: 0.55),
              shape: const CircleBorder(),
              child: InkWell(
                onTap: onRemove,
                customBorder: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 14, color: Colors.white),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 添加槽（2px 虚线框 + 相机图标）。
class _AddTile extends StatelessWidget {
  /// 构造添加槽。
  ///
  /// 参数：[enabled] 是否可点（选中中或已达上限则禁用）；[onTap] 点按回调。
  const _AddTile({required this.enabled, required this.onTap});

  /// 是否可点。
  final bool enabled;

  /// 点按回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: CustomPaint(
          painter: _DashedBorderPainter(
            color: Color(enabled ? AppColors.textPlaceholder : AppColors.border),
            radius: AppRadius.md,
          ),
          child: SizedBox(
            width: _tileSize,
            height: _tileSize,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.photo_camera_outlined,
                  size: 22,
                  color: Color(enabled ? AppColors.textPlaceholder : AppColors.border),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '添加图片',
                  style: TextStyle(
                    fontSize: 11,
                    color: Color(enabled ? AppColors.textPlaceholder : AppColors.border),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 槽边长（HTML 原型 `.preview-item` 80×80）。
const double _tileSize = 80;

/// 虚线圆角边框（Flutter 无内置虚线，按 HTML 原型 2px dashed 自绘）。
class _DashedBorderPainter extends CustomPainter {
  /// 构造虚线边画笔。
  ///
  /// 参数：[color] 线色；[radius] 圆角。
  const _DashedBorderPainter({required this.color, required this.radius});

  /// 线色。
  final Color color;

  /// 圆角。
  final double radius;

  /// 虚线段长。
  static const double _dash = 5;

  /// 虚线间隔。
  static const double _gap = 4;

  /// 线宽（HTML 原型 2px dashed）。
  static const double _strokeWidth = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = _strokeWidth
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            _strokeWidth / 2,
            _strokeWidth / 2,
            size.width - _strokeWidth,
            size.height - _strokeWidth,
          ),
          Radius.circular(radius),
        ),
      );
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = distance + _dash;
        canvas.drawPath(metric.extractPath(distance, next.clamp(0, metric.length)), paint);
        distance = next + _gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
