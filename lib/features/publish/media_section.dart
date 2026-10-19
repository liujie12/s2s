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
/// 该缺口属服务端 GC 议题，未在客户端伪造删除；已上传条目再次裁剪同样会以
/// 新对象替换旧对象，旧对象落入同一缺口。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../media/media_cropper.dart';
import '../media/media_display_layout.dart';
import '../media/media_picker.dart';
import '../media/media_upload_service.dart';
import 'publish_form_state.dart';

/// 单条上传条目（UI 瞬态）。
class _MediaUpload {
  _MediaUpload({
    required this.filename,
    required this.bytes,
    required this.contentType,
  }) : remoteUrl = null;

  /// 编辑既有帖：直接以服务端已 commit 的媒体构造（无本地字节，缩略图走 URL）。
  ///
  /// 参数：
  /// - [mediaId] 已 commit 的媒体 ID；
  /// - [remoteUrl] 访问地址（限时签名 URL；重发态无 URL 时传空串，显示占位图标）。
  _MediaUpload.remote({required this.mediaId, required this.remoteUrl})
      : filename = '',
        bytes = null,
        contentType = 'image/jpeg',
        uploading = false,
        done = true;

  /// 原始文件名。
  final String filename;

  /// 本地字节（缩略图直接用，不另存磁盘）；远程既有媒体为 null。
  final Uint8List? bytes;

  /// MIME 类型。
  final String contentType;

  /// 远程访问地址（既有媒体回显用；本地新选媒体为 null）。
  final String? remoteUrl;

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
  /// 参数：
  /// - [onChanged] 已成功上传的 mediaId 列表变化回调；
  /// - [initialMedia] 既有媒体（编辑/重发态回显），默认空；
  /// - [maxCount] 上限，默认 [kMaxImageCount]。
  const MediaSection({
    super.key,
    required this.onChanged,
    this.initialMedia = const <({String mediaId, String url})>[],
    this.maxCount = kMaxImageCount,
  });

  /// 已成功上传的 mediaId 列表变化回调。
  final ValueChanged<List<String>> onChanged;

  /// 既有媒体（编辑/重发态回显）。
  ///
  /// 编辑态由 `GET /posts/{id}` 的 `media[]` 映射而来：`mediaId` 用于上报，
  /// `url` 用于缩略图。重发态的克隆草稿只回 `media_ids`、没有 URL，传空串即可
  /// （缩略图退化为占位图标，计数与提交载荷仍正确）。
  final List<({String mediaId, String url})> initialMedia;

  /// 张数上限。
  final int maxCount;

  @override
  ConsumerState<MediaSection> createState() => _MediaSectionState();
}

class _MediaSectionState extends ConsumerState<MediaSection> {
  final List<_MediaUpload> _items = [];

