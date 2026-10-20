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
import '../media/media_image_encoder.dart';
import '../media/media_picker.dart';
import '../media/media_upload_service.dart';
import 'publish_form_state.dart';

/// 拍后比例不匹配时的用户决定。
enum _AspectDecision { use, crop, reshoot }

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

class _MediaSectionState extends ConsumerState<MediaSection>
    with AutomaticKeepAliveClientMixin {
  final List<_MediaUpload> _items = [];

  /// 保持本段存活（真机缺陷修复）。
  ///
  /// 发布页是 `ListView` 懒构建，本段滚出可视区超出 cacheExtent 会被销毁，
  /// 而已上传列表 `_items` 只存在本 State 里 —— 用户上滚补标题/描述再滚回来，
  /// 缩略图会凭空变回 `0 / 9`，但父级 `_form.mediaIds` 仍是旧值，界面与提交态
  /// 不一致。上传成功的 mediaId 不能依赖父级回传重建（详情页 URL 只在
  /// `initialMedia` 里），故用 keep-alive 保住本段 State。
  ///
  /// 参数：无。
  /// 返回：恒为 true。
  @override
  bool get wantKeepAlive => true;

  /// 正在选图（防重复触发系统图库）。
  bool _picking = false;

  /// 本次发布会话内跳过拍后比例提示（连拍多张时避免逐张确认，见「本次不再提示」）。
  bool _skipAspectWarn = false;

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
        // 入列前归一化（方向烘焙 + 长边限幅 + 统一 JPEG）：相册原图可能带 EXIF
        // 方向，直接上传详情页会横躺。单张归一化失败不阻断后续图片。
        final PickedMedia normalized;
        try {
          normalized = await ref.read(mediaNormalizerProvider)(
            CropEncodeInput(bytes: media.bytes, filename: media.filename),
          );
        } on MediaPickException catch (error) {
          _toast(error.userMessage);
          continue;
        }
        if (!mounted) return;
        final item = _MediaUpload(
          filename: normalized.filename,
          bytes: normalized.bytes,
          contentType: normalized.contentType,
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

  /// 从系统相机拍一张并上传（相机优先的默认入口；单张）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> _captureFromCamera() async {
    if (_picking) return;
    final remaining = widget.maxCount - _items.length;
    if (remaining <= 0) return;

    setState(() => _picking = true);
    try {
      final picked = await _captureSingle();
      if (picked == null || !mounted) return; // 用户取消
      final item = _MediaUpload(
        filename: picked.filename,
        bytes: picked.bytes,
        contentType: picked.contentType,
      );
      setState(() => _items.add(item));
      await _upload(item);
    } on MediaPickException catch (error) {
      _toast(error.userMessage);
    } catch (_) {
      // 相机打不开（权限被拒 / 无摄像头 / 系统相机异常）：不套 API 异常（那会
      // 显示「未归一的异常形态」），给固定文案并保留「从相册选」出口，发布不被卡死。
      _toastCameraUnavailable();
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 拍一张并做拍后比例体检，返回确定要入列的图。
  ///
  /// 偏差在容忍阈值内静默通过；超阈值弹「重拍 / 按详情比例裁剪 / 仍然使用」三选一，
  /// 用户选重拍则循环重新拍摄，直到确定使用、裁剪完成或取消。
  ///
  /// 参数：无。
  /// 返回：[PickedMedia] 确定入列的图；用户取消返回 null。
  Future<PickedMedia?> _captureSingle() async {
    while (true) {
      final picked = await ref.read(mediaPickerProvider).pickFromCamera();
      if (picked == null) return null; // 用户取消拍摄

      switch (await _aspectDecisionFor(picked)) {
        case _AspectDecision.use:
          // 「仍然使用」的是相机原图：入列前归一化（方向烘焙 + 长边限幅 + JPEG）。
          // 「裁剪」分支由 ImageCropScreen 内部已归一化，不在此二次处理。
          return ref.read(mediaNormalizerProvider)(
            CropEncodeInput(bytes: picked.bytes, filename: picked.filename),
          );
        case _AspectDecision.crop:
          final cropped = await _cropPicked(picked);
          if (cropped != null) return cropped;
          return null; // 裁剪页取消 → 整次拍摄取消
        case _AspectDecision.reshoot:
          continue; // 重新拍
      }
    }
  }

  /// 判定拍后比例是否需提示，返回用户最终决定。
  ///
  /// 参数：[picked] 拍摄结果。
  /// 返回：[_AspectDecision] 使用 / 裁剪 / 重拍。
  Future<_AspectDecision> _aspectDecisionFor(PickedMedia picked) async {
    // 用户已选「本次不再提示」：后续拍摄直接放行，不再逐张确认。
    if (_skipAspectWarn) return _AspectDecision.use;

    final ImageSize? size;
    try {
      size = await ref.read(imageSizeReaderProvider)(picked.bytes);
    } catch (_) {
      return _AspectDecision.use; // 读宽高失败不阻塞，图仍可上传
    }
    if (size == null || size.height == 0) return _AspectDecision.use;
    // async gap 后使用 context 前的守卫：读宽高走 isolate，await 返回时组件可能已销毁。
    if (!mounted) return _AspectDecision.use;

    final mismatched = aspectMismatchExceeds(
      width: size.width,
      height: size.height,
      targetAspect: detailMediaAspectRatio(context),
      tolerance: kAspectMismatchTolerance,
    );
    if (!mismatched) return _AspectDecision.use;

    return _showAspectMismatchSheet();
  }

  /// 复用裁剪入口裁剪一张尚未入列的拍摄结果。
  ///
  /// 参数：[source] 待裁剪图。
  /// 返回：裁剪后的图；用户取消返回 null。
  Future<PickedMedia?> _cropPicked(PickedMedia source) {
    return ref.read(mediaCropLauncherProvider)(
      context,
      source: source,
      aspectRatio: detailMediaAspectRatio(context),
    );
  }

  /// 拍后比例不匹配的三选一提示。
  ///
  /// 参数：无。
  /// 返回：[_AspectDecision] 用户选择；下滑关闭视为「仍然使用」。
  Future<_AspectDecision> _showAspectMismatchSheet() async {
    final decision = await showModalBottomSheet<_AspectDecision>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '这张照片的比例和详情页不一致',
                style: TextStyle(
                  fontSize: AppTypeScale.h3.size,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.textPrimary),
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '不裁剪也能发布，但详情页边缘会显示模糊留白。',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              _SheetAction(
                icon: Icons.photo_camera_outlined,
                label: '重拍',
                onTap: () =>
                    Navigator.pop(sheetContext, _AspectDecision.reshoot),
              ),
              const SizedBox(height: AppSpacing.xs),
              _SheetAction(
                icon: Icons.crop,
                label: '按详情比例裁剪',
                onTap: () => Navigator.pop(sheetContext, _AspectDecision.crop),
              ),
              const SizedBox(height: AppSpacing.xs),
              _SheetAction(
                icon: Icons.check,
                label: '仍然使用（保留原图）',
                onTap: () => Navigator.pop(sheetContext, _AspectDecision.use),
              ),
              // 连拍场景的退出阀：记住本次不再提示，且等同于「仍然使用」。
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  onPressed: () {
                    _skipAspectWarn = true;
                    Navigator.pop(sheetContext, _AspectDecision.use);
                  },
                  child: const Text('本次发布不再提示'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return decision ?? _AspectDecision.use;
  }

  /// 相机不可用时的降级提示：固定文案 + 「从相册选」动作。
  ///
  /// 参数：无。
  /// 返回：void。
  void _toastCameraUnavailable() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('无法打开相机，请从相册选择照片'),
        action: SnackBarAction(
          label: '从相册选',
          onPressed: _pickAndUpload,
        ),
      ),
    );
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
    // AutomaticKeepAliveClientMixin 要求先调用 super.build 才会登记保活。
    super.build(context);
    final canAdd = _items.length < widget.maxCount && !_picking;
    final isEmpty = _items.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isEmpty)
          _EmptyEntry(
            enabled: canAdd,
            onCamera: _captureFromCamera,
            onAlbum: _pickAndUpload,
          )
        else
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (var i = 0; i < _items.length; i++)
                _Thumb(
                  item: _items[i],
                  isCover: i == 0,
                  onRemove: () => _remove(_items[i]),
                  onRetry: () => _upload(_items[i]),
                  // 只有仍有本地字节、不在上传中、且没有待重试错误的条目才能裁剪：
                  // 上传中替换会让在途请求的结果落到已丢弃的对象上；失败态整块是
                  // 「重试」按钮，再叠裁剪入口会互相抢点击。
                  onCrop: _items[i].bytes != null &&
                          !_items[i].uploading &&
                          _items[i].error == null
                      ? () => _crop(_items[i])
                      : null,
                ),
              if (_items.length < widget.maxCount)
                _AddTile(enabled: canAdd, onTap: _captureFromCamera),
            ],
          ),
        // 非空态补一个「从相册选更多」的文字入口，与「继续拍」并列为两种来源。
        // 用 Align 收起点击区域：Column 是 stretch，直接放 InkWell 会整行可点。
        if (!isEmpty && canAdd)
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              onTap: _pickAndUpload,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.photo_library_outlined,
                      size: 16,
                      color: Color(AppColors.primary),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      '从相册选更多',
                      style: TextStyle(
                        fontSize: AppTypeScale.small.size,
                        color: Color(AppColors.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          isEmpty
              ? '${_items.length} / ${widget.maxCount} · 支持图片'
              : '${_items.length} / ${widget.maxCount} · 第 1 张为详情封面',
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
    required this.isCover,
    required this.onRemove,
    required this.onRetry,
    required this.onCrop,
  });

  /// 条目。
  final _MediaUpload item;

  /// 是否为封面（列表第 1 张，即详情轮播首图）。
  final bool isCover;

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
              // 封面标识（第 1 张）：把服务端「封面 = id 升序首条」的隐式规则
              // 显式化，避免用户删掉第 1 张时毫无预警地换封面。
              if (isCover)
                Positioned(
                  top: 0,
                  left: 0,
                  child: DecoratedBox(
                    decoration: const BoxDecoration(
                      color: Color(0x8C000000),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(AppRadius.md),
                        bottomRight: Radius.circular(AppRadius.md),
                      ),
                    ),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.xs,
                        vertical: 2,
                      ),
                      child: Text(
                        '封面',
                        style: TextStyle(
                          fontSize: AppTypeScale.caption.size,
                          color: Colors.white,
                        ),
                      ),
                    ),
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

