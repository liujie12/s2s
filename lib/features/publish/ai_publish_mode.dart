/// T2 AI 智能发布四模式（PRD §5.9 / §6.13 T6-①）。
///
/// **为什么单列一个枚举而不是在弹层里写死四个按钮**：模式是「一次发布的起点」，
/// 它要被入口弹层、确认页、埋点三处引用。写死字符串则三处各写一遍，
/// 任一处改了另两处不会报错。
library;

/// AI 发布四模式。
enum AiPublishMode {
  /// ① 多媒体 7 秒输入（T2 主路径）：拍 1 张图 + 说 1 句话。
  media,

  /// ② 语音零键盘：全程语音（阶段① 调已备案 API）。
  voice,

  /// ③ 对话式一问一答（S5）：每屏 1 问。
  dialog,

  /// ④ 抢发模式（S5）：只填标题 + 拍照即发布，24h 内补全。
  flash,
}

/// 模式展示属性。
extension AiPublishModeX on AiPublishMode {
  /// 模式标题（弹层主文案）。
  String get label => switch (this) {
    AiPublishMode.media => '拍张图，说一句',
    AiPublishMode.voice => '语音说，零键盘',
    AiPublishMode.dialog => '一问一答，新手引导',
    AiPublishMode.flash => '抢发：先占位再补全',
  };

  /// 模式副文案（弹层说明）。
  String get description => switch (this) {
    AiPublishMode.media => '拍 1 张图 + 说 1 句话，AI 自动填好（约 3 秒）',
    AiPublishMode.voice => '点一下开始，说一句话，再点停止',
    AiPublishMode.dialog => '每屏 1 问，8 问填完即发布，新手首选',
    AiPublishMode.flash => '只填标题 + 拍照即发布，24 小时内补全',
  };

  /// 本期是否可用（四模式已全量开放）。
  bool get isAvailable => true;
}
