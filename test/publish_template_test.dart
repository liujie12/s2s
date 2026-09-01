/// 发布模板引擎守门测试（PRD §5.4.3 模板差异表 / §5.7 模板引擎 / §5.8 模板缺配）。
///
/// **这些断言防的是什么**：模板是一坨手写常量，键是 §2.4 的二级编号。
/// 把 501（家政/保洁）误写成 502（维修安装）不会报任何错 —— 表现只是
/// 「选了家政却出现维修的字段」，而这种错在人眼过页面时极难发现，
/// 因为两套字段看上去都像那么回事（条目 [71] 的 `_samplePath` 是同一类错）。
///
/// 因此本文件的重点是**把「模板键 = §2.4 二级编号」这条隐式约定变成会失败的断言**：
/// 不比对常量与常量，而是拿模板键去分类树里查出真实名称，与 §5.4.3 的行名对照。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/publish_template.dart';

void main() {
  group('模板键与 §2.4 分类树对数（契约：§5.4.3 四行的二级名称）', () {
    // 右侧是 §5.4.3 表格首列的类目名，用字面量钉死（原则 134）——
    // 若改从 category_tree 取名字，这条断言就退化成「代码与自己相等」。
    const expected = <int, String>{
      401: '二手闲置转让',
      501: '家政/保洁',
      301: '顺风车/拼车',
      101: '全职招聘',
    };

    for (final entry in expected.entries) {
      test('二级 ${entry.key} 在分类树里确实是「${entry.value}」', () {
        // 拿该二级下第一个叶子反查路径，路径中段即二级名。
        final leafId = entry.key * 100 + 1;
        final path = categoryPathOf(leafId);
        expect(path, hasLength(3), reason: '叶子 $leafId 不存在，模板键指向了空类目');
        expect(path[1].name, entry.value);
      });

      test('二级 ${entry.key} 的每个叶子都命中同一份模板（模板挂二级的前提）', () {
        final mid = categoryPathOf(entry.key * 100 + 1)[1];
        final ids = {for (final leaf in mid.children) templateForLeaf(leaf.id).id};
        // 同一二级下所有叶子必须共用一份模板 —— 若不然，「模板挂二级」
        // 这个设计前提就不成立，而它不成立的表现是某些叶子悄悄降级成通用模板。
        expect(ids, hasLength(1));
        expect(ids.single, isNot(genericTemplateId));
      });
    }
  });

  group('§5.4.3 四份模板的字段与文案', () {
    test('二手闲置：标题 placeholder 与必填「新旧程度」', () {
      final t = templateForLeaf(40101);
      expect(t.id, '4.1');
      expect(t.titlePlaceholder, '【转让】品牌+物品');
      // §5.4.3 附加字段列写的是「新旧程度选单、取件方式」
      final keys = t.extraFields.map((f) => f.key).toList();
      expect(keys, ['condition', 'pickup']);
      expect(t.extraFields.first.type, TemplateFieldType.select);
      expect(t.extraFields.first.required, isTrue);
    });

    test('家政保洁：价格单位含 ㎡ / 小时 / 次（§5.4.3「价格 + 单位（㎡/小时/次）」）', () {
      final t = templateForLeaf(50101);
      expect(t.id, '5.1');
      expect(t.priceUnits, contains('元/小时'));
      expect(t.priceUnits, contains('元/次'));
      expect(t.priceUnits, contains('元/㎡'));
    });

    test('拼车：起点终点 / 出发时间 / 空座数三项必填（§5.4.3 附加字段列）', () {
      final t = templateForLeaf(30101);
      expect(t.id, '3.1');
      final required = t.extraFields.where((f) => f.required).map((f) => f.key);
      expect(required, containsAll(['route', 'depart_time', 'seats']));
    });

    test('全职招聘：价格单位为月薪（§5.4.3「月薪范围/月」）', () {
      final t = templateForLeaf(10101);
      expect(t.id, '1.1');
      expect(t.priceUnits.first, '元/月');
    });

    test('每份模板的 priceUnits 都含「面议」—— §5.8「允许选面议不填数字」的出口', () {
      for (final leafId in [40101, 50101, 30101, 10101]) {
        expect(
          templateForLeaf(leafId).priceUnits,
          contains('面议'),
          reason: '叶子 $leafId 的模板没有面议单位，价格必填就成了死路',
        );
      }
      expect(genericTemplate.priceUnits, contains('面议'));
    });

    test('所有模板字段 key 唯一 —— 重复 key 会让后写的值覆盖前一个', () {
      for (final leafId in [40101, 50101, 30101, 10101]) {
        final keys = templateForLeaf(leafId).extraFields.map((f) => f.key);
        expect(keys.toSet(), hasLength(keys.length), reason: '叶子 $leafId 有重复 key');
      }
    });

    test('select 类型必须带 options，其他类型必须不带（否则渲染成空选单）', () {
      for (final leafId in [40101, 50101, 30101, 10101]) {
        for (final f in templateForLeaf(leafId).extraFields) {
          if (f.type == TemplateFieldType.select) {
            expect(f.options, isNotEmpty, reason: '${f.key} 是选单却没有候选值');
          } else {
            expect(f.options, isEmpty, reason: '${f.key} 不是选单却带了候选值');
          }
        }
      }
    });
  });

  group('§5.8 模板缺配 → 降级通用模板', () {
    test('未配模板的二级（如 402 借物互助）降级为通用模板', () {
      final t = templateForLeaf(40201);
      expect(t.isGeneric, isTrue);
      // 通用模板的最少字段口径：标题 + 价格 + 描述 + 位置，故无附加字段
      expect(t.extraFields, isEmpty);
    });

    test('脏 ID（分类树里不存在的编号）也降级而不抛错', () {
      // 旧草稿、服务端下发、分类改版都会产出这种编号。抛错等于让一条
      // 旧草稿把发布页打崩。
      expect(templateForLeaf(999999).isGeneric, isTrue);
      expect(templateForLeaf(0).isGeneric, isTrue);
      expect(templateForLeaf(-1).isGeneric, isTrue);
    });

    test('48 个叶子全部能取到模板，且四类命中专属模板、其余走通用', () {
      var specific = 0;
      for (final leaf in leafCategories) {
        final t = templateForLeaf(leaf.id);
        if (!t.isGeneric) specific++;
      }
      // 命中数 = 四个二级下的叶子总数。写成由树算出的期望值而非硬编码数字：
      // 这里要守的是「这四个二级一个不漏」，而叶子数会随类目增删变动。
      final expectedHits = [401, 501, 301, 101]
          .map((mid) => categoryPathOf(mid * 100 + 1)[1].children.length)
          .reduce((a, b) => a + b);
      expect(specific, expectedHits);
      // 同时守住「不是全都命中」—— 若模板查表退化成「任何 ID 都返回同一份」，
      // 上面那条断言反而会绿（原则 133/134 同族）。
      expect(specific, lessThan(leafCategories.length));
    });
  });

  group('§5.8 强制认证拦截的判定依据', () {
    test('高敏叶子返回对应资质：家政 → 个人资质', () {
      final leafId = categoryPathOf(50101)[2].id;
      expect(requiredCertForLeaf(leafId), RequiredCert.personalQualification);
    });

    test('二手闲置等普通类目返回 none', () {
      expect(requiredCertForLeaf(40101), RequiredCert.none);
    });

    test('脏 ID 返回 none 而非抛错或随便挑一个资质', () {
      // 拦在一个用户无法通过的认证前面会变成死路（他没有这个类目，
      // 也就永远补不齐这项资质）。
      expect(requiredCertForLeaf(999999), RequiredCert.none);
    });
  });
}
