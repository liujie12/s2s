/// AI 猜测结果模型（PRD §5.9 结果确认态 / §5.10 严格 Scope 四步管线）。
///
/// **本文件不含任何模型推理**：§5.9 的 AI 四件套来自 3B 小模型（服务端），
/// 本期无服务端。故这里只建「猜测结果」这个数据形态与它的确认流程，
/// 让 §5.9 表里的五种状态（解析中 / 解析失败 / 结果待确认 / 用户拒绝 /
/// 部分字段无法猜出）都能被呈现与验收。
///
/// **为什么要有 `source` 而不是只存值**：§5.10 Step 4「逆向 Scope 比对」要求
/// 「生成中每个实体都能在 scope 找到源头 = 合法输出」。没有来源的猜测值
/// 无法通过这一步，也无法向用户解释「你凭什么这么猜」。本期的来源只有
/// [GuessSource.userInput]（用户已填字段）与 [GuessSource.template]
/// （分类模板的选项/默认值）两种 —— 邻居众数与平台已知都需要服务端数据。
library;

/// 猜测值的来源（§5.10 Step 2 的 U ∪ N ∪ P 三集合）。
enum GuessSource {
  /// U —— 用户显式填写的内容（本期唯一真实来源）
  userInput('据你已填'),

  /// P —— 平台已知（本期仅指分类模板本身的字段定义）
  template('据分类模板'),

  /// N —— 邻居众数。**本期无数据源，仅占位**，不产生猜测值
  neighborMode('据附近同类');

  const GuessSource(this.label);

  /// 来源说明文案。展示它是为了让用户能判断这个猜测可不可信 ——
  /// 一个不说来源的「AI 猜」角标，用户只能凭感觉决定改不改。
  final String label;
}

/// 一个字段的 AI 猜测结果。
class FieldGuess {
  const FieldGuess({
    required this.fieldKey,
    required this.label,
    this.value,
    this.source,
  });

  /// 字段键（与 `TemplateFieldSpec.key` 同一命名空间，或 `title`/`category` 等固定键）。
  final String fieldKey;

  /// 字段名，展示用。
  final String label;

  /// 猜测值。**null 表示没猜出来** —— 按 §5.9「该字段留空并标『需你补充』，
  /// 不猜、不编造」。不用空字符串表示未猜出：空串与「猜出来是空」无法区分。
  final String? value;

  /// 猜测来源。[value] 非空时必须有来源（§5.10 Step 4）。
  final GuessSource? source;

  /// 是否猜出了值。
  bool get isGuessed => value != null && value!.trim().isNotEmpty;

  /// 展示文案：未猜出时按 §5.9 原文标「需你补充」。
  String get displayText => isGuessed ? value! : '需你补充';
}

/// AI 解析的整体状态（§5.9「AI 解析失败与结果确认态」表的五行）。
enum AiParseStatus {
  /// 解析中：骨架屏 + 「正在识别…」
  parsing,

  /// 解析失败：可重试或改手动
  failed,

  /// 结果待确认：强制进入确认页
  ready,
}

/// 解析中超过该秒数改文案为「稍等，马上好」（§5.9「超过 5 秒」）。
///
/// 字面量钉死（原则 134）：这是 PRD 明写的契约秒数。
const int kParsingSlowSeconds = 5;

/// AI 猜测的一整套结果（§5.9「AI 四件套」= 标题/分类/价格/模板字段）。
class AiGuessResult {
  const AiGuessResult({required this.status, this.guesses = const []});

  /// 解析中态。
  const AiGuessResult.parsing()
      : status = AiParseStatus.parsing,
        guesses = const [];

  /// 解析失败态（§5.9「已输入内容全部保留」—— 故失败态不携带任何猜测值，
  /// 页面显示的仍是用户原本填的表单）。
  const AiGuessResult.failed()
      : status = AiParseStatus.failed,
        guesses = const [];

  final AiParseStatus status;

  /// 逐字段猜测，按展示顺序。
  final List<FieldGuess> guesses;

  /// 已猜出的字段数。
  int get guessedCount => guesses.where((g) => g.isGuessed).length;

  /// 未猜出、需用户补充的字段（§5.9「部分字段无法猜出」）。
  List<FieldGuess> get needsUser =>
      guesses.where((g) => !g.isGuessed).toList();

  /// 是否所有字段都已有值 —— 决定「确认发布」是否可用
  /// （§5.9「必填项未补齐时『确认发布』保持禁用」）。
  bool get allFilled => needsUser.isEmpty;
}
