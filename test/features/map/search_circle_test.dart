/// 搜索圈覆盖层单测（U7）：按真实米数绘制、不因缺数据抛异常。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/map/map_projection.dart';
import 'package:zhaoyazhao/features/map/search_circle_overlay.dart';

void main() {
  const projection = MapProjection(
    centerLat: 30.28,
    centerLng: 120.15,
    metersPerPixel: 12,
    viewportSize: (width: 400, height: 800),
  );

  testWidgets('1km 圈在 12m/px 投影下正常绘制', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: SearchCircleOverlay(
              projection: projection,
              anchorLat: 30.28,
              anchorLng: 120.15,
              radiusMeters: 1000,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(CustomPaint), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('半径小于 1px 时不绘制也不抛异常', (tester) async {
    const farProjection = MapProjection(
      centerLat: 30.28,
      centerLng: 120.15,
      metersPerPixel: 12000,
      viewportSize: (width: 400, height: 800),
    );
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 800,
            child: SearchCircleOverlay(
              projection: farProjection,
              anchorLat: 30.28,
              anchorLng: 120.15,
              radiusMeters: 1000,
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
