import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/listing_category_style.dart';
import 'package:zhaoyazhao/widgets/category_glyph.dart';

/// 叶子图标契约：非空、全树唯一、可解析或已列入待自绘。
///
/// 为什么要有这条测试：图标按「Material 名」存，名字写错不会编译报错，
/// 只会在运行时静默退回一级图标；重复字形也不会报错，只会让两个类目看起来一样。
/// 两者都属「看起来正常、实际错了」的缺陷，只能靠数据断言拦住。
void main() {
  test('叶子图标名非空', () {
    final missing = leafCategories
        .where((n) => (n.icon ?? '').isEmpty)
        .map((n) => '${n.id} ${n.name}')
        .toList();
    expect(missing, isEmpty, reason: '以下叶子未登记图标名：$missing');
  });

  test('叶子图标名全集唯一', () {
    final seen = <String, List<int>>{};
    for (final n in leafCategories) {
      seen.putIfAbsent(n.icon ?? '', () => <int>[]).add(n.id);
    }
    final dup = seen.entries.where((e) => e.value.length > 1).map((e) => '${e.key} → ${e.value}');
    expect(dup, isEmpty, reason: '以下字形被多个叶子复用：${dup.join('，')}');
  });

  test('图标名可解析（Material 或自绘）', () {
    final unresolved = <String>[];
    for (final n in leafCategories) {
      final name = n.icon ?? '';
      if (categoryIconByName(name) != null) continue;
      if (hasCustomCategoryGlyph(name)) continue;
      unresolved.add('${n.id} ${n.name} → $name');
    }
    expect(unresolved, isEmpty, reason: '以下名字既未注册也没有自绘实现：${unresolved.join('，')}');
  });
}
