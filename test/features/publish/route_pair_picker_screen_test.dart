/// 起终点选择页 widget 测试（计划 U3；覆盖 AE1–AE6 中与页面相关的场景）。
///
/// **这些断言防的是什么**：这一页的关键行为都不是「看起来对不对」，而是
/// 「失败时会不会静默给出错误结论」——
///   - 定位被拒时起点必须留空（塞默认城市中心会让用户发出一条位置错误的帖子）；
///   - 距离失败必须隐藏而不是显示 0（0 是一个会被相信的确定值）；
///   - 取消必须丢弃页面内改动（表单保留进入前的值）。
/// 这些分支在真机上都要靠权限开关或断网才能复现，故在这里用注入的假实现锁死。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/route_pair.dart';
import 'package:zhaoyazhao/features/location/driving_route.dart';
import 'package:zhaoyazhao/features/location/high_accuracy_locator.dart';
import 'package:zhaoyazhao/features/location/location_center.dart';
import 'package:zhaoyazhao/features/location/poi_search.dart';
import 'package:zhaoyazhao/features/publish/route_pair_picker_screen.dart';
import 'package:zhaoyazhao/features/privacy/privacy_consent.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

/// 固定返回值的定位器替身（不触系统定位与原生通道）。
class _FakeLocator extends HighAccuracyLocator {
  _FakeLocator(this.fix);

  /// 每次定位返回的点；null 表示「定位被拒/不可用」。
  final LocationFix? fix;

  @override
  Future<LocationFix?> locate({
    Duration timeout = const Duration(
      milliseconds: NfrLocation.publishFixTimeoutMs,
    ),
  }) async => fix;
}

/// 固定同意态的隐私 Notifier（不读真实 SharedPreferences）。
class _FixedConsent extends PrivacyConsentNotifier {
  _FixedConsent(this._status);

  final PrivacyConsentStatus _status;

  @override
  PrivacyConsentStatus build() => _status;
}

/// 候选搜索替身：记录调用次数与关键词，返回固定候选。
class _FakeSearch {
  /// 每次调用返回的候选。
  List<PoiSuggestion> results = const <PoiSuggestion>[];

  /// 调用次数。
  int calls = 0;

  /// 最近一次关键词。
  String? lastKeyword;

  /// 可覆盖入口的实现。
  Future<List<PoiSuggestion>> call({
    required String keywords,
    double? lng,
    double? lat,
  }) async {
    calls++;
    lastKeyword = keywords;
    return results;
  }
}

/// 驾车路径替身：记录请求坐标，可挂起以断言「计算中…」。
class _FakeDriving {
  /// 请求记录（起点经度、终点经度）。
  final List<({double originLng, double destinationLng})> calls =
      <({double originLng, double destinationLng})>[];

  /// 立即返回的结果；null 表示请求失败。
  DrivingSummary? result;

  /// true 时立即返回 [result]；false 时把请求挂起，由测试手动完成。
  bool autoResolve = true;

  /// 挂起的请求（autoResolve=false 时按序追加）。
  final List<Completer<DrivingSummary?>> pending =
      <Completer<DrivingSummary?>>[];

  /// 可覆盖入口的实现。
  Future<DrivingSummary?> call({
    required double originLng,
    required double originLat,
    required double destinationLng,
    required double destinationLat,
  }) {
    calls.add((originLng: originLng, destinationLng: destinationLng));
    if (autoResolve) return Future<DrivingSummary?>.value(result);
    final completer = Completer<DrivingSummary?>();
    pending.add(completer);
    return completer.future;
  }
}

/// 打开选择页并记录回传结果的宿主。
class _Host extends StatelessWidget {
  const _Host({required this.initial, required this.onResult});

  final RoutePair? initial;
  final ValueChanged<RoutePair?> onResult;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Builder(
        builder: (inner) => Center(
          child: ElevatedButton(
            onPressed: () async {
              final result = await Navigator.of(inner).push<RoutePair>(
                MaterialPageRoute<RoutePair>(
                  builder: (_) => RoutePairPickerScreen(initial: initial),
                ),
              );
              onResult(result);
            },
            child: const Text('打开选择页'),
          ),
        ),
      ),
    );
  }
}

