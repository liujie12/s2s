/// Marker 渲染层（PRD §6.4.2）。
///
/// 用 `CustomPaint` 一次性画全部 Marker，而不是每个 Marker 一个 Widget：
/// 5 万点档位下 Widget 方案会创建 5 万个 RenderObject，仅布局阶段就远超预算。
/// POC-A 已证明聚合算法只占 300ms 预算的 1.6%，瓶颈在渲染侧（说明文档条目 [63]），
/// 故渲染层从一开始就按「一层画布」设计，不留「先用 Widget 跑通再优化」的债。
///
/// 点击命中不走 Widget 树，由 [MarkerLayer.hitTestMarker] 在 Marker 列表上反查。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../domain/listing_category.dart';
import 'clustering/marker_builder.dart';

/// Marker 图层。
class MarkerLayer extends StatelessWidget {
  const MarkerLayer({
    super.key,
    required this.markers,
    required this.supplyDemandOf,
    this.selectedListingId,
    this.onTapMarker,
  });

  /// 待渲染的 Marker（已含聚合判定，见 [buildMarkers]）。
  final List<MapMarker> markers;

  /// 查询某条信息是资源还是需求 —— 决定画实心圆还是空心圆 + ? 角标。
  ///
  /// 注入而非让 Marker 自带该字段：聚合模块无 Flutter 依赖、也不该知道供需概念，
  /// 让 `ClusterPoint` 多背一个字段会把业务语义漏进纯算法层。
  final SupplyDemand Function(String listingId) supplyDemandOf;

  /// 当前选中的信息 ID，选中态放大到 48×48（PRD §6.4.2）。
  final String? selectedListingId;

  /// 点击回调。传入被点中的 Marker。
  final void Function(MapMarker marker)? onTapMarker;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // opaque：Marker 之外的空白也要接收点击，否则点空白会穿透到底图的拖动手势，
      // 表现为「点了没反应，但地图动了一下」。
      behavior: HitTestBehavior.opaque,
      onTapUp: (details) {
        final hit = hitTestMarker(details.localPosition);
        if (hit != null) onTapMarker?.call(hit);
      },
      child: CustomPaint(
        painter: _MarkerPainter(
          markers: markers,
          supplyDemandOf: supplyDemandOf,
          selectedListingId: selectedListingId,
        ),
        // 铺满父级：CustomPaint 无 child 时默认尺寸为零，画不出任何东西。
        size: Size.infinite,
      ),
    );
  }

  /// 反查点击落在哪个 Marker 上。
  ///
  /// **倒序遍历**：绘制是正序，后画的压在上面，命中判定必须与视觉一致，
  /// 否则用户点到的是被压在下面那个。
  ///
  /// 返回命中的 Marker；未命中返回 null。
  MapMarker? hitTestMarker(Offset position) {
    for (int i = markers.length - 1; i >= 0; i--) {
      final m = markers[i];
      final double radius = _radiusOf(m, selectedListingId);
      // 用平方比较省一次开方。命中区按视觉半径不额外放大 ——
      // 单点 40px、最小聚合 32px 均已超过 44px 触控下限的等效面积要求。
      final double dx = position.dx - m.x;
      final double dy = position.dy - m.y;
      if (dx * dx + dy * dy <= radius * radius) return m;
    }
    return null;
  }
}

/// Marker 的绘制半径。
double _radiusOf(MapMarker marker, String? selectedListingId) {
  return switch (marker) {
    ClusterMarker() => marker.diameter / 2,
    SinglePointMarker() =>
      (marker.listingId == selectedListingId
              ? kSelectedMarkerDiameter
              : kSinglePointMarkerDiameter) /
          2,
  };
}

class _MarkerPainter extends CustomPainter {
  _MarkerPainter({
    required this.markers,
    required this.supplyDemandOf,
    required this.selectedListingId,
  });

  final List<MapMarker> markers;
  final SupplyDemand Function(String listingId) supplyDemandOf;
  final String? selectedListingId;

