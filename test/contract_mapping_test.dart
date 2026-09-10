/// 本地模型与契约之间的映射守门测试（详细设计 §10.4）。
///
/// 这些断言防的是**「一半能跑」**这类缺陷：
///
/// 1. 供需态在三处有三套表示法 —— 本地 `SupplyDemand.supply`/`demand`、
///    契约 `PostTypeEnum` 的 `"resource"`/`"demand"`、紧凑数组的 `0`/`1`。
///    其中 `demand` 三处同名、`supply` 与 `resource` 不同名。若用
///    `values.byName` 做转换，需求态会通过、资源态会抛异常 —— 只测
///    `demand` 一条就会得到「映射没问题」的错误结论，所以两个方向、
///    两个取值都必须各有断言。
/// 2. 紧凑数组的 `0`/`1` 与枚举 `index` 当前恰好一致，`values[code]`
///    靠巧合能跑。枚举顺序一变就错，而那时没人会想到查这里。
/// 3. 半径的全城档：本地是 `km == null`，契约是字符串 `'city'`。
///    若写成 `km.toString()` 会得到字面量 `"null"`，服务端回 40001 而
///    客户端只说「参数错误」。因此必须显式断言结果**不等于** `'null'`。
/// 4. 叶子类目 ID 反查大类：查不到时必须返回 null 而非抛异常或崩溃 ——
///    本地分类树版本落后于服务端数据属预期内状态（§16.4）。
///
/// 运行：flutter test test/contract_mapping_test.dart
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/features/discovery/discovery_filter.dart';