/// 空态来源入口：拍照主按钮 + 相册次按钮。
class _EmptyEntry extends StatelessWidget {
  const _EmptyEntry({
    required this.enabled,
    required this.onCamera,
    required this.onAlbum,
  });

  /// 是否可点（选中中或已达上限则禁用）。
  final bool enabled;

  /// 拍照回调。
  final VoidCallback onCamera;

  /// 相册回调。
  final VoidCallback onAlbum;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: _EntryButton(
            enabled: enabled,
            filled: true,
            onTap: onCamera,
            icon: Icons.photo_camera_outlined,
            label: '拍照',
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: _EntryButton(
            enabled: enabled,
            filled: false,
            onTap: onAlbum,
            icon: Icons.photo_library_outlined,
            label: '相册',
          ),
        ),
      ],
    );
  }
}

/// 空态来源入口按钮：[filled] 为真时实心主按钮，否则描边次按钮。
class _EntryButton extends StatelessWidget {
  const _EntryButton({
    required this.enabled,
    required this.filled,
    required this.onTap,
    required this.icon,
    required this.label,
  });

  /// 是否可点。
  final bool enabled;

  /// 是否实心（主按钮）。
  final bool filled;

  /// 点按回调。
  final VoidCallback onTap;

  /// 图标。
  final IconData icon;

