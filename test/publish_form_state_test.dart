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
import 'package:zhaoyazhao/domain/listing_detail.dart';
import 'package:zhaoyazhao/domain/publish_template.dart';
import 'package:zhaoyazhao/domain/route_pair.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

void main() {
  /// 构造一份「除指定项外全部填妥」的表单。
  ///
  /// 参数 [leafId] 叶子分类 ID，默认 40101（二手闲置，模板只有一项必填）；
  /// [located] 是否已采集到位置坐标（false 用于挖空「位置」一段）。
  /// 返回一份可提交的表单快照，供各用例逐项挖空来验证对应的 blocker。
  PublishFormState complete({int leafId = 40101, bool located = true}) {
    final template = templateForLeaf(leafId);
    return PublishFormState(
      leafCategoryId: leafId,
      lng: located ? 120.1551 : null,
      lat: located ? 30.2741 : null,
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
      // 交叉断言（[B2-11]）：NfrMedia 是后端 NfrMedia.java / openapi 的前端
      // 镜像，与 §5.8 的本地契约值必须同值，否则会出现「客户端放行 9 张、
      // 服务端拒第 9 张」这类只在上传时才暴露的漂移。
      expect(NfrMedia.maxMediaCount, kMaxImageCount);
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

  group('位置坐标：采集到才随载荷上送（POST /posts 契约要求 lng/lat 必填）', () {
    test('已采集坐标 → 载荷含 lng/lat，hasLocation 为真', () {
      final form = complete();
      final payload = form.postDraftPayload();
      expect(form.hasLocation, isTrue);
      expect(payload['lng'], 120.1551);
      expect(payload['lat'], 30.2741);
    });

    test('未采集坐标 → 载荷不含 lng/lat，blocker 拦在 noLocation', () {
      // 守的是「precheck 能过、createPost 必 400」那个组合：坐标缺失时
      // 必须被 blocker 在提交前拦住，而不是发到服务端吃 40001。
      final form = complete(located: false);
      expect(form.hasLocation, isFalse);
      expect(form.postDraftPayload().containsKey('lng'), isFalse);
      expect(form.postDraftPayload().containsKey('lat'), isFalse);
      expect(form.blocker, PublishBlocker.noLocation);
    });

    test('hasLocation 与坐标同源：写入坐标即视为已选位置', () {
      final form = const PublishFormState().copyWith(
        lng: 120.1551,
        lat: 30.2741,
      );
      expect(form.hasLocation, isTrue);
      expect(form.postDraftPayload()['lng'], 120.1551);
    });
  });

  group('§5.4.1 八段逐项挖空，各自报出自己的 blocker', () {
    test('未选分类 → noCategory', () {
      // 用全新实例而非 copyWith(leafCategoryId: null)：copyWith 的
      // `?? this.x` 写法无法把可空字段改回 null（这是 copyWith 的通病）。
      const form = PublishFormState(
        lng: 120.1551,
        lat: 30.2741,
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
      // 用 located:false 构造无坐标实例：copyWith 的 `?? this.x` 无法把可空
      // 字段改回 null（同上方 noCategory 用例的注释）。
      expect(complete(located: false).blocker, PublishBlocker.noLocation);
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
      expect(
        complete().copyWith(contact: '').blocker,
        PublishBlocker.noContact,
      );
    });

    test('协议未勾 → agreementUnchecked（§5.8「协议未勾选 → 主按钮 Disabled」）', () {
      expect(
        complete().copyWith(agreed: false).blocker,
        PublishBlocker.agreementUnchecked,
      );
    });

    test('图片超 9 张 → tooManyMedia', () {
      expect(
        complete()
            .copyWith(mediaIds: List<String>.filled(kMaxImageCount + 1, 'mda'))
            .blocker,
        PublishBlocker.tooManyMedia,
      );
      // 恰好 9 张不拦 —— 边界必须落在「超过」而非「等于」
      expect(
        complete()
            .copyWith(mediaIds: List<String>.filled(kMaxImageCount, 'mda'))
            .blocker,
        isNull,
      );
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
      expect(optional, isNotEmpty, reason: '拼车模板应有非必填字段（颜色 / 车牌）');
      expect(complete(leafId: 30101).blocker, isNull);
    });

    test('AE4 编辑载入历史自由文本 → 原键原文保留且不拦提交', () {
      final form = complete(leafId: 30101).copyWith(
        templateValues: const {
          'route': '回龙观 → 中关村',
          'depart_time': '工作日 8:00',
          'seats': '2',
          'car_brand': '比亚迪',
          'car_model': '轿车',
        },
      );

      // 载入路径零改动：字符串键原样保留，不尝试解析或清洗旧值
      expect(form.templateValues['depart_time'], '工作日 8:00');
      // 非空即已填（KTD3）：历史文本同样让必填项通过
      expect(form.blocker, isNull);
    });

    test('出发时间已是 ISO 时刻串 → 同样视为已填', () {
      final form = complete(leafId: 30101).copyWith(
        templateValues: const {
          'route': '回龙观 → 中关村',
          'depart_time': '2026-10-30T10:30:00Z',
          'seats': '2',
          'car_brand': '比亚迪',
          'car_model': '轿车',
        },
      );

      expect(form.blocker, isNull);
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
      expect(
        complete().copyWith(priceText: '0').blocker,
        PublishBlocker.noPrice,
      );
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

      final withLocation = withCategory.copyWith(lng: 120.1551, lat: 30.2741);
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

  group('KTD1/KTD3/KTD4 起终点（route_pair）', () {
    /// 构造一份除起终点外全部填妥的拼车表单（叶子 30101）。
    ///
    /// 参数 [pair] 起终点值；[legacyText] 历史文本形态的 route 值。
    /// 返回：拼车表单快照。
    PublishFormState carpool({RoutePair? pair, String legacyText = ''}) {
      return PublishFormState(
        leafCategoryId: 30101,
        lng: 120.1551,
        lat: 30.2741,
        title: '工作日回龙观到中关村拼车',
        priceUnit: '面议',
        description: '每天早八点出发，走京藏高速，可带小件行李。',
        templateValues: {
          'depart_time': '工作日 8:00',
          'seats': '2',
          'car_brand': '比亚迪',
          'car_model': '轿车',
          if (legacyText.isNotEmpty) 'route': legacyText,
        },
        routePair: pair,
        contact: '13800138000',
        agreed: true,
      );
    }

    /// 两端齐备的起终点值。
    RoutePair fullPair() => const RoutePair(
      origin: RoutePlace(
        name: '回龙观',
        address: '北京市昌平区回龙观',
        lng: 116.337,
        lat: 40.071,
      ),
      destination: RoutePlace(
        name: '中关村',
        address: '北京市海淀区中关村大街',
        lng: 116.316,
        lat: 39.983,
      ),
      distanceM: 18500,
      durationS: 2100,
    );

    test('模板含 route_pair 时 usesRoutePair 为真，其余分类为假', () {
      expect(carpool().usesRoutePair, isTrue);
      expect(complete().usesRoutePair, isFalse);
    });

    test('两端齐备 → 模板必填不拦', () {
      expect(carpool(pair: fullPair()).blocker, isNull);
    });

    test('只有起点（终点无坐标）→ 仍报模板必填缺失（KTD4）', () {
      final pair = RoutePair(
        origin: fullPair().origin,
        destination: const RoutePlace(name: '中关村'),
      );
      expect(carpool(pair: pair).blocker, PublishBlocker.templateFieldMissing);
    });

    test('载荷 attributes.route 是含两端坐标的对象（AE6）', () {
      final payload = carpool(pair: fullPair()).postDraftPayload();
      final attributes = payload['attributes']! as Map<String, Object?>;
      final route = attributes['route']! as Map<String, Object?>;

      final origin = route['origin']! as Map<String, Object?>;
      final destination = route['destination']! as Map<String, Object?>;
      expect(origin['name'], '回龙观');
      expect(origin['lng'], 116.337);
      expect(destination['lat'], 39.983);
      expect(route['distance_m'], 18500);
      // 门牌号下线：载荷里不再有门牌相关字段（R9）。
      expect(payload.containsKey('door_number'), isFalse);
    });

    test('只有历史文本、没有对象 → 载荷 route 仍是字符串（KTD1 兼容）', () {
      final form = carpool(legacyText: '回龙观 → 中关村');
      final attributes =
          form.postDraftPayload()['attributes']! as Map<String, Object?>;

      expect(form.routePair, isNull);
      expect(attributes['route'], '回龙观 → 中关村');
      // 存量帖不能被客户端必填拦住，可直接重发。
      expect(form.blocker, isNull);
    });

    test('拼车：位置精确看两端 POI，不看门牌号（AE6 / KTD3）', () {
      expect(carpool(pair: fullPair()).locationPrecise, isTrue);
      expect(
        carpool(pair: fullPair()).postDraftPayload()['address_precise'],
        isTrue,
      );
      // 有门牌号但两端不全 → 拼车仍不算精确。
      expect(
        carpool(
          pair: RoutePair(
            origin: fullPair().origin,
            destination: const RoutePlace(name: '中关村'),
          ),
        ).copyWith(doorNumber: '3 号楼 501').locationPrecise,
        isFalse,
      );
    });

    test('拼车两端齐备 → 完整度三项全达成，档位为绿', () {
      final form = carpool(pair: fullPair());
      expect(form.completeness.metCount, 3);
      expect(form.completeness.level, CompletenessLevel.green);
    });

    test('非拼车分类仍按门牌号判位置精确', () {
      expect(complete().locationPrecise, isFalse);
      expect(
        complete().copyWith(doorNumber: '3 号楼 501').locationPrecise,
        isTrue,
      );
    });

    test('换分类后起终点仍在（换回来不必重选）', () {
      final switched = carpool(pair: fullPair()).withCategory(40101);
      expect(switched.routePair, fullPair());
    });

    test('withRoutePair(null) 可清空（copyWith 的 ?? 无法置空）', () {
      final cleared = carpool(pair: fullPair()).withRoutePair(null);
      expect(cleared.routePair, isNull);
    });
  });
}
