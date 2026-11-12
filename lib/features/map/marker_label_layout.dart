/// 地图类目名称标签的贪心布局（R5 / R6 / KTD4 / KTD6）。
///
/// **为什么是纯函数**：布局只依赖「候选标签 + 可见区域 + 文字尺寸」，不读任何
/// 逐帧状态、不查分类树、不碰绘制缓存。这样它能在单测里直接跑，也不必担心
/// 放进 `paint()` 后每帧重算 —— 调用方（地图装配段）在相机停稳后算一次，
/// 拖动期间复用结果并随图层整体平移（R10）。
///
/// **为什么不做边缘吸附 / 引线**：R5 的口径是「放不下就不标」。为了多塞几个标签
/// 而把标签挪到离 Pin 很远的地方，用户会把标签认成别的点；缩小字号或裁切文字
/// 则直接违反 R6。
library;

import 'dart:ui';

import '../../design_tokens.dart';
import 'clustering/marker_builder.dart';

/// 一个候选标签：名称与色点在装配期已解析好，布局只负责定位。
///
/// 名称不由本模块解析：分类树查询属装配期职责，渲染 / 布局层不该再查一遍
/// 分类树（KTD3），否则每帧多一次查表且职责倒挂。
class MarkerLabelCandidate {
  /// 构造候选标签。
  ///
  /// 参数：
  /// - [marker]：标签要挂靠的 Marker（取位置与单元大小）；
  /// - [text]：已解析好的类目名（非空；空名不应进入候选）；
  /// - [dotColor]：标签左侧色点颜色（取所属一级大类的 deepColor）。
  const MarkerLabelCandidate({
    required this.marker,
    required this.text,
    required this.dotColor,
  });

  /// 标签挂靠的 Marker。
  final MapMarker marker;

  /// 标签文案（类目名）。
  final String text;

  /// 色点颜色。
  final Color dotColor;
}

/// 放置成功的一个标签（图层坐标系）。
class MarkerLabelPlacement {
  /// 构造放置结果。
  const MarkerLabelPlacement({
    required this.marker,
    required this.text,
    required this.rect,
    required this.dotColor,
    required this.dotCenter,
  });

  /// 标签挂靠的 Marker（点击命中仍走它，标签本身不参与命中测试）。
  final MapMarker marker;

  /// 标签文案。
  final String text;

  /// 胶囊矩形（图层坐标）。
  final Rect rect;

  /// 色点颜色。
  final Color dotColor;

  /// 色点圆心（图层坐标）。
  final Offset dotCenter;
}

/// 标签胶囊的横向内边距（逻辑像素）。
const double _kLabelPaddingH = 7;

/// 标签胶囊的纵向内边距（逻辑像素）。
const double _kLabelPaddingV = 4;

/// 标签胶囊圆角半径。
const double _kLabelCornerRadius = 9;

/// 标签左侧色点直径。
const double _kLabelDotDiameter = 6;

/// 色点与文字之间的间距。
const double _kLabelDotGap = 4;

/// 标签胶囊与所挂 Pin 底边之间的间距。
const double _kLabelPinGap = 5;

/// 标签与可见区域边缘的最小留白。
const double _kLabelViewportInset = 2;

/// 单点 Pin 直径（与 `marker_builder.dart` 的公开常量同源，此处按渲染半径使用）。
const double _kSinglePointDiameter = kSinglePointMarkerDiameter;

/// 选中态 Pin 直径。
const double _kSelectedDiameter = kSelectedMarkerDiameter;

/// 标签字号（R11：取自设计 Token，不写字面量）。
double get _labelFontSize => AppTypeScale.small.size;