  /// 文案。
  final String label;

  @override
  Widget build(BuildContext context) {
    final Color foreground;
    final Color background;
    if (filled) {
      foreground = Colors.white;
      background = const Color(AppColors.primary);
    } else {
      foreground = const Color(AppColors.primary);
      background = const Color(AppColors.surface);
    }
    return Material(
      color: enabled ? background : const Color(AppColors.border),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        side: filled
            ? BorderSide.none
            : BorderSide(
                color: Color(enabled ? AppColors.primary : AppColors.border),
              ),
      ),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: SizedBox(
          height: 48,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: enabled
                    ? foreground
                    : const Color(AppColors.textPlaceholder),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                  color: enabled
                      ? foreground
                      : const Color(AppColors.textPlaceholder),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 拍后比例三选一里的动作项。
class _SheetAction extends StatelessWidget {
  const _SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  /// 图标。
  final IconData icon;

  /// 文案。
  final String label;

  /// 点按回调。
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(AppColors.background),
      borderRadius: BorderRadius.circular(AppRadius.lg),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.md,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: const Color(AppColors.primary)),
              const SizedBox(width: AppSpacing.sm),
              Text(
                label,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textPrimary),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 继续拍槽（2px 虚线框 + 相机图标）：非空态追加拍摄入口。
class _AddTile extends StatelessWidget {
  /// 构造继续拍槽。
  ///
  /// 参数：[enabled] 是否可点（选中中或已达上限则禁用）；[onTap] 点按回调（拍摄）。
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
                  '继续拍',
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
