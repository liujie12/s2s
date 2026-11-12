// 渲染层画标签后的两条行为守卫（U3）。
//
// 只断言「不该变的东西没变」：标签不参与命中测试、并且对读屏可见。
// 具体像素由 painter 负责，用 golden 会因字体差异在 CI 上抖动，故不采用。
//
// 运行：flutter test test/features/map/marker_layer_label_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';
import 'package:zhaoyazhao/features/map/marker_label_layout.dart';
import 'package:zhaoyazhao/features/map/marker_layer.dart';

const double _pinX = 100;
const double _pinY = 100;

SinglePointMarker _marker() => const SinglePointMarker(
  x: _pinX,
  y: _pinY,
  topCategory: ListingCategory.work,
  listingId: '1',
  leafCategoryId: 10101,
);

/// 一个挂在 Pin 下方的标签（坐标与布局模块自洽）。
MarkerLabelPlacement _labelUnderPin() => MarkerLabelPlacement(
  marker: _marker(),
  text: '主卧',
  rect: const Rect.fromLTWH(78, 125, 44, 22),
  dotColor: const Color(0xFF123456),
  dotCenter: const Offset(88, 136),
);

Widget _host(MarkerLayer layer) => MaterialApp(
  home: Scaffold(
    body: Stack(
      children: [Positioned.fill(child: layer)],
    ),
  ),
);

void main() {
  testWidgets('标签不参与命中测试：点标签返回 null，点 Pin 仍命中', (tester) async {
    final marker = _marker();
    final layer = MarkerLayer(
      markers: [marker],
      labels: [_labelUnderPin()],
      supplyDemandById: const {'1': SupplyDemand.supply},
    );

    // 标签胶囊中心：不属于任何 Marker，命中应为空。
    expect(layer.hitTestMarker(const Offset(100, 136)), isNull);
    // Pin 圆心照常命中。
    expect(layer.hitTestMarker(const Offset(_pinX, _pinY)), same(marker));

    await tester.pumpWidget(_host(layer));
    expect(tester.takeException(), isNull);
  });

  testWidgets('标签对读屏可见，播报类目名', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        MarkerLayer(
          markers: [_marker()],
          labels: [_labelUnderPin()],
          supplyDemandById: const {'1': SupplyDemand.supply},
        ),
      ),
    );

    expect(find.bySemanticsLabel('主卧'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('没有标签时正常渲染（标签是可选入参）', (tester) async {
    await tester.pumpWidget(
      _host(
        MarkerLayer(
          markers: [_marker()],
          supplyDemandById: const {'1': SupplyDemand.supply},
        ),
      ),
    );

    expect(tester.takeException(), isNull);
  });
}
