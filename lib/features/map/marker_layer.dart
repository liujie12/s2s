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
import '../../domain/listing_category_style.dart';
import 'clustering/marker_builder.dart';

/// Marker 图层。
class MarkerLayer extends StatelessWidget {
  const MarkerLayer({
    super.key,
    required this.markers,
    required this.supplyDemandById,
    this.selectedListingId,
    this.onTapMarker,
  });

  /// 待渲染的 Marker（已含聚合判定，见 [buildMarkers]）。
  final List<MapMarker> markers;

  /// 信息 ID → 供需 —— 决定画实心圆还是空心圆 + ? 角标。
  ///
  /// 传**已建好的表**而非查询回调：回调很容易被实现成对原始列表的
  /// `firstWhere`，那样每画一个 Marker 就扫一遍全表，5 万点档位下是 O(n²)。
  /// 而这类开销发生在 `paint()` 内，真机上表现为掉帧，极易被误判成
  /// 「CustomPaint 画不动」，把优化引向降 Pin 上限这种错误方向。
  ///
  /// 用 Map 而非让 [MapMarker] 自带该字段：聚合模块无 Flutter 依赖、也不该
  /// 知道供需概念，让 `ClusterPoint` 多背一个字段会把业务语义漏进纯算法层。
  final Map<String, SupplyDemand> supplyDemandById;

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
          supplyDemandById: supplyDemandById,
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

/// 已完成整形的文本缓存。
///
/// **为什么必须缓存**：`TextPainter.layout()` 做的是完整的文字整形（字体查找、
///字形映射、度量），成本远高于 `paint()`。原实现每个 Marker 每帧新建一个
/// TextPainter，5 万点即每帧 5 万次整形 —— 实测单帧 2.48 秒，且每点耗时
/// 从 1 万点的 25.7µs 反弹到 5 万点的 49.7µs（超线性，来自大量短命对象的
/// GC 压力）。而实际组合极少：图标只有 5 分类 × 2 配色 × 2 尺寸。
///
/// **为什么是顶层而非 painter 字段**：`_MarkerPainter` 每帧都是新实例，
/// 挂在实例上等于没缓存。
///
/// **为什么有容量上限**：聚合数字的取值不封闭（1–999+），无上限则缓存会随
/// 用户浏览不断增长。超限直接清空而非 LRU：命中率在稳态下本就接近 1，
/// 维护 LRU 的成本高于偶尔重建一次。
final Map<_TextKey, TextPainter> _textCache = {};

const int _kTextCacheCapacity = 512;

/// 字体族要进键：图标走 MaterialIcons，数字走默认族，同一码位在两族下是
/// 完全不同的字形，漏掉它会让图标画成方框。
typedef _TextKey = ({
  String text,
  int color,
  double size,
  int weight,
  String? family,
});

TextPainter _cachedPainter({
  required String text,
  required Color color,
  required double fontSize,
  required FontWeight fontWeight,
  String? fontFamily,
  String? fontPackage,
}) {
  final key = (
    text: text,
    // 用 toARGB32 而非 Color 本身作键的一部分：Color 的 == 可用，但把值摊平
    // 成 int 能让 record 的哈希更廉价，而这里每帧要查几万次。
    color: color.toARGB32(),
    size: fontSize,
    // 用 value（100–900 的字重数值）而非已废弃的 index。
    weight: fontWeight.value,
    family: fontFamily,
  );
  final cached = _textCache[key];
  if (cached != null) return cached;

  if (_textCache.length >= _kTextCacheCapacity) _textCache.clear();

  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: color,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontFamily: fontFamily,
        package: fontPackage,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  _textCache[key] = painter;
  return painter;
}

class _MarkerPainter extends CustomPainter {
  _MarkerPainter({
    required this.markers,
    required this.supplyDemandById,
    required this.selectedListingId,
  });

  final List<MapMarker> markers;
  final Map<String, SupplyDemand> supplyDemandById;
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
    // 大类可空（分类树版本落后于服务端数据时查不到，§16.4 属预期内状态），
    // 此时用中性配色而**不是丢弃这个聚合圈** —— 丢弃会让用户觉得东西不见了。
    final category = marker.topCategory;
    final Color strokeColor = category?.color ?? neutralCategoryColor;
    final Color textColor = category?.deepColor ?? neutralCategoryColor;
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
        ..color = strokeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // 数字用 deepColor 而非原色：原色在白底上对比度不足 4.5:1（design_tokens.dart:74）。
    _paintCenteredText(
      canvas,
      center,
      text: marker.count > 999 ? '999+' : '${marker.count}',
      color: textColor,
      fontSize: marker.diameter >= 48 ? 16 : 13,
      fontWeight: FontWeight.w600,
    );
  }

  /// 单点 Marker：资源＝分类色实心 + 白图标；需求＝白底 + 分类色描边 + 分类色图标 + ? 角标。
  void _paintSinglePoint(Canvas canvas, SinglePointMarker marker) {
    final category = marker.topCategory;
    // 同 _paintCluster：查不到大类时降级为中性配色，Pin 仍然画出来。
    final Color pinColor = category?.color ?? neutralCategoryColor;
    final IconData pinIcon = category?.icon ?? neutralCategoryIcon;
    final isSelected = marker.listingId == selectedListingId;
    final double diameter = isSelected
        ? kSelectedMarkerDiameter
        : kSinglePointMarkerDiameter;
    final double radius = diameter / 2;
    final center = Offset(marker.x, marker.y);
    // 查不到按资源处理：Marker 的 listingId 来自同一批 listings，缺失说明
    // 两个入参不配套，是编码错误而非数据情况，故用 assert 暴露而不静默兜底。
    assert(
      supplyDemandById.containsKey(marker.listingId),
      '${marker.listingId} 不在 supplyDemandById 内，markers 与该表不是同一批数据',
    );
    final isSupply = supplyDemandById[marker.listingId] != SupplyDemand.demand;

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
      canvas.drawCircle(center, radius, Paint()..color = pinColor);
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
          ..color = pinColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }

    // 图标边长＝直径 × 0.5（PRD §6.4.2 配色规则）。
    _paintIcon(
      canvas,
      center,
      icon: pinIcon,
      size: diameter * 0.5,
      color: isSupply ? Color(AppColors.surface) : pinColor,
    );

    if (!isSupply) {
      // 需求态 ? 角标在右上，不占圆心 —— 圆心已被分类图标占用（PRD §6.4.2）。
      final badgeCenter = center.translate(radius * 0.7, -radius * 0.7);
      canvas.drawCircle(badgeCenter, 8, Paint()..color = pinColor);
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
    final painter = _cachedPainter(
      text: String.fromCharCode(icon.codePoint),
      color: color,
      fontSize: size,
      fontWeight: FontWeight.normal,
      fontFamily: icon.fontFamily,
      fontPackage: icon.fontPackage,
    );
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
    final painter = _cachedPainter(
      text: text,
      color: color,
      fontSize: fontSize,
      fontWeight: fontWeight,
    );
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
