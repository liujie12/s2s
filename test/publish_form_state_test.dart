/// 发布表单校验守门测试（PRD §5.4.1 顶部栏「禁用直到必填齐全」/ §5.8 边界表）。
///
/// **这些断言防的是什么**：§5.8 的边界是一张表，而它在代码里塌缩成
/// [PublishFormState.blocker] 里一串 if。任何一次重构漏掉其中一个 if，
/// 编译器不报错、界面也照常能用 —— 表现是「没填价格也能发出去」这类
/// 只在用户身上才暴露的缺陷。
///
/// 尤其是「协议未勾选 → Disabled」：与登录页那条同源，属《个人信息保护法》
/// 的单独同意，把它从条件里漏掉是一行字的事（见 login_screen_test.dart 文件头）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/category_tree.dart';
import 'package:zhaoyazhao/domain/publish_template.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';

void main() {
  /// 构造一份「除指定项外全部填妥」的表单。
  ///
  /// 参数 [leafId] 叶子分类 ID，默认 40101（二手闲置，模板只有一项必填）。
  /// 返回一份可提交的表单快照，供各用例逐项挖空来验证对应的 blocker。
  PublishFormState complete({int leafId = 40101}) {
    final template = templateForLeaf(leafId);
    return PublishFormState(
      leafCategoryId: leafId,
      hasLocation: true,
      title: '九成新实木餐桌转让',
      priceText: '350',
      priceUnit: template.priceUnits.first,
      description: '搬家出售，购入一年，无磕碰，可上门自取。',
      templateValues: {
        for (final f in template.extraFields)
          if (f.required) f.key: f.options.isEmpty ? '填了' : f.options.first,
      },
      contact: '13800138000',
      agreed: true,
    );
  }

  group('契约常量（原则 134：必须有一处字面量钉死并被直接比对）', () {
    test('图片上限 9（§5.8「图片 ≤ 9」）', () {
      expect(kMaxImageCount, 9);
    });

    test('描述建议区间 30-200 字（§5.4.1 第 5 段）', () {
      expect(kDescriptionSuggestMin, 30);
      expect(kDescriptionSuggestMax, 200);
    });

    test('有效期默认 7 天（§5.11「默认 7 天，不提供其他可选值」）', () {
      expect(kDefaultValidDays, 7);
    });
  });

  group('基线：填齐后可提交', () {
    test('样板表单无阻塞', () {
      final form = complete();
      // 这条是所有「挖空一项应被拦」用例的对照组。它一旦失败，
      // 下面那些用例全都会变成「因为别的原因被拦」的假绿。
      expect(form.blocker, isNull, reason: '样板表单本身不该被拦');
      expect(form.canSubmit, isTrue);
    });
  });

  group('§5.4.1 八段逐项挖空，各自报出自己的 blocker', () {
    test('未选分类 → noCategory', () {
      // 用全新实例而非 copyWith(leafCategoryId: null)：copyWith 的
      // `?? this.x` 写法无法把可空字段改回 null（这是 copyWith 的通病）。
      const form = PublishFormState(
        hasLocation: true,
        title: 't',
        priceText: '1',
        priceUnit: '元',
        description: 'd',
        contact: 'c',
        agreed: true,
      );
      expect(form.blocker, PublishBlocker.noCategory);
    });

    test('未选位置 → noLocation', () {
      expect(
        complete().copyWith(hasLocation: false).blocker,
        PublishBlocker.noLocation,
      );
    });

    test('标题为空 → noTitle', () {
      expect(complete().copyWith(title: '').blocker, PublishBlocker.noTitle);
    });

    test('标题只有空白字符 → 仍视为空（trim 后判定）', () {
      expect(complete().copyWith(title: '   ').blocker, PublishBlocker.noTitle);
    });

    test('描述为空 → noDescription', () {
      expect(
        complete().copyWith(description: '').blocker,
        PublishBlocker.noDescription,
      );
    });

    test('联系方式为空 → noContact', () {
      expect(complete().copyWith(contact: '').blocker, PublishBlocker.noContact);
    });

    test('协议未勾 → agreementUnchecked（§5.8「协议未勾选 → 主按钮 Disabled」）', () {
      expect(
        complete().copyWith(agreed: false).blocker,
        PublishBlocker.agreementUnchecked,
      );
    });

    test('图片超 9 张 → tooManyMedia', () {
      expect(
        complete().copyWith(imageCount: kMaxImageCount + 1).blocker,
        PublishBlocker.tooManyMedia,
      );
      // 恰好 9 张不拦 —— 边界必须落在「超过」而非「等于」
      expect(complete().copyWith(imageCount: kMaxImageCount).blocker, isNull);
    });

    test('模板必填项未填 → templateFieldMissing', () {
      // 拼车模板有三项必填，最能暴露「只检查了第一项」这类漏检。
      final form = complete(leafId: 30101).copyWith(templateValues: const {});
      expect(form.blocker, PublishBlocker.templateFieldMissing);
    });

    test('模板必填项只填了一部分 → 仍报 templateFieldMissing', () {
      final form = complete(
        leafId: 30101,
      ).copyWith(templateValues: const {'route': '回龙观 → 中关村'});
      expect(form.blocker, PublishBlocker.templateFieldMissing);
    });

    test('模板非必填项留空不拦（§5.4.3 只有部分附加字段是必填）', () {
      final template = templateForLeaf(30101);
      final optional = template.extraFields.where((f) => !f.required);
      expect(optional, isNotEmpty, reason: '拼车模板应有非必填字段（车型）');
      expect(complete(leafId: 30101).blocker, isNull);
    });
  });

  group('§5.8 价格为空：「允许选面议不填数字；其他情况必须填数字」', () {
    test('未填数字且单位不是面议 → noPrice', () {
      expect(
        complete().copyWith(priceText: '').blocker,
        PublishBlocker.noPrice,
      );
    });

    test('选了面议且不填数字 → 放行', () {
      final form = complete().copyWith(priceText: '', priceUnit: '面议');
      expect(form.priceSettled, isTrue);
      expect(form.blocker, isNull);
    });

    test('填 0 不算已交代价格 —— 0 元发布须走面议，否则语义不明', () {
      expect(complete().copyWith(priceText: '0').blocker, PublishBlocker.noPrice);
    });

    test('填非数字（如中间态「5.」以外的乱字符）→ noPrice', () {
      expect(
        complete().copyWith(priceText: '面谈').blocker,
        PublishBlocker.noPrice,
      );
    });

    test('小数价格可用（如 12.5 元）', () {
      expect(complete().copyWith(priceText: '12.5').blocker, isNull);
    });

    test('可议价与面议是两回事：勾了可议价但没填数字仍被拦', () {
      // negotiable = 有标价但可谈；面议 = 不标价。§5.8 只把面议当免填出口。
      final form = complete().copyWith(priceText: '', negotiable: true);
      expect(form.blocker, PublishBlocker.noPrice);
    });
  });

  group('blocker 的返回顺序 = §5.4.1 表单段落顺序', () {
    test('多项皆缺时先报最靠前的那一项', () {
      // 一次抛八条提示等于没提示；而顺序错乱会让用户被指向表单末尾，
      // 填完发现前面还缺 —— 这条断言守的正是「提示顺序即填写顺序」。
      const form = PublishFormState();
      expect(form.blocker, PublishBlocker.noCategory);

      final withCategory = form.withCategory(40101);
      expect(withCategory.blocker, PublishBlocker.noLocation);

      final withLocation = withCategory.copyWith(hasLocation: true);
      expect(withLocation.blocker, PublishBlocker.noTitle);

      final withTitle = withLocation.copyWith(title: '餐桌');
      expect(withTitle.blocker, PublishBlocker.noPrice);

      final withPrice = withTitle.copyWith(priceText: '350');
      expect(withPrice.blocker, PublishBlocker.noDescription);

      final withDesc = withPrice.copyWith(description: '九成新');
      expect(withDesc.blocker, PublishBlocker.templateFieldMissing);

      final withTemplate = withDesc.copyWith(
        templateValues: const {'condition': '几乎全新'},
      );
      expect(withTemplate.blocker, PublishBlocker.noContact);

      final withContact = withTemplate.copyWith(contact: '13800138000');
      expect(withContact.blocker, PublishBlocker.agreementUnchecked);

      expect(withContact.copyWith(agreed: true).blocker, isNull);
    });

    test('每个 blocker 都有非空文案 —— 灰按钮不说原因等于把规则藏起来', () {
      for (final b in PublishBlocker.values) {
        expect(b.message.trim(), isNotEmpty);
      }
    });
  });

  group('withCategory：换分类必须清掉旧模板的残留值', () {
    test('旧模板字段值被清空（否则会作为脏数据一起入库）', () {
      final home = complete(leafId: 50101); // 家政，有 service_hours
      expect(home.templateValues, isNotEmpty);
      final second = home.withCategory(40101); // 换到二手闲置
      expect(second.templateValues, isEmpty);
      // 换完之后模板必填项自然未齐，应当被拦住而不是带着旧值放行
      expect(second.blocker, PublishBlocker.templateFieldMissing);
    });

    test('价格单位重置为新模板的第一个合法单位', () {
      final home = complete(leafId: 50101).copyWith(priceUnit: '元/㎡');
      final job = home.withCategory(10101); // 全职招聘，单位是 元/月
      expect(job.priceUnit, templateForLeaf(10101).priceUnits.first);
      // 关键在于新单位必须是新模板的合法值 —— 家政的「元/㎡」在招聘模板里不存在
      expect(templateForLeaf(10101).priceUnits, contains(job.priceUnit));
    });

    test('与分类无关的字段（标题、位置、联系方式）保留 —— 换个分类不该清空整张表', () {
      final before = complete();
      final after = before.withCategory(50101);
      expect(after.title, before.title);
      expect(after.hasLocation, before.hasLocation);
      expect(after.contact, before.contact);
      expect(after.agreed, before.agreed);
    });
  });

  group('模板与资质的派生值', () {
    test('未选分类时 template 退到通用模板（页面首帧要有 placeholder 可显示）', () {
      expect(const PublishFormState().template.isGeneric, isTrue);
    });

    test('未选分类时 requiredCert 为 none —— 没有分类就无从判断需要什么资质', () {
      expect(const PublishFormState().requiredCert, RequiredCert.none);
    });

    test('高敏分类的 requiredCert 透传（家政 → 个人资质）', () {
      expect(
        complete(leafId: 50101).requiredCert,
        RequiredCert.personalQualification,
      );
    });

    test('描述字数提示按 trim 后长度算并带上建议区间', () {
      final form = complete().copyWith(description: '  一二三  ');
      expect(form.descriptionHint, '已填 3 字，建议 30-200 字');
    });

    test('描述不足 30 字不影响提交 —— 「建议」不是校验（§5.4.1 原文用词）', () {
      expect(complete().copyWith(description: '短').blocker, isNull);
    });
  });

  group('§7.4.3 需求态标题前缀由分类自动推导', () {
    test('资源态无前缀', () {
      expect(demandPrefixFor(PublishKind.supply, 40101), isNull);
    });

    test('房屋 → 【求租】、车辆 → 【求搭】、生活 → 【求购】、工作与服务 → 【求助】', () {
      expect(demandPrefixFor(PublishKind.demand, 20101), '【求租】');
      expect(demandPrefixFor(PublishKind.demand, 30101), '【求搭】');
      expect(demandPrefixFor(PublishKind.demand, 40101), '【求购】');
      expect(demandPrefixFor(PublishKind.demand, 10101), '【求助】');
      expect(demandPrefixFor(PublishKind.demand, 50101), '【求助】');
    });

    test('未选分类或脏 ID 返回 null 而非某个默认前缀', () {
      expect(demandPrefixFor(PublishKind.demand, null), isNull);
      expect(demandPrefixFor(PublishKind.demand, 999999), isNull);
    });
  });

  group('[124] B3 服务端模板装配（loadedTemplate / templatePending）', () {
    /// 构造「服务端口径」模板：本地框架文案 + 单个服务端必填字段。
    ///
    /// 参数 [leafId] 叶子 ID。返回 extraFields 被替换后的模板实例。
    PublishTemplate serverTemplateOf(int leafId) {
      return templateForLeaf(leafId).withExtraFields(const [
        TemplateFieldSpec(
          key: 'server_only',
          label: '服务端字段',
          type: TemplateFieldType.text,
          required: true,
        ),
      ]);
    }

    test('未选分类：templatePending 恒 false（通用模板无等待语义）', () {
      expect(const PublishFormState().templatePending, isFalse);
    });

    test('已选分类未加载：templatePending 为 true（B3 提交闸门判据）', () {
      expect(complete().templatePending, isTrue);
    });

    test('withTemplate 就位后闸门解除，template 取服务端字段集', () {
      final form = complete().withTemplate(serverTemplateOf(40101));
      expect(form.templatePending, isFalse);
      expect(form.template.extraFields.map((f) => f.key), ['server_only']);
      // 框架文案恒取本地，不被服务端字段集替换
      expect(
        form.template.titlePlaceholder,
        templateForLeaf(40101).titlePlaceholder,
      );
      expect(form.template.priceUnits, templateForLeaf(40101).priceUnits);
    });

    test('loadedTemplate 的必填字段参与 blocker：本地字段填齐不算数', () {
      final pending = complete().withTemplate(serverTemplateOf(40101));
      // complete() 填的是本地字段（condition），服务端字段空着仍拦
      expect(pending.blocker, PublishBlocker.templateFieldMissing);
      final filled = pending.copyWith(
        templateValues: const {'server_only': '填了'},
      );
      expect(filled.blocker, isNull);
    });

    test('withCategory 清空 loadedTemplate：新分类必须重新拉取模板', () {
      final loaded = complete().withTemplate(serverTemplateOf(40101));
      expect(loaded.templatePending, isFalse);
      final switched = loaded.withCategory(30101);
      expect(switched.loadedTemplate, isNull);
      expect(switched.templatePending, isTrue);
    });
  });
}