void main() {
  group('供需态：契约 post_type ↔ 本地枚举（§10.4.2）', () {
    test('resource → supply', () {
      // 这一条是 values.byName 会漏掉的那条：契约叫 resource，本地叫 supply。
      expect(supplyDemandFromApi('resource'), SupplyDemand.supply);
    });

    test('demand → demand', () {
      // 三处同名，正是它让「一半能跑」看起来像「全都能跑」。
      expect(supplyDemandFromApi('demand'), SupplyDemand.demand);
    });

    test('契约外取值抛 ApiException(parseError)，不静默兜底', () {
      // 兜底成 supply 会让需求信息被当资源展示 —— 用户看到的是内容错位，
      // 而日志里没有任何痕迹。
      expect(
        () => supplyDemandFromApi('supply'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            ApiErrorCode.parseError,
          ),
        ),
      );
    });

    test('supply → resource：上行方向不能写成 sd.name', () {
      // sd.name 得到的是 'supply'，与契约的 'resource' 不符。
      expect(toApiPostType(SupplyDemand.supply), 'resource');
      expect(toApiPostType(SupplyDemand.supply), isNot('supply'));
    });

    test('demand → demand：上行方向', () {
      expect(toApiPostType(SupplyDemand.demand), 'demand');
    });

    test('双向映射闭环：转出去再转回来必须相等', () {
      for (final sd in SupplyDemand.values) {
        expect(supplyDemandFromApi(toApiPostType(sd)), sd);
      }
    });
  });

  group('供需态：紧凑数组 type 码 ↔ 本地枚举（§10.4.2）', () {
    test('0 → supply、1 → demand', () {
      expect(supplyDemandFromCompact(0), SupplyDemand.supply);
      expect(supplyDemandFromCompact(1), SupplyDemand.demand);
    });

    test('契约外码值抛 ApiException(parseError)，不是 RangeError', () {
      // values[code] 的写法在 code=2 时抛 RangeError —— 那是个「下标越界」的
      // 报错，看不出是契约不一致。显式 switch 才能给出可定位的信息。
      expect(
        () => supplyDemandFromCompact(2),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => supplyDemandFromCompact(-1),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('搜索半径：本地 int? ↔ 契约字符串（§10.4.3）', () {
    test('全城档得到 city，且绝不能是字面量 null', () {
      final raw = toApiRadius(SearchRadius.city);
      expect(raw, 'city');
      // 这一条是本组最关键的断言：km.toString() 会让它变成 'null'，
      // 而 'null' 是个合法字符串，编译期与运行期都不会有任何提示。
      expect(raw, isNot('null'));
    });

    test('数值档得到不带单位的纯数字字符串', () {
      expect(toApiRadius(SearchRadius.km1), '1');
      expect(toApiRadius(SearchRadius.km3), '3');
      expect(toApiRadius(SearchRadius.km5), '5');
      expect(toApiRadius(SearchRadius.km10), '10');
    });

    test('契约字符串回本地枚举：五档都要能回来', () {
      expect(searchRadiusFromApi('1'), SearchRadius.km1);
      expect(searchRadiusFromApi('3'), SearchRadius.km3);
      expect(searchRadiusFromApi('5'), SearchRadius.km5);
      expect(searchRadiusFromApi('10'), SearchRadius.km10);
      expect(searchRadiusFromApi('city'), SearchRadius.city);
    });

    test('双向映射闭环：五档全覆盖', () {
      for (final r in SearchRadius.values) {
        expect(searchRadiusFromApi(toApiRadius(r)), r);
      }
    });

    test('契约外取值抛 ApiException(parseError)', () {
      expect(() => searchRadiusFromApi('20'), throwsA(isA<ApiException>()));
      // 'null' 也必须被拒：它正是 km.toString() 那个 bug 的产物，
      // 若这里兜底成全城，缺陷就再也不会暴露。
      expect(() => searchRadiusFromApi('null'), throwsA(isA<ApiException>()));
    });
  });

  group('叶子类目 ID → 一级大类（§10.4.1）', () {
    test('树里每个叶子都能查到它所属的大类', () {
      for (var i = 0; i < categoryTree.length; i++) {
        final expected = ListingCategory.values[i];
        for (final mid in categoryTree[i].children) {
          for (final leaf in mid.children) {
            expect(
              topCategoryOf(leaf.id),
              expected,
              reason: '叶子「${leaf.name}」(${leaf.id}) 查不到正确大类 —— 会导致配色串类',
            );
          }
        }
      }
    });

    test('树里查不到的叶子 ID 返回 null，而不是抛异常也不是崩溃', () {
      // 这是 §16.4 的预期内状态：本地分类树版本落后于服务端数据。
      // 调用方应降级为中性配色，而不是丢弃该条数据。
      expect(topCategoryOf(99999), isNull);
    });

    test('服务端叶子 ID 不会被当成枚举下标 —— 这是那个 release 崩溃的守卫', () {
      // 旧实现是 ListingCategory.values[id]，10101 会抛 RangeError，
      // 且 debug 下先被 assert 拦住，只有 release 包才崩。
      expect(() => topCategoryOf(10101), returnsNormally);
      expect(topCategoryOf(10101), ListingCategory.work);
    });

    test('一级 / 二级编号不是叶子，查不到 —— 分桶必须用叶子口径', () {
      // 契约 PinsCompactResponse.category_id 给的是叶子；若服务端某天下发
      // 二级 ID，这里返回 null 会走中性配色，而不是静默按错的大类配色。
      expect(topCategoryOf(1), isNull);
      expect(topCategoryOf(101), isNull);
    });
  });

  group('CategoryNode.topCategory 的可空化（§10.4.1）', () {
    test('一级编号越界不抛 RangeError —— values[top-1] 的替代守卫', () {
      // 旧实现 ListingCategory.values[top - 1] 在一级编号超出 1..5 时抛
      // RangeError，且 release 下 assert 不参与编译，只能靠这条断言钉住。
      const node = CategoryNode(id: 9, name: '未知大类', children: []);
      expect(() => node.topCategory, returnsNormally);
      expect(node.topCategory, isNull);
    });

    test('合法一级编号仍能正确推导', () {
      const node = CategoryNode(id: 1, name: '工作', children: []);
      expect(node.topCategory, ListingCategory.work);
    });
  });
}
