/// 本地 AI 猜测生成（PRD §5.9 四件套 / §5.10 严格 Scope 四步管线）。
///
/// **这不是 AI，也不假装是**：真正的猜测来自 3B 小模型（§5.10 Step 3），需服务端。
/// 本文件做的是「在无模型的情况下，仍然只用合法来源产出猜测」——
/// 即把 §5.10 的 Step 2（Scope 提取）与 Step 4（逆向比对）用可验证的代码写出来，
/// Step 3 留给服务端。
///
/// **为什么值得写而不是直接塞假数据**：§5.10 的红线是「禁止编造新实体」。
/// 如果确认页展示的是硬编码假值，那么页面看起来一样，但**红线本身没有代码守着**，
/// 接服务端时也没有任何断言能拦住一个会编造的模型。这里把「每个猜测值都必须
/// 能在用户输入或模板定义里找到源头」做成真实约束，接入时只需替换 Step 3。
library;

import '../../domain/ai_guess.dart';
import '../../domain/category_tree.dart';
import '../../domain/publish_template.dart';
import 'publish_form_state.dart';

/// 从当前表单生成 AI 猜测四件套（§5.9）。
///
/// 参数 [form] 用户已填的表单快照。
/// 返回：`AiParseStatus.ready` 的结果，含标题 / 分类 / 价格 / 模板字段逐项猜测。
///
/// **猜测策略（每一条都能追溯到来源，见 §5.10 Step 4）**：
/// - 用户已填 → 原值照搬，来源 `userInput`（这是最强的 scope，U 集合）；
/// - 用户未填但模板给了唯一合法值（如只有一个价格单位）→ 取该值，来源 `template`；
/// - 其余 → **不猜**，留 null 标「需你补充」。
AiGuessResult buildLocalGuess(PublishFormState form) {
  final template = form.template;
  final guesses = <FieldGuess>[
    _categoryGuess(form),
    _titleGuess(form),
    _priceGuess(form, template),
    // 模板附加字段逐项（§5.9 四件套的第四项「模板字段」）
    for (final field in template.extraFields)
      _templateFieldGuess(form, field),
  ];
  return AiGuessResult(status: AiParseStatus.ready, guesses: guesses);
}

/// 分类猜测：已选则回显面包屑，未选则不猜。
///
/// **为什么未选分类时不猜一个**：分类决定模板、决定资质拦截、决定推荐池分组。
/// 猜错的代价是用户发到了错误的类目里，而这恰是 §5.10 要防的「编造实体」。
FieldGuess _categoryGuess(PublishFormState form) {
  final id = form.leafCategoryId;
  final label = id == null ? null : categoryPathLabel(id);
  return FieldGuess(
    fieldKey: 'category',
    label: '分类',
    value: label,
    source: label == null ? null : GuessSource.userInput,
  );
}

/// 标题猜测：已填则照搬（需求态带 §7.4.3 前缀），未填则不猜。
///
/// **不从描述里截一段当标题**：那是在生成用户没写过的表达。虽然字面上
/// 每个字都来自用户，但「截取哪一段」是模型的判断，不在 scope 内。
FieldGuess _titleGuess(PublishFormState form) {
  final raw = form.title.trim();
  if (raw.isEmpty) {
    return const FieldGuess(fieldKey: 'title', label: '标题');
  }
  final prefix = demandPrefixFor(form.kind, form.leafCategoryId) ?? '';
  return FieldGuess(
    fieldKey: 'title',
    label: '标题',
    value: '$prefix$raw',
    source: GuessSource.userInput,
  );
}

/// 价格猜测：已填数字则「值 + 单位」；未填但模板只有一个单位则给出该单位。
///
/// **只在模板恰好只有一个价格单位时才补单位**：那种情况下单位不是猜的，
/// 是模板唯一的合法取值（§5.10 的 P 集合，平台已知）。有多个单位时选哪个
/// 都是编造 —— 「元/次」和「元/月」差一个数量级。
FieldGuess _priceGuess(PublishFormState form, PublishTemplate template) {
  if (form.priceUnit == '面议') {
    return const FieldGuess(
      fieldKey: 'price',
      label: '价格',
      value: '面议',
      source: GuessSource.userInput,
    );
  }
  final number = form.priceText.trim();
  if (number.isNotEmpty) {
    final unit = form.priceUnit ??
        (template.priceUnits.length == 1 ? template.priceUnits.first : null);
    if (unit != null) {
      return FieldGuess(
        fieldKey: 'price',
        label: '价格',
        value: '$number $unit',
        source: form.priceUnit != null
            ? GuessSource.userInput
            : GuessSource.template,
      );
    }
  }
  return const FieldGuess(fieldKey: 'price', label: '价格');
}

