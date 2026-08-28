/// 降级底图（PRD:1207「地图加载失败：降级为模拟地图，白底线框 + 道路模拟」）。
///
/// 它有两个用途，都不是「临时凑数」：
/// ① 高德 Key 未配置或加载失败时的兜底 —— 地图不可用不该阻塞发现，
///    用户仍能看到 Pin 的相对分布并点开详情；
/// ② 隐私协议未同意时的替代渲染 —— 此时**绝对不能**构建 `AMapWidget`
///    （见 amap_init_guard.dart 文件头的 SDK 实测结论）。
///
/// 刻意画成明显的「示意图」而非仿真地图：若画得像真地图，用户会按真实地理位置
/// 去理解 Pin 的落点，而这里的路网是程序生成的、与现实无关，误导比空白更糟。
/// 故底部有一条明示条说明这是示意底图。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import 'map_projection.dart';

/// 降级底图画布。
class FallbackMapCanvas extends StatelessWidget {
  const FallbackMapCanvas({super.key, required this.projection, this.notice});

  /// 当前投影，用于画比例尺与让路网随缩放变化。
  final MapProjection projection;

  /// 明示条文案。为 null 时不显示明示条（例如上层已经用别的方式说明了）。
  final String? notice;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(painter: _FallbackMapPainter(projection: projection)),
        if (notice != null)
          Positioned(
            left: AppSpacing.md,
            right: AppSpacing.md,
            bottom: AppSpacing.md,
            child: _NoticeBar(text: notice!),
          ),
        Positioned(
          right: AppSpacing.md,
          bottom: notice == null
              ? AppSpacing.md
              : AppSpacing.xxl + AppSpacing.lg,
          child: _ScaleBar(projection: projection),
        ),
      ],
    );
  }
}

/// 底图明示条。
///
/// 用半透明深色底而非纯色卡：它压在底图上，纯白卡会与底图的白抢边界，
/// 而深色底能保证在任何底图内容上都可读。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: Color(AppColors.textPrimary).withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.info_outline, size: 16, color: Colors.white),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: AppTypeScale.small.size,
                height: AppTypeScale.small.lineHeight,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 比例尺。
///
/// 降级底图上没有真实地物可供估距，比例尺是用户判断「5km 到底多远」的唯一依据，
/// 因此不是装饰件。
class _ScaleBar extends StatelessWidget {
  const _ScaleBar({required this.projection});

  final MapProjection projection;

  @override
  Widget build(BuildContext context) {
    final bar = projection.scaleBar();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          bar.label,
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: 2),
        Container(
          width: bar.pixels,
          height: 3,
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: Color(AppColors.textSecondary), width: 1),
              right: BorderSide(
                color: Color(AppColors.textSecondary),
                width: 1,
              ),
              bottom: BorderSide(
                color: Color(AppColors.textSecondary),
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 路网与街区的程序化绘制。
class _FallbackMapPainter extends CustomPainter {
  _FallbackMapPainter({required this.projection});

  final MapProjection projection;

  /// 主干道间距（米）。按米而非像素定义，缩放时路网才会跟着疏密变化，
  /// 否则无论放大多少倍路网都一样密，一眼看出是贴图。
  static const double _majorRoadSpacingMeters = 1000;

  /// 每个主干道格内的支路条数。
  static const int _minorRoadsPerBlock = 3;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = Color(AppColors.background),
    );

    final double majorSpacing =
        _majorRoadSpacingMeters / projection.metersPerPixel;
    // 缩得太小时路网会糊成实心块，此时只画主干道。
    final bool drawMinor = majorSpacing > 120;
    final double minorSpacing = majorSpacing / (_minorRoadsPerBlock + 1);

    final minorPaint = Paint()
      ..color = Color(AppColors.border)
      ..strokeWidth = 1;
    final majorPaint = Paint()
      ..color = Color(AppColors.border)
      ..strokeWidth = 3;

    if (drawMinor) {
      _drawGrid(canvas, size, minorSpacing, minorPaint);
    }
    _drawGrid(canvas, size, majorSpacing, majorPaint);
  }

  /// 画一层等间距网格线。
  ///
  /// 相位跟着投影中心走（对 spacing 取模），这样拖动地图时路网会跟着平移，
  /// 而不是固定在屏幕上、让人觉得 Pin 在网格上滑动。
  void _drawGrid(Canvas canvas, Size size, double spacing, Paint paint) {
    if (spacing <= 0 || !spacing.isFinite) return;

    final double phaseX =
        (projection.centerLng * 100000 / projection.metersPerPixel) % spacing;
    final double phaseY =
        (projection.centerLat * 100000 / projection.metersPerPixel) % spacing;

    for (double x = -phaseX; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = -phaseY; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_FallbackMapPainter oldDelegate) =>
      oldDelegate.projection != projection;
}
