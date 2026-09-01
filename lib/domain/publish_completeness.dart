/// 信息完整度三档判定（PRD §9.8 —— 全文唯一判定处）。
///
/// **为什么单独成类而不写在两个页面里**：§9.8 末条明写「判定口径唯一：本表是
/// 🟢🟡🔴 的唯一判定处，§5.9 确认页冲刺区与 §5.11 补全引导均引用本表」。
/// 确认页要算「补齐这两项能不能升 🟢」，完成页要算「当前档 + 还差哪几项」，
/// 详情页与地图 Pin 角标也要用同一个档 —— 四处各写一遍判定，
/// 迟早出现「确认页说能升 🟢，发完却显示 🟡」这种自相矛盾。
///
/// **为什么输入是三个布尔而不是直接吃 `PublishFormState`**：本文件在 `domain/`，
/// 表单在 `features/publish/`，反向依赖会把领域模型绑死在一个页面上 ——
/// 而 §9.8 的档位还要给详情页、地图 Pin、个人中心补全提醒用。
/// 「怎么从表单推出这三个条件」是表单自己的事（见 `PublishFormState.completeness`）。
library;

import 'listing_detail.dart';

/// 🟢 完整档的三个条件（§9.8 表首列「触发条件」的三项拆解）。
enum CompletenessCondition {
  /// 必填项 100%
  requiredFields('必填项填完', '还有必填项没填'),

  /// 位置到门牌号
  doorNumber('位置到门牌号', '位置补到门牌号'),

  /// 三级类目精准命中
  leafCategory('三级类目选到底', '分类选到第三级');

  const CompletenessCondition(this.label, this.gapLabel);

  /// 已达成时的陈述文案。
  final String label;

  /// 未达成时的待办文案（§5.11「还差 2 张图 + 门牌号」的单项措辞）。
  final String gapLabel;
}

/// 推荐池权重（§9.8「推荐池权重」列）。
///
/// 字面量而非从别处推导：按原则 134，契约数值必须至少一处用字面量钉死。
/// 这三个数字是「用户升档能换到什么」的全部依据，改动必须有人来改这里。
const double kWeightGreen = 2.0;
const double kWeightYellow = 1.0;
const double kWeightRed = 0.5;

/// 一次完整度判定的结果。
class CompletenessAssessment {
  const CompletenessAssessment({
    required this.requiredFieldsComplete,
    required this.hasDoorNumber,
    required this.leafCategoryPrecise,
  });

  /// 必填项是否 100%（§9.8 条件一）。
  final bool requiredFieldsComplete;

  /// 位置是否到门牌号（§9.8 条件二）。
  final bool hasDoorNumber;

  /// 三级类目是否精准命中（§9.8 条件三）。
  final bool leafCategoryPrecise;

  /// 三条件中已达成的个数。
  int get metCount => (requiredFieldsComplete ? 1 : 0) +
      (hasDoorNumber ? 1 : 0) +
      (leafCategoryPrecise ? 1 : 0);

  /// 档位（§9.8：3 个 → 🟢，2 个 → 🟡，≤1 个 → 🔴）。
  ///
  /// 用 `metCount` 而非嵌套 if：§9.8 的口径就是「满足几个」，
  /// 三个条件之间没有优先级差别，写成 if 链会暗示存在主次。
  CompletenessLevel get level => switch (metCount) {
    3 => CompletenessLevel.green,
    2 => CompletenessLevel.yellow,
    _ => CompletenessLevel.red,
  };

  /// 尚未达成的条件，按 [CompletenessCondition] 声明顺序。
  ///
  /// 返回全部而非第一项 —— 与发布页 `blocker` 的取舍刚好相反：
  /// 那里是「挡住你之前先说一条」，这里是「你已经发出去了，
  /// 告诉你全部差项才好一次补完」（§5.11「30 秒补上」的前提是知道要补几样）。
  List<CompletenessCondition> get missing => [
    if (!requiredFieldsComplete) CompletenessCondition.requiredFields,
    if (!hasDoorNumber) CompletenessCondition.doorNumber,
    if (!leafCategoryPrecise) CompletenessCondition.leafCategory,
  ];

  /// 当前档的推荐池权重（§9.8）。
  double get weight => switch (level) {
    CompletenessLevel.green => kWeightGreen,
    CompletenessLevel.yellow => kWeightYellow,
    CompletenessLevel.red => kWeightRed,
  };

  /// 是否已是最高档（无升级空间）。
  bool get isTop => level == CompletenessLevel.green;

  /// 升 🟢 能得到的权益三条（§8 T6-④「对应具体权益三条」）。
  ///
  /// 第一条把当前权重写进文案（「×2 优先展示（当前 ×1）」）—— 只说
  /// 「升级能得 ×2」不说现在是多少，用户无法判断这个升级值不值得花 30 秒。
  List<String> get benefits => [
    '推荐池权重 ×${_fmt(kWeightGreen)} 优先展示（当前 ×${_fmt(weight)}）',
    '附近人 2 倍概率看到你',
    '列表页排序前置，不落末位',
  ];

  /// 权重数字文案：2.0 显示为 2，0.5 保留小数。
  ///
  /// 「权重 ×2.0」读起来像精度而非倍数，而 0.5 不能写成 0。
  static String _fmt(double value) =>
      value == value.roundToDouble() ? value.round().toString() : '$value';

  CompletenessAssessment copyWith({
    bool? requiredFieldsComplete,
    bool? hasDoorNumber,
    bool? leafCategoryPrecise,
  }) {
    return CompletenessAssessment(
      requiredFieldsComplete:
          requiredFieldsComplete ?? this.requiredFieldsComplete,
      hasDoorNumber: hasDoorNumber ?? this.hasDoorNumber,
      leafCategoryPrecise: leafCategoryPrecise ?? this.leafCategoryPrecise,
    );
  }
}

/// 每日 AI 配额上限（§5.10「AI 配额二维分层」）。
///
/// 口径逐字取自 §5.10：实名+🟢=20、实名+🟡=10、未实名或 🔴=3，高敏类目额外 +10。
///
/// 参数 [verified] 是否已实名，[level] 当前完整度档，
/// [sensitiveCategory] 是否高敏类目（§2.4 需资质的叶子）。
/// 返回：该用户当日可用的 AI 次数上限。
///
/// **注意这只是上限，不是剩余次数** —— §5.9「仅确认发布才计 1 次」的计数必须
/// 在服务端（客户端计数清缓存即归零），故本函数不做扣减。
int dailyAiQuota({
  required bool verified,
  required CompletenessLevel level,
  bool sensitiveCategory = false,
}) {
  // 未实名与 🔴 档合并为同一档，是 §5.10 的原文口径（「未实名或 🔴」），
  // 不是简化 —— 两者任一成立就落到 3 次。
  final base = switch ((verified, level)) {
    (false, _) => 3,
    (true, CompletenessLevel.red) => 3,
    (true, CompletenessLevel.yellow) => 10,
    (true, CompletenessLevel.green) => 20,
  };
  return base + (sensitiveCategory ? 10 : 0);
}