/// 按优先级与碰撞放置标签（R5 / R6 / KTD6）。
///
/// 优先级：选中记录 → 单元条数降序 → 离屏幕中心距离升序 → 坐标稳定序。
/// 「单元条数降序」对应 R3「每个二级只在最大的渲染单元上标一次名」：同名候选里
/// 簇自然排在单点之前，从而名落簇上；近景档全是单点（条数相同），退化为「离中心近者优先」。
///
/// 同名只保留一个：用户读到的是字，两个「主卧」并排只是噪声（KTD6）。
///
/// 参数：
/// - [candidates]：候选标签（允许为空）；
/// - [markers]：本帧全部 Marker（用于「标签不得压住任何 Pin」，含未挂标签的）；
/// - [visibleRect]：屏幕可见区域（**图层坐标系**；精算层比屏幕大一圈余量，
///   用图层尺寸判边界会把标签放到屏外去）；
/// - [measureText]：文字测量回调，返回单行文本尺寸（由渲染层复用文字缓存提供）；
/// - [selectedListingId]：当前选中的信息 ID，决定第一优先级。
///
/// 返回：放置成功的标签，顺序即绘制顺序（与优先级一致）。
List<MarkerLabelPlacement> layoutMarkerLabels({
  required List<MarkerLabelCandidate> candidates,
  required List<MapMarker> markers,
  required Rect visibleRect,
  required Size Function(String text) measureText,
  String? selectedListingId,
}) {
  if (candidates.isEmpty || visibleRect.isEmpty) return const [];

  // 同名去重：先按优先级取第一，再统一排序 —— 否则「后出现的同名」可能抢走位置。
  final Offset center = visibleRect.center;
  final Map<String, MarkerLabelCandidate> byText = {};
  for (final c in candidates) {
    final existing = byText[c.text];
    if (existing == null ||
        _comparePriority(c, existing, center, selectedListingId) < 0) {
      byText[c.text] = c;
    }
  }
  final List<MarkerLabelCandidate> ordered = byText.values.toList()
    ..sort(
      (a, b) => _comparePriority(a, b, center, selectedListingId),
    );

  // 所有 Pin 的圆形占位：标签不得压住任何一枚 Pin（R6）。
  final List<Rect> pinRects = [
    for (final m in markers)
      Rect.fromCircle(
        center: Offset(m.x, m.y),
        radius: _markerRadius(m, selectedListingId),
      ),
  ];

  final List<MarkerLabelPlacement> placed = [];
  final List<Rect> occupied = [];

  for (final c in ordered) {
    final Size textSize = measureText(c.text);
    final double width =
        _kLabelPaddingH * 2 +
        _kLabelDotDiameter +
        _kLabelDotGap +
        textSize.width;
    final double height = textSize.height + _kLabelPaddingV * 2;
    final double pinRadius = _markerRadius(c.marker, selectedListingId);
    // 标签居中挂在 Pin 正下方；不做左右/上下挪位（R5「放不下就不标」）。
    final Rect rect = Rect.fromCenter(
      center: Offset(
        c.marker.x,
        c.marker.y + pinRadius + _kLabelPinGap + height / 2,
      ),
      width: width,
      height: height,
    );

    if (!_inside(rect, visibleRect)) continue;
    if (pinRects.any(rect.overlaps)) continue;
    if (occupied.any(rect.overlaps)) continue;

    occupied.add(rect);
    placed.add(
      MarkerLabelPlacement(
        marker: c.marker,
        text: c.text,
        rect: rect,
        dotColor: c.dotColor,
        dotCenter: Offset(
          rect.left + _kLabelPaddingH + _kLabelDotDiameter / 2,
          rect.center.dy,
        ),
      ),
    );
  }

  return placed;
}

/// 标签字号（供渲染层复用同一字号，避免两处各取一次 Token 后漂移）。
///
/// 返回：标签文字字号（逻辑像素）。
double markerLabelFontSize() => _labelFontSize;

/// 胶囊圆角半径（绘制用，几何量只在此处定义）。
///
/// 返回：圆角半径（逻辑像素）。
double markerLabelCornerRadius() => _kLabelCornerRadius;

