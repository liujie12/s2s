/// 驾车路径摘要解析与降级守门测试（计划 R7 / R13）。
///
/// **这些断言防的是什么**：距离与时长是「这条路顺不顺」的唯一量化依据。
/// 解析器把 `status=0`（配额或 Key 问题）当成成功返回 0 米，会让页面显示
/// 「约 0 km」——用户看到的是一个错误的确定值，而非「暂时没有」。故所有
/// 失败分支必须回到 null，由页面隐藏整段（R13）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/location/driving_route.dart';

void main() {
  group('parseDrivingSummary 正常路径', () {
    test('取第一条路径的米与秒', () {
      final summary = parseDrivingSummary(<String, Object?>{
        'status': '1',
        'route': <String, Object?>{
          'paths': <Object?>[
            <String, Object?>{'distance': 18500, 'duration': 2100},
            <String, Object?>{'distance': 20000, 'duration': 2400},
          ],
        },
      });

      expect(summary, isNotNull);
      expect(summary!.distanceM, 18500);
      expect(summary.durationS, 2100);
    });

    test('数值是浮点 → 取整数部分（米 / 秒）', () {
      final summary = parseDrivingSummary(<String, Object?>{
        'status': '1',
        'route': <String, Object?>{
          'paths': <Object?>[
            <String, Object?>{'distance': 18500.6, 'duration': 2100.2},
          ],
        },
      });

      expect(summary?.distanceM, 18500);
      expect(summary?.durationS, 2100);
    });
  });

  group('parseDrivingSummary 失败路径', () {
    test('paths 为空 → null', () {
      expect(
        parseDrivingSummary(<String, Object?>{
          'status': '1',
          'route': <String, Object?>{'paths': <Object?>[]},
        }),
        isNull,
      );
    });

    test('status != 1 → null（不返回 0 距离）', () {
      expect(
        parseDrivingSummary(<String, Object?>{'status': '0', 'info': 'INVALID_USER_KEY'}),
        isNull,
      );
    });

    test('缺 route / paths 或数值类型不符 → null', () {
      expect(parseDrivingSummary(<String, Object?>{'status': '1'}), isNull);
      expect(
        parseDrivingSummary(<String, Object?>{
          'status': '1',
          'route': <String, Object?>{
            'paths': <Object?>[
              <String, Object?>{'distance': '很远', 'duration': 2100},
            ],
          },
        }),
        isNull,
      );
    });

    test('非 Map → null', () {
      expect(parseDrivingSummary(null), isNull);
      expect(parseDrivingSummary('oops'), isNull);
    });
  });

  group('请求侧降级', () {
    test('未注入 Key → 不发请求，返回 null', () async {
      final client = _ThrowingHttpClient();

      final summary = await fetchDrivingSummary(
        originLng: 116.337,
        originLat: 40.071,
        destinationLng: 116.316,
        destinationLat: 39.983,
        client: client,
      );

      expect(summary, isNull);
      expect(client.used, isFalse);
    });
  });
}

/// 一被使用就抛异常的 HttpClient（验证「未配置 Key 时不发请求」）。
class _ThrowingHttpClient implements HttpClient {
  /// 是否被调用过（任一请求入口）。
  bool used = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    used = true;
    throw StateError('不应发起网络请求');
  }
}