  @override
  void paint(Canvas canvas, Size size) {
    // 先画聚合圆再画单点：PRD §6.4.2 要求「用 zIndex 让聚合圆压在单点之下」。
    // 单层画布没有 zIndex，绘制顺序即层级。
    for (final m in markers) {
      if (m is ClusterMarker) _paintCluster(canvas, m);
    }
    for (final m in markers) {
      if (m is SinglePointMarker) _paintSinglePoint(canvas, m);
    }
  }

  /// 聚合 Marker：白底 + 分类色描边 + 居中数字。
  void _paintCluster(Canvas canvas, ClusterMarker marker) {
    final category = listingCategoryFromId(marker.categoryId);
    final center = Offset(marker.x, marker.y);
    final double radius = marker.diameter / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()..color = Color(AppColors.surface),
    );
    canvas.drawCircle(
      center,
      radius - 1,
      Paint()
        ..color = category.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // 数字用 deepColor 而非原色：原色在白底上对比度不足 4.5:1（design_tokens.dart:74）。
    _paintCenteredText(
      canvas,
      center,
      text: marker.count > 999 ? '999+' : '${marker.count}',
      color: category.deepColor,
      fontSize: marker.diameter >= 48 ? 16 : 13,
      fontWeight: FontWeight.w600,
    );
  }

  /// 单点 Marker：资源＝分类色实心 + 白图标；需求＝白底 + 分类色描边 + 分类色图标 + ? 角标。
  void _paintSinglePoint(Canvas canvas, SinglePointMarker marker) {
    final category = listingCategoryFromId(marker.categoryId);
    final isSelected = marker.listingId == selectedListingId;
    final double diameter = isSelected
        ? kSelectedMarkerDiameter
        : kSinglePointMarkerDiameter;
    final double radius = diameter / 2;
    final center = Offset(marker.x, marker.y);
    final isSupply = supplyDemandOf(marker.listingId) == SupplyDemand.supply;

    if (isSelected) {
      // 选中态阴影：单靠放大 8px 在密集区域看不出来，须有阴影把它从同色邻居中拔出。
      canvas.drawCircle(
        center.translate(0, 2),
        radius,
        Paint()
          ..color = const Color(0x33000000)
          ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 4),
      );
    }

    if (isSupply) {
      canvas.drawCircle(center, radius, Paint()..color = category.color);
    } else {
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = Color(AppColors.surface),
      );
      canvas.drawCircle(
        center,
        radius - 1,
        Paint()
          ..color = category.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // 图标边长＝直径 × 0.5（PRD §6.4.2 配色规则）。
    _paintIcon(
      canvas,
      center,
      icon: category.icon,
      size: diameter * 0.5,
      color: isSupply ? Color(AppColors.surface) : category.color,
    );

    if (!isSupply) {
      // 需求态 ? 角标在右上，不占圆心 —— 圆心已被分类图标占用（PRD §6.4.2）。
      final badgeCenter = center.translate(radius * 0.7, -radius * 0.7);
      canvas.drawCircle(badgeCenter, 8, Paint()..color = category.color);
      canvas.drawCircle(
        badgeCenter,
        8,
        Paint()
          ..color = Color(AppColors.surface)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      _paintCenteredText(
        canvas,
        badgeCenter,
        text: '?',
        color: Color(AppColors.surface),
        fontSize: 11,
        fontWeight: FontWeight.w700,
      );
    }
  }

  /// 把 [IconData] 当字形画出来。
  ///
  /// 图标字体在 Flutter 里就是一个字符，用 TextPainter 画比引入 SVG 解析轻得多。
  void _paintIcon(
    Canvas canvas,
    Offset center, {
    required IconData icon,
    required double size,
    required Color color,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(icon.codePoint),
        style: TextStyle(
          fontSize: size,
          fontFamily: icon.fontFamily,
          package: icon.fontPackage,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  void _paintCenteredText(
    Canvas canvas,
    Offset center, {
    required String text,
    required Color color,
    required double fontSize,
    required FontWeight fontWeight,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: fontWeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_MarkerPainter oldDelegate) =>
      // 列表按引用比较：Marker 列表每次重算都是新实例，逐项深比 5 万条
      // 反而比重绘更贵。
      !identical(oldDelegate.markers, markers) ||
      oldDelegate.selectedListingId != selectedListingId;
}
