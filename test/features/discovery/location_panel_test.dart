/// 位置面板「当前搜索位置 / 当前定位」文案回归（2026-11-03 真机反馈）。
///
/// 缺陷现象：面板里显示「我的位置 我的位置」「当前位置」，而不是可读地址。
/// 根因：搜索位置块没接逆地理（写死来源标签）；当前定位把逆地理失败/加载中
/// 都兜底成「当前位置」，用户无法分辨「还没算出来」和「拿不到地址」。
/// 本文件锁定：有地址显示地址、无地址显示明确失败文案、无定位显示未校准。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/discovery/location_panel.dart';
import 'package:zhaoyazhao/features/location/location_center.dart';

/// 固定定位点（模拟本会话已取得有效定位）。
class _FixedLocationNotifier extends LocationFixNotifier {
  /// 构造固定定位 Notifier。
  ///
  /// 参数：[fix] 固定定位点（null = 无定位）。
  _FixedLocationNotifier(this._fix);

  final LocationFix? _fix;

  @override
  LocationFix? build() => _fix;
}

/// 泵入位置面板。
///
/// 参数：[tester] 测试句柄；[fix] 定位点；[address] 逆地理返回值（空串＝取不到）。
/// 返回：[Future<void>]。
Future<void> _pumpPanel(
  WidgetTester tester, {
  required LocationFix? fix,
  required String address,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        locationFixProvider.overrideWith(() => _FixedLocationNotifier(fix)),
        addressLabelProvider.overrideWith((ref, point) async => address),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: LocationPanel(onDone: _noop)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 面板关闭回调占位。
void _noop() {}

void main() {
  testWidgets('已定位且有地址：搜索位置与当前定位都显示地址', (tester) async {
    await _pumpPanel(
      tester,
      fix: const LocationFix(lat: 31.82, lng: 117.22, accuracy: 20),
      address: '安徽省合肥市长丰县双墩镇北城世纪城',
    );

    expect(find.text('安徽省合肥市长丰县双墩镇北城世纪城'), findsNWidgets(2));
    expect(find.text('当前位置'), findsNothing);
    expect(find.text('我的位置 我的位置'), findsNothing);
    // 来源标签仍保留一枚（与地址不同值，不隐藏）。
    expect(find.text('我的位置'), findsOneWidget);
  });

  testWidgets('已定位但取不到地址：显示明确的失败文案而非「当前位置」', (tester) async {
    await _pumpPanel(
      tester,
      fix: const LocationFix(lat: 31.82, lng: 117.22, accuracy: 20),
      address: '',
    );

    expect(find.text('暂时无法获取位置名称'), findsNWidgets(2));
    expect(find.text('当前位置'), findsNothing);
  });

  testWidgets('未定位：搜索位置显示未校准且不重复来源标签', (tester) async {
    await _pumpPanel(tester, fix: null, address: '');

    expect(find.text('未校准'), findsOneWidget);
    expect(find.text('未获取到定位'), findsOneWidget);
  });
}
