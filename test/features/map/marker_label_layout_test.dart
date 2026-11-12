// 类目名标签布局的纯函数断言（R5 / R6 / R3 / KD6）。
//
// 为什么值得单测：布局是「放不下就不标」的贪心规则，肉眼看图只能看到最后结果，
// 分不清「本来该标但被碰撞跳过」与「压根没产出候选」。这里用固定文字尺寸把
// 几何完全钉死，任何阈值变化都会立刻变红。
//
// 运行：flutter test test/features/map/marker_label_layout_test.dart

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';
import 'package:zhaoyazhao/features/map/marker_label_layout.dart';

/// 固定文字测量：每个字符宽 10、高 14。
///
/// 不引入真实字体：单测只验证几何规则，真实整形由渲染层复用缓存承担。
Size _measure(String text) => Size(text.length * 10, 14);

const Color _dot = Color(0xFF123456);

/// 造一个单点 Marker。
MapMarker _single(String id, double x, double y) => SinglePointMarker(
  x: x,
  y: y,
  topCategory: ListingCategory.work,
  listingId: id,
);

/// 造一个候选标签。
MarkerLabelCandidate _candidate(MapMarker marker, String text) =>
    MarkerLabelCandidate(marker: marker, text: text, dotColor: _dot);

const Rect _viewport = Rect.fromLTWH(0, 0, 400, 400);

void main() {
  test('空间充足时两个标签都放下，且都在各自 Pin 下方', () {
    final a = _single('a', 100, 100);
    final b = _single('b', 300, 100);

    final placed = layoutMarkerLabels(
      candidates: [_candidate(a, '主卧'), _candidate(b, '次卧')],
      markers: [a, b],
      visibleRect: _viewport,
      measureText: _measure,
    );

    expect(placed, hasLength(2));
    for (final p in placed) {
      expect(p.rect.center.dx, closeTo(p.marker.x, 0.001));
      // 胶囊整体落在 Pin 圆心之下，不压 Pin。
      expect(p.rect.top, greaterThan(p.marker.y));
    }
  });

  test('第二个标签会压住第一个时被跳过，选中记录优先', () {
    // 两个 Pin 相距 30px，标签宽 44px，必然重叠。
    // 选中 a（离中心更远）后 a 必须先占位，b 被跳过（R5）。
    final a = _single('a', 100, 100);
    final b = _single('b', 130, 100);

    final placed = layoutMarkerLabels(
      candidates: [_candidate(b, '次卧'), _candidate(a, '主卧')],
      markers: [a, b],
      visibleRect: _viewport,
      measureText: _measure,
      selectedListingId: 'a',
    );

    expect(placed, hasLength(1));
    expect(placed.single.marker, same(a));
  });

  test('标签会超出可见区域右边界时被跳过，不做左右挪位', () {
    final a = _single('a', 390, 100);

    final placed = layoutMarkerLabels(
      candidates: [_candidate(a, '主卧')],
      markers: [a],
      visibleRect: _viewport,
      measureText: _measure,
    );

    expect(placed, isEmpty);
  });

  test('标签会压住另一枚 Pin 时被跳过', () {
    // b 的 Pin 圆正好落在 a 标签要占的位置上（R6：标签不遮任何 Pin）。
    final a = _single('a', 100, 100);
    final b = _single('b', 100, 140);

    final placed = layoutMarkerLabels(
      candidates: [_candidate(a, '主卧')],
      markers: [a, b],
      visibleRect: _viewport,
      measureText: _measure,
    );

    expect(placed, isEmpty);
  });

  test('相同名称只产生一个标签（KTD6）', () {
    final a = _single('a', 100, 100);
    final b = _single('b', 300, 100);

    final placed = layoutMarkerLabels(
      candidates: [_candidate(a, '主卧'), _candidate(b, '主卧')],
      markers: [a, b],
      visibleRect: _viewport,
      measureText: _measure,
    );

    expect(placed, hasLength(1));
    expect(placed.single.text, '主卧');
  });

  test('同名候选里单元条数大的优先（R3：名落最大单元）', () {
    // 单点更靠近屏幕中心，但簇代表 5 条记录 —— 名称应挂在簇上。
    final single = _single('s', 200, 195);
    final cluster = ClusterMarker(
      x: 100,
      y: 100,
      topCategory: ListingCategory.work,
      count: 5,
      memberIds: const ['x', 'y', 'z'],
      midCategoryId: 101,
    );

    final placed = layoutMarkerLabels(
      candidates: [
        _candidate(single, '整租'),
        _candidate(cluster, '整租'),
      ],
      markers: [single, cluster],
      visibleRect: _viewport,
      measureText: _measure,
    );

    expect(placed, hasLength(1));
    expect(placed.single.marker, same(cluster));
  });

  test('没有候选时返回空列表，不抛异常', () {
    final placed = layoutMarkerLabels(
      candidates: const [],
      markers: [_single('a', 10, 10)],
      visibleRect: _viewport,
      measureText: _measure,
    );

    expect(placed, isEmpty);
  });

  test('色点圆心在胶囊左侧内边距内', () {
    final a = _single('a', 100, 100);
    final placed = layoutMarkerLabels(
      candidates: [_candidate(a, '主卧')],
      markers: [a],
      visibleRect: _viewport,
      measureText: _measure,
    ).single;

    expect(placed.dotCenter.dx, lessThanOrEqualTo(placed.rect.left + 10));
    expect(placed.dotCenter.dy, closeTo(placed.rect.center.dy, 0.001));
  });
}
