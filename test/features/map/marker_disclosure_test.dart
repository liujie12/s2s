// 名称披露分档与抑制规则的纯函数断言（R1 / R3 / R4 / R8 / KD5）。
//
// 这些阈值是产品口径：改一次就会改变用户看到的名称数量与粒度。用单测把
// 边界值（恰好等于阈值）钉住，避免浮点比较下出现「两档都不认」的空档。
//
// 运行：flutter test test/features/map/marker_disclosure_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/map/marker_disclosure.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

void main() {
  group('markerTierOf', () {
    test('近景：m/px 小于等于近景上界', () {
      expect(markerTierOf(1), MarkerDisclosureTier.detail);
      expect(markerTierOf(NfrPerf.labelDetailMetersPerPixel), MarkerDisclosureTier.detail);
    });

    test('中景：近景上界与切换阈值之间（含切换阈值）', () {
      expect(
        markerTierOf(NfrPerf.labelDetailMetersPerPixel + 0.01),
        MarkerDisclosureTier.mid,
      );
      // 默认 5 km 视野适配后约 27.8 m/px，应落在中景（计划 Assumptions）。
      expect(markerTierOf(27.8), MarkerDisclosureTier.mid);
      expect(
        markerTierOf(NfrPerf.clusterModeSwitchMetersPerPixel),
        MarkerDisclosureTier.mid,
      );
    });

    test('远景：超过切换阈值', () {
      expect(
        markerTierOf(NfrPerf.clusterModeSwitchMetersPerPixel + 0.01),
        MarkerDisclosureTier.far,
      );
      expect(markerTierOf(200), MarkerDisclosureTier.far);
    });
  });

  group('suppressMarkerLabelsFor', () {
    test('单一叶子收窄时抑制 Pin 名称（R8）', () {
      expect(suppressMarkerLabelsFor(1), isTrue);
    });

    test('未收窄（0）或多叶子（≥2）不抑制', () {
      expect(suppressMarkerLabelsFor(0), isFalse);
      expect(suppressMarkerLabelsFor(2), isFalse);
      expect(suppressMarkerLabelsFor(25), isFalse);
    });
  });

  group('midTierAggregationFor', () {
    test('中景档且未显式选叶子时按二级聚合', () {
      expect(
        midTierAggregationFor(
          tier: MarkerDisclosureTier.mid,
          explicitLeafSelection: false,
        ),
        isTrue,
      );
    });

    test('显式选了叶子时关闭二级聚合（KD5）', () {
      expect(
        midTierAggregationFor(
          tier: MarkerDisclosureTier.mid,
          explicitLeafSelection: true,
        ),
        isFalse,
      );
    });

    test('近景与远景都不做二级聚合', () {
      expect(
        midTierAggregationFor(
          tier: MarkerDisclosureTier.detail,
          explicitLeafSelection: false,
        ),
        isFalse,
      );
      expect(
        midTierAggregationFor(
          tier: MarkerDisclosureTier.far,
          explicitLeafSelection: false,
        ),
        isFalse,
      );
    });
  });

  group('名称解析（R7：查不到就置空，不造占位）', () {
    test('已登记叶子返回三级名与所属二级名', () {
      final leafName = leafCategoryNameOf(10101);
      final midName = midCategoryNameOfLeaf(10101);
      expect(leafName, isNotNull);
      expect(leafName, isNotEmpty);
      expect(midName, isNotNull);
      // 二级名必须等于「按二级 ID 直接查」的结果 —— 两条入口同一份真源。
      expect(midName, midCategoryNameOf(101));
    });

    test('空 ID 与未登记 ID 返回 null', () {
      expect(leafCategoryNameOf(null), isNull);
      expect(leafCategoryNameOf(999999), isNull);
      expect(midCategoryNameOf(null), isNull);
      expect(midCategoryNameOf(999), isNull);
      expect(midCategoryNameOfLeaf(null), isNull);
      expect(midCategoryNameOfLeaf(999999), isNull);
    });
  });
}
