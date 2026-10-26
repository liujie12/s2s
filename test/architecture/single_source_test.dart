import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 同源门禁（U9）：`lib/features` 下只允许少数**文件路径**读「两个源」。
///
/// 为什么用测试而不是脚本：它跟 `flutter test` 同一条命令就能跑，不需要额外的
/// node 运行时；而且违规会以**文件+行号**出现在测试输出里，定位成本最低。
///
/// 为什么要按完整路径而不是文件名白名单：同名文件（例如别处再建一个
/// `search_conditions.dart`）会直接绕过按文件名的白名单。
///
/// 允许清单的每一项都必须有理由：
/// - `discovery_filter.dart` / `search_intent.dart`：定义处；
/// - `effective_filter_provider.dart`：唯一读点，投影与进度态都在这里合成；
/// - `search_conditions.dart`：唯一写点（门面）。
void main() {
  const Set<String> allowedPaths = {
    'lib/features/discovery/discovery_filter.dart',
    'lib/features/discovery/search_intent.dart',
    'lib/features/discovery/effective_filter_provider.dart',
    'lib/features/discovery/search_conditions.dart',
  };

  /// 两个源的名字；任何一处直接引用都意味着又出现了第二份回落规则。
  const List<String> forbidden = [
    'discoveryFilterProvider',
    'searchIntentProvider',
  ];

  test('lib/features 下不再直接读持久筛选 / 搜索槽位', () {
    final List<String> violations = <String>[];

    final Directory root = Directory('lib/features');
    if (!root.existsSync()) {
      fail('找不到 lib/features，测试须在仓库根目录运行');
    }

    for (final FileSystemEntity entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String path = entity.path.replaceAll('\\', '/');
      if (allowedPaths.any(path.endsWith)) continue;
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        final String line = lines[i];
        // 注释里提到名字不算违规：它常常是在解释「为什么不再直接读」。
        final String trimmed = line.trimLeft();
        if (trimmed.startsWith('//') || trimmed.startsWith('///')) continue;
        for (final String symbol in forbidden) {
          if (line.contains(symbol)) {
            violations.add('$path:${i + 1} -> $symbol');
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
