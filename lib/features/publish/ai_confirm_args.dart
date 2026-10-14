/// AI 确认页入参（PRD §5.9 四模式共用）。
///
/// **为什么单列入参对象而不是给 [AiConfirmScreen] 加多个可选参数**：
/// 模式①②④ 进入确认页时携带的信息不同（① 有图 + 一句话；④ 有图 + 标题；
/// 从发布页进则只有表单）。把三者收进一个对象，路由侧只需透传一个 `extra`，
/// 也让「是否抢发」的判据（[flashMode]）只有一个来源。
///
/// 与页面解耦：本文件只依赖 [PublishFormState]，不引 go_router / Flutter，
/// 便于路由与页面共用而不成环（同 `publish_screen_args.dart` 的取向）。
library;

import 'publish_form_state.dart';

/// AI 确认页入参。
class AiConfirmArgs {
  /// 构造确认页入参。
  ///
  /// 参数：
  ///   [form] 进入时的表单快照（AI 猜测的 scope，§5.10 Step 2）；
  ///   [initialText] 模式① 的「一句话」原文；为空时用 [form] 的标题/描述兜底；
  ///   [initialMediaId] 模式①④ 已 commit 的图片媒体 ID（解析入参 `media_id`）；
  ///   [initialVoiceMediaId] 模式② 已 commit 的音频媒体 ID（解析入参 `voice_media_id`）；
  ///   [flashMode] 是否抢发模式（④）——「只填标题 + 拍照就发布」，
  ///     允许必填未齐即发布并落 🔴（§5.9/§5.11 的 24h 补全口径）。
  const AiConfirmArgs({
    this.form = const PublishFormState(),
    this.initialText,
    this.initialMediaId,
    this.initialVoiceMediaId,
    this.flashMode = false,
  });

  /// 表单快照。
  final PublishFormState form;

  /// 模式① 的一句话原文（可空）。
  final String? initialText;

  /// 已上传图片的媒体 ID（可空）。
  final String? initialMediaId;

  /// 已上传音频的媒体 ID（模式②，可空）。
  final String? initialVoiceMediaId;

  /// 是否抢发模式（④）。
  final bool flashMode;
}
