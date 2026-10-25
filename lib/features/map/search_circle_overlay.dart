/// 搜索圈覆盖层（地图语音语义搜索 U7，方案 R8/R10）。
///
/// 用 Dart 侧投影自绘而不挂高德原生 `Circle`：Pin 本来就是 Flutter 覆盖层、
/// 坐标由 [MapProjection] 每帧同步算出（见 map_screen 的投影自持说明）。
/// 若搜索圈走原生覆盖物，拖动时圈与 Pin 分别由两条链路更新，会出现半帧错位；
/// 自绘还能让降级底图（无 Key）同样可用。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import 'map_projection.dart';

/// 搜索圈覆盖层。
class SearchCircleOverlay extends StatelessWidget {
  /// 构造搜索圈。
  ///
  /// 参数：
  /// - [projection] 当前视口投影；
  /// - [anchorLat]/[anchorLng] 圆心（GCJ-02）；
  /// - [radiusMeters] 真实半径米数。
  const SearchCircleOverlay({
    super.key,
    required this.projection,
    required this.anchorLat,
    required this.anchorLng,
    required this.radiusMeters,
  });

  /// 当前视口投影。
  final MapProjection projection;

  /// 圆心纬度。
  final double anchorLat;

  /// 圆心经度。
  final double anchorLng;

  /// 真实半径米数。
  final int radiusMeters;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size(
          projection.viewportSize.width,
          projection.viewportSize.height,
        ),
        painter: _SearchCirclePainter(
          projection: projection,
          anchorLat: anchorLat,
          anchorLng: anchorLng,
          radiusMeters: radiusMeters,
        ),
      ),
    );
  }
}

/// 搜索圈画笔：圈外压暗 + 圈边描线。
class _SearchCirclePainter extends CustomPainter {
  /// 构造画笔。
  ///
  /// 参数同 [SearchCircleOverlay]。
  const _SearchCirclePainter({
    required this.projection,
    required this.anchorLat,
    required this.anchorLng,
    required this.radiusMeters,
  });

  /// 视口投影。
  final MapProjection projection;

  /// 圆心纬度。
  final double anchorLat;

  /// 圆心经度。
  final double anchorLng;

  /// 真实半径米数。
  final int radiusMeters;

  @override
  void paint(Canvas canvas, Size size) {
    final center = projection.toPixel(anchorLat, anchorLng);
    final radiusPx = radiusMeters / projection.metersPerPixel;
    // 半径小于 1px 时画不出可见圈，直接不画（避免整屏压暗却看不出原因）。
    if (radiusPx < 1) return;

    final circle = Path()
      ..addOval(Rect.fromCircle(center: Offset(center.x, center.y), radius: radiusPx));
    final outside = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final dim = Path.combine(PathOperation.difference, outside, circle);

    canvas.drawPath(
      dim,
      Paint()
        ..color = const Color(0xFF1F2937).withValues(alpha: 0.28)
        ..style = PaintingStyle.fill,
    );
    canvas.drawPath(
      circle,
      Paint()
        ..color = const Color(AppColors.primary)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SearchCirclePainter oldDelegate) =>
      oldDelegate.projection.centerLat != projection.centerLat ||
      oldDelegate.projection.centerLng != projection.centerLng ||
      oldDelegate.projection.metersPerPixel != projection.metersPerPixel ||
      oldDelegate.anchorLat != anchorLat ||
      oldDelegate.anchorLng != anchorLng ||
      oldDelegate.radiusMeters != radiusMeters;
}
