/// 计数可见性守门测试（U8 / R9 / R11）。
///
/// 判据：浏览数与收藏数**只对帖主可见**。契约层可机器判的部分有三条：
///   1. 他人视角的列表卡片（`PostCard`）不含任何计数语义键；
///   2. 详情（`PostDetail`）不含计数语义键（只允许收藏态 `favorited`，
///      它是「我是否收藏」不是计数）；
///   3. 帖主视角模型 `MyPostItem` 只被 `GET /posts/mine` 引用。
///
/// 这三条是「计数不对外」在契约上的可判边界：任何一处被放开，
/// 都会让计数出现在发现列表、详情或分享页，撞 PRD 的非商业化口径。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import '../support/test_support.dart';

/// 计数语义键（命中任一即视为计数外泄）。
const Set<String> _countKeys = {
  'view_count',
  'favorite_count',
  'contact_count',
};

/// 取模型属性表。
///
/// 参数：[spec] 契约；[name] 模型名。
/// 返回：[YamlMap] properties（模型或属性缺失时为空映射）。
YamlMap _propsOf(OpenApiSpec spec, String name) {
  final schema = spec.schemas?[name] as YamlMap?;
  final properties = schema?['properties'] as YamlMap?;
  return properties ?? (loadYaml('{}') as YamlMap);
}

void main() {
  late final OpenApiSpec spec;
  setUpAll(() {
    assertRepoLayout();
    spec = OpenApiSpec.load();
  });

  test('PostCard 不含任何计数语义键（发现列表/地图卡片不展示计数）', () {
    final props = _propsOf(spec, 'PostCard');
    expect(props, isNotEmpty, reason: '判据对象不存在：PostCard 模型缺失');
    final leaked = _countKeys.where(props.containsKey).toList();
    expect(leaked, isEmpty, reason: 'PostCard 出现计数键：$leaked');
  });

  test('PostDetail 不含计数语义键（详情页不展示计数，仅收藏态）', () {
    final props = _propsOf(spec, 'PostDetail');
    expect(props, isNotEmpty, reason: '判据对象不存在：PostDetail 模型缺失');
    final leaked = _countKeys.where(props.containsKey).toList();
    expect(leaked, isEmpty, reason: 'PostDetail 出现计数键：$leaked');
    expect(props.containsKey('favorited'), isTrue,
        reason: '收藏态不是计数，详情页必须保留');
  });

  test('MyPostItem 保留两个计数（帖主视角的计数来源）', () {
    final props = _propsOf(spec, 'MyPostItem');
    expect(props.containsKey('view_count'), isTrue);
    expect(props.containsKey('favorite_count'), isTrue);
  });

  test('MyPostItem 只被 GET /posts/mine 引用', () {
    final holders = <String>[];
    for (final op in spec.operations()) {
      if (!op.raw.toString().contains('MyPostItem')) continue;
      holders.add('${op.method.toUpperCase()} ${op.path}');
    }
    expect(holders, isNotEmpty, reason: 'MyPostItem 未被任何接口引用');
    expect(
      holders,
      everyElement(equals('GET /posts/mine')),
      reason: '帖主计数模型不得被其它接口复用：$holders',
    );
  });
}