void main() {
  late _FakeSearch search;
  late _FakeDriving driving;
  late List<RoutePair?> results;

  setUp(() {
    search = _FakeSearch();
    driving = _FakeDriving();
    results = <RoutePair?>[];
  });

  /// 组装测试应用并打开选择页。
  ///
  /// 参数：[fix] 定位结果（null=被拒）；[consent] 隐私同意态；
  /// [initial] 进入前的起终点。
  /// 返回：Future，页面打开并稳定后结束。
  Future<void> openPicker(
    WidgetTester tester, {
    LocationFix? fix = const LocationFix(lat: 40.071, lng: 116.337, accuracy: 10),
    PrivacyConsentStatus consent = PrivacyConsentStatus.agreed,
    RoutePair? initial,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          highAccuracyLocatorProvider.overrideWithValue(_FakeLocator(fix)),
          privacyConsentProvider.overrideWith(() => _FixedConsent(consent)),
          poiSearchFnProvider.overrideWithValue(search.call),
          drivingSummaryFnProvider.overrideWithValue(driving.call),
        ],
        child: MaterialApp(
          home: _Host(initial: initial, onResult: results.add),
        ),
      ),
    );
    await tester.tap(find.text('打开选择页'));
    await tester.pumpAndSettle();
  }

  /// 构造一个两端齐备的初始值（坐标固定，便于断言交换方向）。
  ///
  /// 返回：起点 116.337/40.071、终点 116.316/39.983 的起终点对。
  RoutePair completePair() => const RoutePair(
    origin: RoutePlace(
      name: '回龙观',
      address: '北京市昌平区回龙观',
      lng: 116.337,
      lat: 40.071,
    ),
    destination: RoutePlace(
      name: '中关村',
      address: '北京市海淀区中关村大街',
      lng: 116.316,
      lat: 39.983,
    ),
  );

  /// 「确认」按钮的 onPressed 是否为空（禁用判据）。
  bool confirmDisabled(WidgetTester tester) {
    final button = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '确认'),
    );
    return button.onPressed == null;
  }

  group('AE1 默认进入', () {
    testWidgets('定位可用 → 起点显示「我的位置」，终点为空，确认禁用且指出缺终点',
        (tester) async {
      await openPicker(tester);

      expect(find.widgetWithText(TextField, '我的位置'), findsOneWidget);
      expect(find.text('还差终点'), findsOneWidget);
      expect(confirmDisabled(tester), isTrue);
      // R15 位置可见性告知常驻。
      expect(find.text('起点与终点将对所有看到这条信息的人可见'), findsOneWidget);
    });

    testWidgets('两行卡片读作起点/终点，交换按钮有标签且热区不小于 44',
        (tester) async {
      final handle = tester.ensureSemantics();
      await openPicker(tester);

      expect(find.bySemanticsLabel(RegExp('起点')), findsWidgets);
      expect(find.bySemanticsLabel(RegExp('终点')), findsWidgets);
      final swap = find.byTooltip('交换起终点');
      expect(swap, findsOneWidget);
      expect(tester.getSize(swap).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(swap).height, greaterThanOrEqualTo(44));
      handle.dispose();
    });

    testWidgets('已选值的地址描述作为副文展示', (tester) async {
      await openPicker(tester, initial: completePair());

      expect(find.text('北京市昌平区回龙观'), findsOneWidget);
      expect(find.text('北京市海淀区中关村大街'), findsOneWidget);
    });
  });

  group('AE5 定位被拒', () {
    testWidgets('起点留空并提示「选择起点」，其余交互正常', (tester) async {
      await openPicker(tester, fix: null);

      expect(find.text('选择起点'), findsOneWidget);
      expect(find.text('还差起点'), findsOneWidget);
      expect(confirmDisabled(tester), isTrue);
      // 快捷项与取消仍可用（页面没被定位失败阻断）。
      expect(find.text('我的位置'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
    });
  });

  group('候选列表', () {
    testWidgets('输入关键词 → 出现候选；点选 → 回填该行并收起列表', (tester) async {
      search.results = const <PoiSuggestion>[
        PoiSuggestion(
          id: 'B1',
          name: '中关村站',
          address: '北京市海淀区中关村大街 1 号',
          lng: 116.316,
          lat: 39.983,
        ),
      ];
      await openPicker(tester);

      await tester.tap(find.byType(TextField).at(1));
      await tester.enterText(find.byType(TextField).at(1), '中关村');
      await tester.pump(
        const Duration(milliseconds: NfrLocation.poiSearchDebounceMs + 50),
      );
      await tester.pumpAndSettle();

      expect(search.calls, 1);
      expect(search.lastKeyword, '中关村');
      expect(find.text('中关村站'), findsOneWidget);

      await tester.tap(find.text('中关村站'));
      await tester.pumpAndSettle();

      // 回填后候选收起，输入框里是候选名称，两端齐备 → 确认可用。
      expect(find.text('中关村站'), findsOneWidget);
      expect(find.text('北京市海淀区中关村大街 1 号'), findsOneWidget);
      expect(confirmDisabled(tester), isFalse);
    });
  });

  group('AE2 交换与距离', () {
    testWidgets('两端齐备显示距离；交换后按反方向重新请求', (tester) async {
      driving.result = const DrivingSummary(distanceM: 18500, durationS: 2100);
      await openPicker(tester, initial: completePair());

      expect(find.text('约 19 km · 约 35 分钟'), findsOneWidget);
      expect(driving.calls, hasLength(1));
      expect(driving.calls.first.originLng, 116.337);

      await tester.tap(find.byTooltip('交换起终点'));
      await tester.pumpAndSettle();

      expect(driving.calls, hasLength(2));
      expect(driving.calls.last.originLng, 116.316);
      expect(driving.calls.last.destinationLng, 116.337);
      // 两行互换：起点变成中关村。
      expect(find.widgetWithText(TextField, '中关村'), findsOneWidget);
      expect(find.widgetWithText(TextField, '回龙观'), findsOneWidget);
    });

    testWidgets('请求进行中显示「计算中…」且行高不变', (tester) async {
      driving.autoResolve = false;
      await openPicker(tester, initial: completePair());

      expect(find.text('计算中…'), findsOneWidget);
      final loadingHeight = tester.getSize(find.text('计算中…')).height;

      driving.pending.single.complete(
        const DrivingSummary(distanceM: 18500, durationS: 2100),
      );
      await tester.pumpAndSettle();

      expect(find.text('计算中…'), findsNothing);
      expect(find.text('约 19 km · 约 35 分钟'), findsOneWidget);
      // 同一行高：加载态与结果态之间没有跳动。
      expect(
        tester.getSize(find.text('约 19 km · 约 35 分钟')).height,
        loadingHeight,
      );
    });
  });

  group('AE4 距离失败', () {
    testWidgets('路径请求失败 → 距离段隐藏、不弹错误、确认仍可用', (tester) async {
      driving.result = null;
      await openPicker(tester, initial: completePair());

      expect(find.textContaining('约 '), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
      expect(confirmDisabled(tester), isFalse);
    });
  });

  group('AE3 只选一端', () {
    testWidgets('只有终点 → 确认禁用并指出缺起点', (tester) async {
      await openPicker(
        tester,
        fix: null,
        initial: const RoutePair(
          origin: RoutePlace(name: ''),
          destination: RoutePlace(
            name: '中关村',
            lng: 116.316,
            lat: 39.983,
          ),
        ),
      );

      expect(confirmDisabled(tester), isTrue);
      expect(find.text('还差起点'), findsOneWidget);
    });
  });

  group('R14 取消/返回', () {
    testWidgets('点取消 → 页面关闭且回传 null（表单保留进入前的值）',
        (tester) async {
      await openPicker(tester, initial: completePair());

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(results, hasLength(1));
      expect(results.single, isNull);
      expect(find.text('打开选择页'), findsOneWidget);
    });

    testWidgets('确认 → 回传两端与距离', (tester) async {
      driving.result = const DrivingSummary(distanceM: 18500, durationS: 2100);
      await openPicker(tester, initial: completePair());

      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();

      expect(results.single, isNotNull);
      expect(results.single!.origin.name, '回龙观');
      expect(results.single!.destination.name, '中关村');
      expect(results.single!.distanceM, 18500);
    });
  });

  group('KTD5 未同意隐私协议', () {
    testWidgets('不发候选与驾车请求，给出降级提示', (tester) async {
      await openPicker(
        tester,
        consent: PrivacyConsentStatus.notAgreed,
        initial: completePair(),
      );

      expect(driving.calls, isEmpty);
      expect(find.textContaining('未同意隐私协议'), findsOneWidget);

      await tester.tap(find.byType(TextField).at(1));
      await tester.enterText(find.byType(TextField).at(1), '中关村');
      await tester.pump(
        const Duration(milliseconds: NfrLocation.poiSearchDebounceMs + 50),
      );
      await tester.pumpAndSettle();

      expect(search.calls, 0);
    });
  });

  group('地图形态', () {
    testWidgets('未同意隐私协议 → 地图态提示；返回列表后交互正常',
        (tester) async {
      await openPicker(tester, consent: PrivacyConsentStatus.notAgreed);

      await tester.tap(find.text('地图选点'));
      await tester.pumpAndSettle();

      expect(find.text('请先同意隐私协议后再使用地图选点'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);

      await tester.tap(find.text('返回'));
      await tester.pumpAndSettle();

      expect(find.text('选择起终点'), findsOneWidget);
      expect(find.text('起点与终点将对所有看到这条信息的人可见'), findsOneWidget);
    });
  });
}