  /// 正在选图（防重复触发系统图库）。
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    // 既有媒体先入列：编辑态进入页面即回显，且后续新增图片时 `_sync`
    // 会把「既有 + 新增」一起上报，不会把原媒体 ID 冲掉。
    _items.addAll([
      for (final media in widget.initialMedia)
        _MediaUpload.remote(mediaId: media.mediaId, remoteUrl: media.url),
    ]);
  }

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

  /// 裁剪单张本地图片（可选入口；取消返回 null 时什么都不做）。
  ///
  /// 裁剪结果会替换原条目并重新上传：`crop_your_image` 输出 PNG，媒体段拿到
  /// 的是已归一化的 JPEG 字节。已上传条目会丢失旧 mediaId（见文件头遗留说明）。
  ///
  /// 参数：[item] 待裁剪条目（必须仍有本地字节且不在上传中）。
  /// 返回：[Future<void>]。
  Future<void> _crop(_MediaUpload item) async {
    final bytes = item.bytes;
    if (bytes == null || item.uploading) return;

    final cropped = await ref.read(mediaCropLauncherProvider)(
      context,
      source: PickedMedia(
        filename: item.filename,
        bytes: bytes,
        contentType: item.contentType,
      ),
      aspectRatio: detailMediaAspectRatio(context),
    );
    if (cropped == null || !mounted) return;

    final index = _items.indexOf(item);
    if (index < 0) return;
    final replacement = _MediaUpload(
      filename: cropped.filename,
      bytes: cropped.bytes,
      contentType: cropped.contentType,
    );
    setState(() => _items[index] = replacement);
    // 立刻把旧 mediaId 从表单摘掉：否则用户在重传完成前点发布，会把「未裁剪
    // 的旧图」静默提交，与用户刚做的裁剪动作相反。
    _sync();
    await _upload(replacement);
  }

  /// 上传单条（失败不自动重试，交由用户点按重试——红线：前端唯一自动重试点是
  /// RetryInterceptor，features 内禁循环重试）。
  ///
  /// 参数：[item] 待上传条目。
  /// 返回：[Future<void>]。
  Future<void> _upload(_MediaUpload item) async {
    final bytes = item.bytes;
    // 远程既有媒体不会走上传（只有本地新选条目有字节）。
    if (bytes == null) return;
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
              bytes: bytes,
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
                // 只有仍有本地字节、不在上传中、且没有待重试错误的条目才能裁剪：
                // 上传中替换会让在途请求的结果落到已丢弃的对象上；失败态整块是
                // 「重试」按钮，再叠裁剪入口会互相抢点击。
                onCrop: item.bytes != null &&
                        !item.uploading &&
                        item.error == null
                    ? () => _crop(item)
                    : null,
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
        // 只在存在可裁剪的本地图片时提示：编辑态的远程既有媒体没有本地字节，
        // 提示了也点不了，反而制造「功能坏了」的错觉。
        if (_items.any((item) => item.bytes != null))
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Row(
              children: [
                const Icon(
                  Icons.content_cut,
                  size: 12,
                  color: Color(AppColors.textPlaceholder),
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '点按缩略图可裁剪，详情页展示更美观（可选）',
                    style: TextStyle(
                      fontSize: AppTypeScale.small.size,
                      color: const Color(AppColors.textPlaceholder),
                    ),
                  ),
                ),
              ],
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
  /// 参数：[item] 条目；[onRemove] 移除回调；[onRetry] 失败重试回调；
  ///   [onCrop] 裁剪回调（null 表示该条不可裁剪/正在上传）。
  const _Thumb({
    required this.item,
    required this.onRemove,
    required this.onRetry,
    required this.onCrop,
  });

  /// 条目。
  final _MediaUpload item;

  /// 移除回调。
  final VoidCallback onRemove;

  /// 失败重试回调。
  final VoidCallback onRetry;

  /// 裁剪回调（null 表示不可裁剪）。
  final VoidCallback? onCrop;

  /// 构建缩略图内容。
  ///
  /// 优先级：本地字节（新选媒体）> 远程签名 URL（编辑态既有媒体）> 占位图标
  /// （重发态只有 media_id、没有 URL）。网络图加载失败同样退化为占位，避免
  /// 编辑页出现整块红色报错。
  ///
  /// 返回：铺满 80×80 槽的图片或占位控件。
  Widget _buildImage() {
    final bytes = item.bytes;
    if (bytes != null) return Image.memory(bytes, fit: BoxFit.cover);
    final url = item.remoteUrl;
    if (url == null || url.isEmpty) {
      return const ColoredBox(
        color: Color(AppColors.background),
        child: Center(
          child: Icon(
            Icons.image_outlined,
            color: Color(AppColors.textPlaceholder),
          ),
        ),
      );
    }
    return Image.network(
      url,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => const ColoredBox(
        color: Color(AppColors.background),
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            color: Color(AppColors.textPlaceholder),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: onCrop != null,
      label: onCrop != null ? '裁剪这张图片' : null,
      child: GestureDetector(
        onTap: onCrop,
        // 图片只铺满槽内，不用 opaque 的话点边缘空白不会触发裁剪。
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: _tileSize,
          height: _tileSize,
          child: Stack(
            children: [
              Positioned.fill(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: _buildImage(),
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
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
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
                          color: const Color(AppColors.error)
                              .withValues(alpha: 0.72),
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
              // 裁剪角标：让「点缩略图可裁剪」有可见的入口线索，而不是只靠
              // 下方一行文字提示。
              if (onCrop != null)
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0x8C000000),
                      borderRadius: BorderRadius.only(
                        topRight: Radius.circular(AppRadius.md),
                        bottomLeft: Radius.circular(AppRadius.md),
                      ),
                    ),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(
                        Icons.content_cut,
                        size: 12,
                        color: Colors.white,
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
        ),
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
