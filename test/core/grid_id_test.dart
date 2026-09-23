/// grid_id 三端对拍——Dart 端（详设 §5.4.1 / 编码规范 §7.2-③）。
///
/// 本测试与服务端 `GridIdCalculatorTest`（Java）、SQL 验证脚本共用同一份 10 条向量表，
/// 任一端不过即视为实现错误。核心考察点：
///
/// - 第 3 条 `(0.00450, 0.00450) → "1_1"`：验证浮点补偿（0.00450 的 double 表示
///   略小于 0.0045，缺补偿会算成 0_0）；
/// - 第 9 条 `(-0.000015, -0.000015) → "-1_-1"`：唯一能暴露「用截断代替 floor」的
///   向量，最终结果偶然正确（截断得中间微度 -1、floor 得 -2，两者 /450 向下取整后都
///   是 -1），因此**必须额外断言中间微度值 == -2**，只断言最终 grid_id 等于白测。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/cache/grid_id.dart';

void main() {
  group('gridIdOf 10 条测试向量', () {
    const cases = <({double lng, double lat, String expected})>[
      (lng: 120.15000, lat: 30.28000, expected: '26700_6728'),
      (lng: 0, lat: 0, expected: '0_0'),
      (lng: 0.00450, lat: 0.00450, expected: '1_1'),
      (lng: 0.00449, lat: 0.00449, expected: '0_0'),
      (lng: -0.00001, lat: -0.00001, expected: '-1_-1'),
      (lng: -0.00450, lat: -0.00450, expected: '-1_-1'),
      (lng: -0.00451, lat: -0.00451, expected: '-2_-2'),
      (lng: 0.004500049, lat: 0.004500049, expected: '1_1'),
      (lng: -0.000015, lat: -0.000015, expected: '-1_-1'),
      (lng: 120.15000, lat: -30.28000, expected: '26700_-6729'),
    ];

    for (final c in cases) {
      test('(${c.lng}, ${c.lat}) → ${c.expected}', () {
        expect(gridIdOf(c.lng, c.lat), c.expected);
      });
    }
  });

  test('向量9：负小坐标，必须额外断言中间微度值为 -2', () {
    // 只断言 gridIdOf 结果会漏掉 bug：截断与 floor 在本例最终结果相同。
    expect(gridIdOf(-0.000015, -0.000015), '-1_-1');
    // 这一行才是真正的探针。
    expect(floorToMicroDegree(-0.000015), -2);
  });

  test('向量3：浮点补偿使 0.00450 落到第 1 格（中间微度 == 450）', () {
    // 0.00450 的 double 略小于 0.0045，缺 _floorEpsilon 补偿会得 449。
    expect(floorToMicroDegree(0.00450), 450);
    expect(gridIdOf(0.00450, 0.00450), '1_1');
  });
}
