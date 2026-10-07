/// Marker 图层的指针行为测试。
///
/// 为什么必须锁：本层盖在底图之上且铺满全屏，它的命中行为直接决定**地图能不能
/// 拖动/缩放**。2026-10-07 真机缺陷的根因就在这 —— 原先用
/// `GestureDetector(behavior: HitTestBehavior.opaque)`，`RenderStack` 命中本层后
/// 不再向下查找兄弟节点，底图（高德平台视图 / 降级底图画布）收不到任何指针，
/// 表现为「地图拖不动、缩放不动」，真地图与降级底图**两条分支同时失效**。
///
/// 这类缺陷的静态特征是「什么都没报错」：无异常、无日志、单测也不会红，只有真机上
/// 手指划不动。故此处把两条契约分别钉死：
/// ① 指针必须**继续下探**到底层兄弟节点（拖动/缩放能被底图接管）；
/// ② 点击必须仍能选中 Marker，且拖动与捏合**不得**被误判成点击。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/map/clustering/marker_builder.dart';
import 'package:zhaoyazhao/features/map/marker_layer.dart';

/// 底图替身收到的指针事件计数。
///
/// 用可变对象而非闭包外的局部变量：计数要由回调累加、由断言读取，
/// 两者不在同一作用域，只有共享实例才拿得到。
class _PointerLog {
  int downs = 0;
  int moves = 0;
}

void main() {
  /// 被测 Marker：单点，圆心 (100, 100)，视觉半径 = 单点默认直径 40 的一半。
  const marker = SinglePointMarker(
    x: 100,
    y: 100,
    topCategory: null,
    listingId: '1',
  );

  /// 铺「底图替身 + MarkerLayer」两层，并返回底图收到的指针事件计数。
  ///
  /// 底图替身用 [Listener] 而非 `GestureDetector`：这里要验的是「指针有没有到达
  /// 下层」，与手势竞技场的胜负无关，`Listener` 能直接观测到到达与否。
  Future<_PointerLog> pumpOverBaseLayer(
    WidgetTester tester, {
    List<MapMarker> markers = const [],
    void Function(MapMarker marker)? onTapMarker,
  }) async {
    final log = _PointerLog();
    await tester.pumpWidget(
      MaterialApp(
        home: Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (_) => log.downs++,
              onPointerMove: (_) => log.moves++,
              child: const ColoredBox(color: Color(0xFFFFFFFF)),
            ),
            MarkerLayer(
              markers: markers,
              supplyDemandById: const {'1': SupplyDemand.supply},
              onTapMarker: onTapMarker,
            ),
          ],
        ),
      ),
    );
    return log;
  }

  testWidgets('拖动时指针继续下探到底图：down 与 move 都能被下层收到', (tester) async {
    final log = await pumpOverBaseLayer(tester);

    final gesture = await tester.startGesture(const Offset(200, 300));
    await gesture.moveBy(const Offset(120, 0));
    await gesture.up();

    expect(
      log.downs,
      1,
      reason: '底图必须收到 pointer down —— 收不到就是「地图拖不动」那个缺陷',
    );
    expect(
      log.moves,
      greaterThan(0),
      reason: '底图必须收到 pointer move，否则拖动过程中底图不会跟随',
    );
  });

  testWidgets('短按命中 Marker 时触发选中回调', (tester) async {
    MapMarker? tapped;
    await pumpOverBaseLayer(
      tester,
      markers: const [marker],
      onTapMarker: (m) => tapped = m,
    );

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.up();

    expect(tapped, same(marker), reason: '单指原地按下抬起应命中 Marker');
  });

  testWidgets('拖动超过触控抖动阈值时不触发选中', (tester) async {
    MapMarker? tapped;
    await pumpOverBaseLayer(
      tester,
      markers: const [marker],
      onTapMarker: (m) => tapped = m,
    );

    final gesture = await tester.startGesture(const Offset(100, 100));
    await gesture.moveBy(const Offset(0, kTouchSlop + 20));
    await gesture.up();

    expect(
      tapped,
      isNull,
      reason: '拖动地图时手指常从 Pin 上起手，若判成点击就会「一拖就弹信息卡」',
    );
  });

  testWidgets('双指捏合抬起时不触发选中', (tester) async {
    MapMarker? tapped;
    await pumpOverBaseLayer(
      tester,
      markers: const [marker],
      onTapMarker: (m) => tapped = m,
    );

    final first = await tester.startGesture(const Offset(100, 100));
    final second = await tester.startGesture(const Offset(160, 160));
    await second.up();
    await first.up();

    expect(
      tapped,
      isNull,
      reason: '捏合缩放收尾时不得误报一次选中（第二根手指抬起不能按单指判点击）',
    );
  });

  group('hitTestMarker', () {
    const layer = MarkerLayer(
      markers: [marker],
      supplyDemandById: {'1': SupplyDemand.supply},
    );

    test('圆心命中，圆外不命中', () {
      expect(layer.hitTestMarker(const Offset(100, 100)), same(marker));
      expect(
        layer.hitTestMarker(const Offset(100, 140)),
        isNull,
        reason: '视觉半径 20，纵向偏 40 已在圈外',
      );
    });

    test('重叠时命中画在上面的那个（倒序遍历）', () {
      const onTop = SinglePointMarker(
        x: 100,
        y: 100,
        topCategory: null,
        listingId: '2',
      );
      const overlapped = MarkerLayer(
        markers: [marker, onTop],
        supplyDemandById: {'1': SupplyDemand.supply, '2': SupplyDemand.supply},
      );
      expect(
        overlapped.hitTestMarker(const Offset(100, 100)),
        same(onTop),
        reason: '后画的压在上面，命中判定必须与视觉一致',
      );
    });
  });
}
