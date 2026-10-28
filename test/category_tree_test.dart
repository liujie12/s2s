/// 分类树守门测试（PRD §2.3 上限 / §2.4 三级树 / §4.3 认证 / §13.2 自引用表）。
///
/// 这些断言防的是同一类错：**分类树是一大坨手写常量，抄错不会报错**。
/// 上一版详情页的 `_samplePath` 就是明证 —— 它写着「房屋 > 整租 > 一室一厅」
/// 与「家政 > 保洁 > 日常保洁」，两处都与 §2.4 不符，却在库里安静躺了一个里程碑，
/// 因为没有任何一处代码拿它跟真源比过。
///
/// 因此本文件的重点不在覆盖率，而在**把「ID 编号规则」这条隐式约定变成会失败的断言**：
/// `categoryPathOf` 靠整除回溯，一旦有人手写了个不合规则的 ID（例如二级挂错父级），
/// 回溯会静默返回空列表，表现是「某个分类的面包屑不显示」——
/// 这种缺陷在页面上极不显眼，正属机读盲区与人眼盲区的重叠处。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/listing_category.dart';
import 'package:zhaoyazhao/domain/listing_category_style.dart';

void main() {
  group('结构规模与层级', () {
    test('恰好三层：一级有子、二级有子、三级为叶 —— 不允许出现二层或四层分支', () {
      for (final top in categoryTree) {
        expect(top.isLeaf, isFalse, reason: '一级「${top.name}」没有二级子类');
        for (final mid in top.children) {
          expect(mid.isLeaf, isFalse, reason: '二级「${mid.name}」没有叶子');
          for (final leaf in mid.children) {
            // 四层会让 categoryPathOf 的整除回溯彻底失效，且 §5.4.2 的级联
            // 选择器只有三列，多出的一层在 UI 上无处可选。
            expect(leaf.isLeaf, isTrue, reason: '叶子「${leaf.name}」还有子节点');
          }
        }
      }
    });

    test('一级恰为五大类且顺序与 ListingCategory 一致 —— 顺序即分类栏展示顺序（§6.4.1）', () {
      expect(categoryTree.length, ListingCategory.values.length);
      for (var i = 0; i < categoryTree.length; i++) {
        expect(categoryTree[i].name, ListingCategory.values[i].label);
      }
    });

    test('叶子总数不超过 60（§2.3 首期上限）', () {
      // 上限是产品定的运营约束：类目越多，发布时选择成本越高。
      // 这条断言会在有人「顺手多加几个类目」时失败，而这正是它存在的目的。
      expect(leafCategories.length, lessThanOrEqualTo(60));
      // 同时守下界：树被误删一半时长度会骤降，而页面只表现为「少了些选项」。
      expect(leafCategories.length, 48);
    });
  });

  group('ID 编号规则自洽（categoryPathOf 的整除回溯依赖它）', () {
    test('二级 ID = 一级*100+M，叶子 ID = 二级*100+K —— 挂错父级即失败', () {
      for (final top in categoryTree) {
        for (final mid in top.children) {
          expect(
            mid.id ~/ 100,
            top.id,
            reason: '二级「${mid.name}」(${mid.id}) 的父级不是「${top.name}」(${top.id})',
          );
          for (final leaf in mid.children) {
            expect(
              leaf.id ~/ 100,
              mid.id,
              reason: '叶子「${leaf.name}」(${leaf.id}) 的父级不是「${mid.name}」(${mid.id})',
            );
          }
        }
      }
    });

    test('全树 ID 无重复 —— 重复会让 firstOrNull 取到先出现的那个，静默串味', () {
      final ids = <int>[
        for (final top in categoryTree) ...[
          top.id,
          for (final mid in top.children) ...[
            mid.id,
            for (final leaf in mid.children) leaf.id,
          ],
        ],
      ];
      expect(ids.toSet().length, ids.length);
    });

    test('叶子 ID 均为五位、二级三位 —— 位数即层级，位数错则回溯必然落空', () {
      for (final top in categoryTree) {
        expect(top.id, inInclusiveRange(1, 9));
        for (final mid in top.children) {
          expect(mid.id, inInclusiveRange(100, 999));
          for (final leaf in mid.children) {
            expect(leaf.id, inInclusiveRange(10000, 99999));
          }
        }
      }
    });

    test('topCategory 由 id 推导的结果与其实际所在分支一致（三层都要对）', () {
      for (var i = 0; i < categoryTree.length; i++) {
        final top = categoryTree[i];
        final expected = ListingCategory.values[i];
        expect(top.topCategory, expected);
        for (final mid in top.children) {
          expect(mid.topCategory, expected, reason: '二级「${mid.name}」推导出的大类错了');
          for (final leaf in mid.children) {
            expect(
              leaf.topCategory,
              expected,
              reason: '叶子「${leaf.name}」推导出的大类错了 —— 会导致配色串类',
            );
          }
        }
      }
    });
  });

  group('面包屑回溯', () {
    test('每个叶子都能回溯出完整三级 —— 有一个回溯不出就是一处不显示面包屑的页面', () {
      for (final leaf in leafCategories) {
        final path = categoryPathOf(leaf.id);
        expect(path.length, 3, reason: '叶子「${leaf.name}」(${leaf.id}) 回溯失败');
        expect(path.last.id, leaf.id);
      }
    });

    test('给定叶子回溯出的名称即 §2.4 原文路径', () {
      expect(
        categoryPathOf(10101).map((n) => n.name).toList(),
        ['工作', '全职招聘', '餐饮服务'],
      );
      // 这条刻意选中曾被写错的分支：旧字面量写作「房屋 > 整租 > 一室一厅」，
      // §2.4 的真实叶子是「整租出租」，二级是「整租/合租」。
      expect(
        categoryPathOf(20103).map((n) => n.name).toList(),
        ['房屋', '整租/合租', '整租出租'],
      );
      // 同上：旧字面量把一级写成了「家政」，实为「服务」。
      expect(
        categoryPathOf(50101).map((n) => n.name).toList(),
        ['服务', '家政/保洁', '日常保洁'],
      );
    });

    test('脏 ID 返回空列表而非抛异常 —— 运营删类目而旧帖仍指向它，在生产会发生', () {
      expect(categoryPathOf(99999), isEmpty); // 一级不存在
      expect(categoryPathOf(10999), isEmpty); // 二级不存在
      expect(categoryPathOf(10199), isEmpty); // 叶子不存在
      expect(categoryPathOf(0), isEmpty);
      expect(categoryPathOf(-1), isEmpty);
      // 传了个二级 ID 而非叶子 ID：也须落空，不能误当叶子处理。
      expect(categoryPathOf(101), isEmpty);
    });

    test('leafCategoryById 命中返回叶子、脏 ID 返回 null', () {
      expect(leafCategoryById(40102)?.name, '母婴儿童');
      expect(leafCategoryById(40199), isNull);
    });
  });

  group('高敏认证标记（§4.3）', () {
    test('服务类 5.x 全部叶子强制个人资质 —— §4.3 明写，一个漏标即一个绕过口', () {
      final service = categoryTree.firstWhere((n) => n.id == 5);
      for (final mid in service.children) {
        for (final leaf in mid.children) {
          expect(
            leaf.requiredCert,
            RequiredCert.personalQualification,
            reason: '服务类叶子「${leaf.name}」未标个人资质',
          );
        }
      }
    });

    test('拼车与租车强制车辆认证；转让与求搭车不强制（不擅自扩大 §4.3 范围）', () {
      expect(leafCategoryById(30101)?.requiredCert, RequiredCert.vehicle);
      expect(leafCategoryById(30201)?.requiredCert, RequiredCert.vehicle);
      // 转让是一次性买卖、求搭车方没有车 —— 强制行驶证等于设一道无法满足的门。
      expect(leafCategoryById(30301)?.requiredCert, RequiredCert.none);
      expect(leafCategoryById(30401)?.requiredCert, RequiredCert.none);
    });

    test('招聘与房源强制企业认证；求职与求租不强制（否则把找工作/找房的人挡在门外）', () {
      expect(leafCategoryById(10101)?.requiredCert, RequiredCert.enterprise);
      expect(leafCategoryById(20103)?.requiredCert, RequiredCert.enterprise);
      expect(leafCategoryById(10301)?.requiredCert, RequiredCert.none);
      expect(leafCategoryById(20201)?.requiredCert, RequiredCert.none);
    });

    test('生活类全部无强制认证 —— 邻里互助若要认证，产品就不成立了', () {
      final life = categoryTree.firstWhere((n) => n.id == 4);
      for (final mid in life.children) {
        for (final leaf in mid.children) {
          expect(leaf.requiredCert, RequiredCert.none, reason: leaf.name);
        }
      }
    });
  });

  group('二级图标映射（PRD §6.4.2 二级图标映射表）', () {
    /// 每个二级取一个代表叶子（本函数只认叶子 ID，二级 ID 直接传入会查不到）。
    List<int> leafIds() => [
      for (final top in categoryTree)
        for (final mid in top.children) mid.children.first.id,
    ];

    test('21 个二级全部有字形，且两两不同 —— 同族共用字形等于没做二级区分', () {
      final ids = leafIds();
      expect(ids.length, 21);
      final icons = [for (final id in ids) l2CategoryIcon(id)];
      expect(
        icons.where((i) => i == null),
        isEmpty,
        reason: '有二级类目没登记字形',
      );
      expect(
        icons.toSet().length,
        ids.length,
        reason: '存在两个二级类目共用同一字形，密集处仍读不出差别',
      );
    });

    test('叶子 ID 能查到所属二级字形；未知叶子与空值返回 null 由调用方降级', () {
      for (final leaf in leafCategories) {
        expect(
          l2CategoryIcon(leaf.id),
          isNotNull,
          reason: '叶子 ${leaf.id}（${leaf.name}）查不到二级字形',
        );
      }
      // 空值与未登记编号必须返回 null 而不是兜底成某个字形：
      // 兜底会把「分类树落后」伪装成「图标选错了」。
      expect(l2CategoryIcon(null), isNull);
      expect(l2CategoryIcon(99999), isNull);
    });

    test('抽查四条：一级母题下沉与两对易混项按 PRD 表落位', () {
      expect(l2CategoryIcon(10101), Icons.work); // 101 与一级同形（母题下沉）
      expect(l2CategoryIcon(40202), Icons.volunteer_activism); // 402 同上
      expect(l2CategoryIcon(40301), Icons.search); // 403 找物
      expect(l2CategoryIcon(30401), Icons.hail); // 304 求搭车，与 301 同乘区分
    });
  });

  group('服务端 icon 名解析（DB `category.icon` → API → domain → 渲染）', () {
    /// PRD §6.4.2 两表「Material 名」列：一级 5 + 二级 21。
    ///
    /// 这里是**名字清单的守门断言**：PRD 改表而代码漏跟时，它会失败。
    const names = [
      // 一级
      'work',
      'home',
      'directions_car',
      'volunteer_activism',
      'build',
      // 二级（2026-10-28 定稿）
      'work_history',
      'person_search',
      'apartment',
      'real_estate_agent',
      'hotel',
      'support_agent',
      'airport_shuttle',
      'car_rental',
      'sell',
      'hail',
      'inventory_2',
      'search',
      'pets',
      'campaign',
      'cleaning_services',
      'home_repair_service',
      'school',
      'spa',
      'directions_run',
    ];

    test('PRD 两表的名字全部可解析；null 与未知名返回 null 交调用方降级', () {
      for (final String name in names) {
        expect(categoryIconByName(name), isNotNull, reason: '未登记字形：$name');
      }
      // 不兜底成某个字形：兜底会把「服务端换了图标名」伪装成「图标选错了」。
      expect(categoryIconByName(null), isNull);
      expect(categoryIconByName('not_a_material_symbol'), isNull);
    });

    test('按二级 ID 与按叶子 ID 查同一字形（两条入口不许漂移）', () {
      for (final top in categoryTree) {
        for (final mid in top.children) {
          final icon = l2CategoryIconOfMid(mid.id);
          expect(icon, isNotNull, reason: '二级 ${mid.id}（${mid.name}）无字形');
          expect(
            l2CategoryIcon(mid.children.first.id),
            icon,
            reason: '二级 ${mid.id} 的叶子入口与二级入口字形不一致',
          );
        }
      }
      expect(l2CategoryIconOfMid(null), isNull);
      expect(l2CategoryIconOfMid(999), isNull);
    });

    test('nodeIconOf 四级回退：服务端名 → 本地二级 → 一级 → 中性', () {
      // 1) 服务端名优先：故意给 101 一个与本地映射（work）不同的名。
      expect(
        nodeIconOf(const CategoryNode(id: 101, name: '全职招聘', icon: 'pets')),
        Icons.pets,
      );
      // 2) 无服务端名 → 本地二级映射（101 = work）。二级节点带子节点，
      //    故按 isLeaf=false 走「二级 ID」入口（不带子节点会被当成叶子）。
      expect(
        nodeIconOf(
          const CategoryNode(
            id: 101,
            name: '全职招聘',
            children: [CategoryNode(id: 10101, name: '餐饮服务')],
          ),
        ),
        Icons.work,
      );
      // 3) 叶子按所属二级取字形（10101 → 101）。
      expect(nodeIconOf(const CategoryNode(id: 10101, name: '餐饮服务')), Icons.work);
      // 4) 一级查不到二级（id=1 → 0），落一级枚举。
      expect(nodeIconOf(const CategoryNode(id: 2, name: '房屋')), Icons.home);
      // 5) 全查不到 → 中性图标（分类树落后是预期内状态，不崩）。
      expect(
        nodeIconOf(const CategoryNode(id: 99999, name: '未知类目')),
        neutralCategoryIcon,
      );
    });
  });

  test('版本号非空且形如 yyyy-MM-dd.n（§2.9 版本号 + 本地缓存的比对依据）', () {
    expect(RegExp(r'^\d{4}-\d{2}-\d{2}\.\d+$').hasMatch(categoryTreeVersion), isTrue);
  });
}
