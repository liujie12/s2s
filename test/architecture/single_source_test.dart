import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 同源门禁（U9）：`lib/features/{map,discovery}` 里只允许少数文件读「两个源」。
///
/// 为什么用测试而不是脚本：它跟 `flutter test` 同一条命令就能跑，不需要额外的
/// node 运行时；而且违规会以**文件+行号**出现在测试输出里，定位成本最低。
///
/// 允许清单的每一项都必须有理由：
/// - `discovery_filter.dart` / `search_intent.dart`：定义处；
/// - `effective_filter_provider.dart`：唯一读点，投影与进度态都在这里合成；
/// - `search_conditions.dart`：唯一写点（门面）。
void main() {
  const Set<String> allowed = {
    'discovery_filter.dart',
    'search_intent.dart',
    'effective_filter_provider.dart',
    'search_conditions.dart',
  };

  /// 两个源的名字；任何一处直接引用都意味着又出现了第二份回落规则。
  const List<String> forbidden = [
    'discoveryFilterProvider',
    'searchIntentProvider',
  ];

  test('地图与探索域不再直接读持久筛选 / 搜索槽位', () {
    final List<String> violations = <String>[];

    for (final String dir in ['lib/features/map', 'lib/features/discovery']) {
      final Directory directory = Directory(dir);
      if (!directory.existsSync()) continue;
      for (final FileSystemEntity entity in directory.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final String name = entity.uri.pathSegments.last;
        if (allowed.contains(name)) continue;
        final List<String> lines = entity.readAsLinesSync();
        for (int i = 0; i < lines.length; i++) {
          final String line = lines[i];
          // 注释里提到名字不算违规：它常常是在解释「为什么不再直接读」。
          final String trimmed = line.trimLeft();
          if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
          for (final String symbol in forbidden) {
            if (line.contains(symbol)) {
              violations.add('${entity.path}:${i + 1} → $symbol');
            }
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '发现第二读写点：\n${violations.join('\n')}\n'
          '请改为读 effectiveFilterProvider / 写 searchConditionsProvider。',
    );
  });
}