/// 模板字段猜测：已填照搬；未填且是只有一个选项的选单则取该选项；否则不猜。
FieldGuess _templateFieldGuess(
  PublishFormState form,
  TemplateFieldSpec field,
) {
  final filled = (form.templateValues[field.key] ?? '').trim();
  if (filled.isNotEmpty) {
    return FieldGuess(
      fieldKey: field.key,
      label: field.label,
      value: filled,
      source: GuessSource.userInput,
    );
  }
  // 单选且只有一个候选 → 该值是模板唯一合法取值，非猜测
  if (field.type == TemplateFieldType.select && field.options.length == 1) {
    return FieldGuess(
      fieldKey: field.key,
      label: field.label,
      value: field.options.first,
      source: GuessSource.template,
    );
  }
  return FieldGuess(fieldKey: field.key, label: field.label);
}

/// 逆向 Scope 比对（§5.10 Step 4）。
///
/// 参数 [result] 待校验的猜测结果，[form] 生成时依据的表单。
/// 返回：所有**找不到来源**的非法猜测字段键。空列表 = 合法输出。
///
/// **为什么要把这一步单独暴露出来而不是内嵌**：Step 4 的意义是「不信任
/// Step 3 的产物」。若把它写在 `buildLocalGuess` 内部，它校验的就是自己
/// 刚生成的东西 —— 恒过（原则 134 同族）。独立成函数，接入真实模型后
/// 可以直接拿它校验服务端返回，那才是它要防的对象。
List<String> reverseScopeCheck(AiGuessResult result, PublishFormState form) {
  final illegal = <String>[];
  for (final guess in result.guesses) {
    if (!guess.isGuessed) continue;
    if (guess.source == null) {
      // 有值但没来源，直接判非法 —— Step 4 的字面要求
      illegal.add(guess.fieldKey);
      continue;
    }
    if (!_hasSource(guess, form)) illegal.add(guess.fieldKey);
  }
  return illegal;
}

/// 单个猜测值能否在 scope 中找到源头。
bool _hasSource(FieldGuess guess, PublishFormState form) {
  return switch (guess.source!) {
    // U 集合：值必须出现在用户填过的内容里
    GuessSource.userInput => _inUserInput(guess, form),
    // P 集合：值必须是模板定义的合法取值
    GuessSource.template => _inTemplate(guess, form.template),
    // N 集合本期无数据源，任何声称来自邻居众数的值都无从验证，一律判非法
    GuessSource.neighborMode => false,
  };
}

/// 值是否源于用户输入。
bool _inUserInput(FieldGuess guess, PublishFormState form) {
  final value = guess.value!;
  return switch (guess.fieldKey) {
    'category' => form.leafCategoryId != null &&
        value == categoryPathLabel(form.leafCategoryId!),
    // 标题允许带 §7.4.3 自动前缀，故判「包含用户原文」而非全等
    'title' => form.title.trim().isNotEmpty && value.contains(form.title.trim()),
    'price' => value == '面议'
        ? form.priceUnit == '面议'
        : value.startsWith(form.priceText.trim()) &&
            form.priceText.trim().isNotEmpty,
    _ => (form.templateValues[guess.fieldKey] ?? '').trim() == value,
  };
}

/// 值是否为模板定义的合法取值。
bool _inTemplate(FieldGuess guess, PublishTemplate template) {
  final value = guess.value!;
  if (guess.fieldKey == 'price') {
    return template.priceUnits.any((unit) => value.endsWith(unit));
  }
  final field = template.extraFields
      .where((f) => f.key == guess.fieldKey)
      .firstOrNull;
  return field != null && field.options.contains(value);
}