/// 色点半径（绘制用）。
///
/// 返回：色点半径（逻辑像素）。
double markerLabelDotRadius() => _kLabelDotDiameter / 2;

/// 文字左边界相对胶囊左边界的内缩（内边距 + 色点 + 间距）。
///
/// 返回：内缩量（逻辑像素）。
double markerLabelTextInset() =>
    _kLabelPaddingH + _kLabelDotDiameter + _kLabelDotGap;

/// 矩形是否完整落在可见区域内（R6「不超出屏幕」）。
///
/// 参数：[rect] 待判矩形；[viewport] 可见区域。
/// 返回：四边都不越界时为真。
bool _inside(Rect rect, Rect viewport) {
  return rect.left >= viewport.left + _kLabelViewportInset &&
      rect.top >= viewport.top + _kLabelViewportInset &&
      rect.right <= viewport.right - _kLabelViewportInset &&
      rect.bottom <= viewport.bottom - _kLabelViewportInset;
}

/// Marker 的视觉半径（与渲染层同一套三档尺寸）。
///
/// 参数：[marker] 标记；[selectedListingId] 当前选中 ID。
/// 返回：半径（逻辑像素）。
double _markerRadius(MapMarker marker, String? selectedListingId) {
  return switch (marker) {
    ClusterMarker() => marker.diameter / 2,
    StackMarker() =>
      (selectedListingId != null && marker.contains(selectedListingId)
              ? _kSelectedDiameter
              : _kSinglePointDiameter) /
          2,
    SinglePointMarker() =>
      (marker.listingId == selectedListingId
              ? _kSelectedDiameter
              : _kSinglePointDiameter) /
          2,
  };
}

/// Marker 代表的记录条数（决定同名候选里谁优先挂名，见 R3）。
///
/// 参数：[marker] 标记。
/// 返回：条数（单点为 1）。
int _unitCount(MapMarker marker) => switch (marker) {
  ClusterMarker() => marker.count,
  StackMarker() => marker.count,
  SinglePointMarker() => 1,
};

/// 候选优先级比较（越小越优先）。
///
/// 参数：
/// - [a]、[b]：待比较候选；
/// - [center]：可见区域中心（距离基准）；
/// - [selectedListingId]：当前选中 ID。
/// 返回：负数表示 [a] 优先。
int _comparePriority(
  MarkerLabelCandidate a,
  MarkerLabelCandidate b,
  Offset center,
  String? selectedListingId,
) {
  final bool aSelected = _isSelected(a.marker, selectedListingId);
  final bool bSelected = _isSelected(b.marker, selectedListingId);
  if (aSelected != bSelected) return aSelected ? -1 : 1;

  final int byCount = _unitCount(b.marker).compareTo(_unitCount(a.marker));
  if (byCount != 0) return byCount;

  final double aDist =
      (Offset(a.marker.x, a.marker.y) - center).distanceSquared;
  final double bDist =
      (Offset(b.marker.x, b.marker.y) - center).distanceSquared;
  if (aDist != bDist) return aDist.compareTo(bDist);

  // 坐标稳定序：同一批数据两次布局的顺序必须一致，否则标签会在两次拖动间跳动。
  final int byY = a.marker.y.compareTo(b.marker.y);
  if (byY != 0) return byY;
  return a.marker.x.compareTo(b.marker.x);
}

/// 该 Marker 是否处于选中态。
///
/// 参数：[marker] 标记；[selectedListingId] 当前选中 ID。
/// 返回：命中选中记录时为真。
bool _isSelected(MapMarker marker, String? selectedListingId) {
  if (selectedListingId == null) return false;
  return switch (marker) {
    SinglePointMarker() => marker.listingId == selectedListingId,
    StackMarker() => marker.contains(selectedListingId),
    // 服务端簇没有成员 ID，无法判断「选中了簇里的某条」；簇本身也不是可选中单元。
    ClusterMarker() => false,
  };
}
