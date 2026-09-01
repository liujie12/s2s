/// AI 猜测生成与逆向 Scope 比对守门测试（PRD §5.9 四件套 / §5.10 严格 Scope）。
///
/// **这一组断言守的是「不编造」这条红线本身**。§5.10 的要求是「禁止编造新实体」，
/// 而这条要求在代码里的载体只有 `reverseScopeCheck`。若它被削弱成恒过
/// （例如把 `neighborMode` 判成合法、或省掉「有值必须有来源」那一步），
/// 页面看起来完全一样，但接服务端那天将没有任何断言能拦住一个会编造的模型。
///
/// 故本文件除了验证「猜得对」，还专门伪造几种非法猜测，验证校验真的会拦。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/ai_guess.dart';
import 'package:zhaoyazhao/domain/publish_template.dart';
import 'package:zhaoyazhao/features/publish/ai_guess_builder.dart';
import 'package:zhaoyazhao/features/publish/publish_form_state.dart';

void main() {
  /// 取结果里某个字段的猜测。
  ///
  /// 参数 [result] 猜测结果，[key] 字段键。返回该字段的 [FieldGuess]。
  FieldGuess pick(AiGuessResult result, String key) =>
      result.guesses.firstWhere((g) => g.fieldKey == key);

  /// 一份填了分类、标题、价格的表单（二手闲置，单位「元」/「面议」）。
  PublishFormState filled() => const PublishFormState(
    leafCategoryId: 40101,
    title: '九成新实木餐桌',
    priceText: '350',
    priceUnit: '元',
    description: '搬家出售，无磕碰，可上门自取。',
    templateValues: {'condition': '几乎全新'},
  );

  group('§5.9 四件套：标题 / 分类 / 价格 / 模板字段逐项都有一行', () {
    test('已填表单 → 四类字段齐备', () {
      final result = buildLocalGuess(filled());
      final keys = result.guesses.map((g) => g.fieldKey).toList();
      expect(keys, containsAll(['category', 'title', 'price']));
      // 模板附加字段逐项，缺一项就等于确认页少一行需要核对的内容
      for (final f in templateForLeaf(40101).extraFields) {
        expect(keys, contains(f.key));
      }
    });

    test('状态为 ready（本地生成没有等待过程）', () {
      expect(buildLocalGuess(filled()).status, AiParseStatus.ready);
    });
  });

  group('§5.10 猜测策略：用户已填照搬，来源 userInput', () {
    test('分类回显完整面包屑，而不是叶子名或对象 toString', () {
      final guess = pick(buildLocalGuess(filled()), 'category');
      expect(guess.value, '生活 > 二手闲置转让 > 家具家电');
      expect(guess.source, GuessSource.userInput);
      // 这条断言是实测抓出来的：曾写成 categoryPathOf(id).join(' > ')，
      // 拼出的是 CategoryNode 的 toString，页面上会显示 Instance of...
      expect(guess.value, isNot(contains('Instance of')));
    });

    test('标题照搬用户原文，不做截断改写', () {
      expect(pick(buildLocalGuess(filled()), 'title').value, '九成新实木餐桌');
    });

    test('需求态标题带 §7.4.3 自动前缀（前缀由分类推导，不算编造）', () {
      final form = filled().copyWith(kind: PublishKind.demand);
      expect(pick(buildLocalGuess(form), 'title').value, '【求购】九成新实木餐桌');
    });

    test('价格 = 数字 + 用户选的单位', () {
      final guess = pick(buildLocalGuess(filled()), 'price');
      expect(guess.value, '350 元');
      expect(guess.source, GuessSource.userInput);
    });

    test('选了面议 → 直接给「面议」，不硬凑一个数字', () {
      final form = filled().copyWith(priceText: '', priceUnit: '面议');
      expect(pick(buildLocalGuess(form), 'price').value, '面议');
    });

    test('模板字段已填照搬', () {
      final guess = pick(buildLocalGuess(filled()), 'condition');
      expect(guess.value, '几乎全新');
      expect(guess.source, GuessSource.userInput);
    });
  });

  group('§5.9「不猜、不编造」：猜不出就标需你补充', () {
    test('未选分类 → 分类不猜（分类决定模板与资质拦截，猜错代价最大）', () {
      final guess = pick(buildLocalGuess(const PublishFormState()), 'category');
      expect(guess.value, isNull);
      expect(guess.source, isNull);
      expect(guess.isGuessed, isFalse);
      expect(guess.displayText, '需你补充');
    });

    test('标题为空 → 不从描述里截一段当标题', () {
      // 描述写得很长也不代表可以从里面挑一句 —— 「挑哪一句」是模型的判断，
      // 不在 scope 内。
      final form = filled().copyWith(title: '', description: '实木餐桌九成新，搬家急出。');
      expect(pick(buildLocalGuess(form), 'title').isGuessed, isFalse);
    });

    test('标题只有空白字符 → 视为未填', () {
      expect(
        pick(buildLocalGuess(filled().copyWith(title: '  ')), 'title').isGuessed,
        isFalse,
      );
    });

    test('价格没填数字且模板有多个单位 → 不猜（元/次 与 元/月 差一个数量级）', () {
      // 家政模板有四个单位，任选一个都是编造。
      final form = const PublishFormState(leafCategoryId: 50101);
      expect(templateForLeaf(50101).priceUnits.length, greaterThan(1));
      expect(pick(buildLocalGuess(form), 'price').isGuessed, isFalse);
    });

    test('模板单选字段有多个选项且未填 → 不猜', () {
      final form = filled().copyWith(templateValues: const {});
      expect(pick(buildLocalGuess(form), 'condition').isGuessed, isFalse);
    });

    test('allFilled 只在全部字段都有值时为真（决定「确认发布」能否点）', () {
      expect(buildLocalGuess(const PublishFormState()).allFilled, isFalse);
      final result = buildLocalGuess(filled());
      // 二手闲置模板的「pickup」非必填且多选项，故这份表单必然有未猜出项
      expect(result.needsUser, isNotEmpty);
      expect(result.allFilled, isFalse);
      expect(result.guessedCount, lessThan(result.guesses.length));
    });
  });

  group('§5.10 Step 4 逆向 Scope 比对', () {
    test('本地生成的结果全部合法（没有一项找不到来源）', () {
      // 这是对照组：它一旦失败，下面「伪造应被拦」的用例就成了假绿 ——
      // 因为分不清是伪造被拦还是本来就全被拦。
      final form = filled();
      expect(reverseScopeCheck(buildLocalGuess(form), form), isEmpty);
    });

    test('有值但没标来源 → 判非法（Step 4 的字面要求）', () {
      final form = filled();
      const fake = AiGuessResult(
        status: AiParseStatus.ready,
        guesses: [FieldGuess(fieldKey: 'title', label: '标题', value: '餐桌')],
      );
      expect(reverseScopeCheck(fake, form), ['title']);
    });

    test('声称 userInput 但值不在用户输入里 → 判非法（这就是「编造实体」）', () {
      final form = filled();
      final fake = AiGuessResult(
        status: AiParseStatus.ready,
        guesses: const [
          FieldGuess(
            fieldKey: 'title',
            label: '标题',
            // 用户从没写过「红木」，这是模型自己加的材质
            value: '红木餐桌',
            source: GuessSource.userInput,
          ),
        ],
      );
      expect(reverseScopeCheck(fake, form), ['title']);
    });

    test('声称 template 但值不是模板的合法取值 → 判非法', () {
      final form = filled();
      const fake = AiGuessResult(
        status: AiParseStatus.ready,
        guesses: [
          FieldGuess(
            fieldKey: 'condition',
            label: '成色',
            // 二手闲置模板的成色选项里没有这一档
            value: '有明显破损',
            source: GuessSource.template,
          ),
        ],
      );
      expect(reverseScopeCheck(fake, form), ['condition']);
    });

    test('声称 neighborMode 一律判非法 —— 本期无数据源，无从验证', () {
      // 若哪天有人把这一支改成 true，编造就有了一个合法外衣：
      // 任何值只要标上「据附近同类」就能过。
      final form = filled();
      const fake = AiGuessResult(
        status: AiParseStatus.ready,
        guesses: [
          FieldGuess(
            fieldKey: 'price',
            label: '价格',
            value: '400 元',
            source: GuessSource.neighborMode,
          ),
        ],
      );
      expect(reverseScopeCheck(fake, form), ['price']);
    });

    test('未猜出的字段不参与校验（没有值就没有编造）', () {
      const fake = AiGuessResult(
        status: AiParseStatus.ready,
        guesses: [FieldGuess(fieldKey: 'title', label: '标题')],
      );
      expect(reverseScopeCheck(fake, filled()), isEmpty);
    });

    test('多个非法项全部返回，而不是遇到第一个就停', () {
      final form = filled();
      const fake = AiGuessResult(
        status: AiParseStatus.ready,
        guesses: [
          FieldGuess(fieldKey: 'title', label: '标题', value: '红木餐桌',
              source: GuessSource.userInput),
          FieldGuess(fieldKey: 'condition', label: '成色', value: '有明显破损',
              source: GuessSource.template),
        ],
      );
      expect(reverseScopeCheck(fake, form), ['title', 'condition']);
    });

    test('标题带自动前缀仍算合法 —— 前缀由分类推导，不是新实体', () {
      final form = filled().copyWith(kind: PublishKind.demand);
      expect(reverseScopeCheck(buildLocalGuess(form), form), isEmpty);
    });
  });

  group('契约常量（原则 134）', () {
    test('解析超时改文案的阈值是 5 秒（§5.9「超过 5 秒」）', () {
      expect(kParsingSlowSeconds, 5);
    });

    test('三种来源都有非空说明文案 —— 不说来源的「AI 猜」角标无法判断可信度', () {
      for (final s in GuessSource.values) {
        expect(s.label.trim(), isNotEmpty);
      }
    });
  });
}
