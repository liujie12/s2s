/// AI 智能发布 DTO（B2-4；对应 openapi `AiParseRequest`/`AiParseResult`/`AiGuess`/`AiQuota`）。
///
/// 手写 fromJson/toJson（与 `features/post/post_dto.dart` 同范式）：snake_case 逐字对齐
/// 契约，经 `lib/core/contract_json.dart` 助手取值，类型违约抛 [ApiException.parse]。
library;

import '../../core/contract_json.dart';

/// AI 解析入参（`POST /ai/publish/parse`）。
///
/// 四模式共用（PRD §5.9）。[toJson] **只输出非 null 键**（服务端按 null 判空，
/// 送多个 `null` 会被误判成「传了但为空」）。
class AiParseRequestDto {
  /// 构造解析入参。
  ///
  /// 参数：[mediaId] 图片媒体 ID（模式①/④）；[voiceMediaId] 音频媒体 ID（模式②）；
  /// [voiceText] 客户端已转写语音文本；[text] 自由文本；[kind] 类型（resource/demand）；
  /// [leafCategoryId] 当前叶子类目 ID；[completenessLevel] 当前草稿完整度档（0/1/2）。
  const AiParseRequestDto({
    this.mediaId,
    this.voiceMediaId,
    this.voiceText,
    this.text,
    this.kind,
    this.leafCategoryId,
    this.completenessLevel,
  });

  /// 图片媒体 ID（模式①/④）。
  final String? mediaId;

  /// 音频媒体 ID（模式②；服务端走已备案模型 ASR）。
  final String? voiceMediaId;

  /// 客户端已转写的语音文本。
  final String? voiceText;

  /// 自由文本输入。
  final String? text;

  /// 类型（resource/demand）。
  final String? kind;

  /// 当前叶子类目 ID。
  final int? leafCategoryId;

  /// 当前草稿完整度档（0/1/2）。
  final int? completenessLevel;

  /// 序列化为契约 snake_case 载荷（只含非 null 键）。
  ///
  /// 返回：[Map] 契约请求体。
  Map<String, Object?> toJson() {
    final map = <String, Object?>{};
    if (mediaId != null) map['media_id'] = mediaId;
    if (voiceMediaId != null) map['voice_media_id'] = voiceMediaId;
    if (voiceText != null) map['voice_text'] = voiceText;
    if (text != null) map['text'] = text;
    if (kind != null) map['kind'] = kind;
    if (leafCategoryId != null) map['leaf_category_id'] = leafCategoryId;
    if (completenessLevel != null) map['completeness_level'] = completenessLevel;
    return map;
  }
}

/// AI 四件套猜测（openapi `AiGuess`）。
class AiGuessDto {
  /// 构造猜测（解析后）。
  const AiGuessDto({
    this.title,
    this.leafCategoryId,
    this.price,
    this.priceUnit,
    this.templateValues,
  });

  /// 标题。
  final String? title;

  /// 叶子类目 ID。
  final int? leafCategoryId;

  /// 价格（元）。
  final double? price;

  /// 价格单位。
  final String? priceUnit;

  /// 模板字段猜测（键取自模板 fields[].key）。
  final Map<String, Object?>? templateValues;

  /// 从契约 JSON 解析。
  ///
  /// 参数：[json] 信封 data 内的 `guess` 节点。
  /// 返回：[AiGuessDto]。
  /// 抛出：[ApiException.parse] 结构违约时。
  factory AiGuessDto.fromJson(Object? json) {
    final map = requireMap(json, 'AiGuess');
    final rawTemplateValues = map['template_values'];
    return AiGuessDto(
      title: optString(map, 'title', 'AiGuess'),
      leafCategoryId: optInt(map, 'leaf_category_id', 'AiGuess'),
      price: optDouble(map, 'price', 'AiGuess'),
      priceUnit: optString(map, 'price_unit', 'AiGuess'),
      templateValues:
          rawTemplateValues is Map ? rawTemplateValues.cast<String, Object?>() : null,
    );
  }
}

/// AI 配额快照（openapi `AiQuota`）。
class AiQuotaDto {
  /// 构造配额快照。
  const AiQuotaDto({
    required this.used,
    required this.limit,
    required this.resetAt,
  });

  /// 今日已用次数。
  final int used;

  /// 今日上限。
  final int limit;

  /// 配额重置时间（次日 00:00）。
  final DateTime resetAt;

  /// 从契约 JSON 解析。
  ///
  /// 参数：[json] 信封 data 内的 `quota` 节点。
  /// 返回：[AiQuotaDto]。
  /// 抛出：[ApiException.parse] 结构违约时。
  factory AiQuotaDto.fromJson(Object? json) {
    final map = requireMap(json, 'AiQuota');
    return AiQuotaDto(
      used: requireInt(map, 'used', 'AiQuota'),
      limit: requireInt(map, 'limit', 'AiQuota'),
      resetAt: requireDateTime(map, 'reset_at', 'AiQuota'),
    );
  }
}

/// AI 解析结果（openapi `AiParseResult`）。
class AiParseResultDto {
  /// 构造解析结果。
  const AiParseResultDto({
    required this.guess,
    required this.scopeVerified,
    required this.unresolvedFields,
    this.quota,
  });

  /// 四件套猜测。
  final AiGuessDto guess;

  /// 已注入字段的来源（键为字段名，值为 user_input/neighbor_mode/platform）。
  final Map<String, String> scopeVerified;

  /// 被拒绝注入（留空）的字段。
  final List<String> unresolvedFields;

  /// 配额快照（可空；契约未列入 required）。
  final AiQuotaDto? quota;

  /// 从契约 JSON 解析。
  ///
  /// 参数：[json] 信封 `data` 本体。
  /// 返回：[AiParseResultDto]。
  /// 抛出：[ApiException.parse] 结构违约时。
  factory AiParseResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'AiParseResult');

    final rawVerified = map['scope_verified'];
    final verified = <String, String>{};
    if (rawVerified is Map) {
      rawVerified.forEach((key, value) {
        verified['$key'] = '${value ?? ''}';
      });
    }

    final rawQuota = map['quota'];

    return AiParseResultDto(
      guess: AiGuessDto.fromJson(map['guess']),
      scopeVerified: verified,
      unresolvedFields: optStringList(map, 'unresolved_fields', 'AiParseResult') ??
          const <String>[],
      quota: rawQuota == null ? null : AiQuotaDto.fromJson(rawQuota),
    );
  }
}
