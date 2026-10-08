/// 探索页请求参数组装测试（[126] 前端段）。
///
/// 锁定两处最容易静默出错的映射：叶子类目展开（传大类 ID 会恒返空结果）、
/// 供需双选切分（契约只收单值）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/discovery_query.dart';

void main() {
  group('leafCategoryIdsFor', () {
    test('空集（全部分类）展开为全部叶子，等于常量树的叶子总数', () {
      final ids = leafCategoryIdsFor(const {});

      expect(ids, hasLength(leafCategories.length));
      expect(ids, contains(10101));
      expect(ids, contains(50502));
      // 展开的必须是叶子 ID（5 位），不是大类 ID（1 位）
      expect(ids.every((id) => id >= 10000), isTrue);
    });

    test('选定「工作」只展开工作下的叶子，不含房屋等其它大类', () {
      final ids = leafCategoryIdsFor(const {ListingCategory.work});

      expect(ids, hasLength(9));
      expect(ids, containsAll(const [10101, 10102, 10103, 10104, 10105]));
      expect(ids, containsAll(const [10201, 10202, 10203, 10301]));
      expect(ids, isNot(contains(20101)));
    });

    test('多选为各大类叶子的并集', () {
      final ids = leafCategoryIdsFor(const {
        ListingCategory.work,
        ListingCategory.house,
      });

      expect(ids, contains(10101));
      expect(ids, contains(20101));
      expect(ids, isNot(contains(30101)));
      // 工作 9 + 房屋 6（201xx 3 + 202xx 1 + 203xx 1 + 204xx 1）
      expect(ids, hasLength(15));
    });
  });

  group('postTypesFor', () {
    test('空集不发请求（空列表，不是全选）', () {
      expect(postTypesFor(const {}), isEmpty);
    });

    test('单选 resource / demand 各为一个单值', () {
      expect(postTypesFor(const {SupplyDemand.supply}), const ['resource']);
      expect(postTypesFor(const {SupplyDemand.demand}), const ['demand']);
    });

    test('双选切分为两个值，且顺序固定 resource 在前（pins 拆两次 / search 拼逗号）', () {
      expect(
        postTypesFor(const {SupplyDemand.supply, SupplyDemand.demand}),
        const ['resource', 'demand'],
      );
      // 与集合的插入顺序无关
      expect(
        postTypesFor(const {SupplyDemand.demand, SupplyDemand.supply}),
        const ['resource', 'demand'],
      );
    });
  });
}
