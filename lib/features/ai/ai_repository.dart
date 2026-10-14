/// ai 域仓库（B2-4）：AI 智能发布解析与配额查询。
///
/// 与 `features/post/post_repository.dart` 同一模式：真网络走 [dioProvider]
/// 生产同款五拦截器链；本层只做「发请求 + 交 DTO 解析」，信封由
/// EnvelopeInterceptor 拆、业务错误以 [ApiException] 抛出，本层不吞不改写。
///
/// **幂等头说明**：`POST /ai/publish/parse` 是 POST，HeaderInterceptor 会按
/// 「写接口缺失即注入」纪律注入 Idempotency-Key；同一次解析重试不重复打上游。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'ai_dto.dart';

/// ai 域仓库。
///
/// 无实例状态；dio 由构造注入，与 [dioProvider] 生产装配同源。
class AiRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入，
  /// 生产经 [aiRepositoryProvider] 注入）。
  AiRepository(this._dio);

  final Dio _dio;

  /// AI 智能发布解析（`POST /ai/publish/parse`，四模式共用）。
  ///
  /// 参数：
  ///   [req] 解析入参（至少一项输入非空，由调用方保证）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[AiParseResultDto]（四件套猜测 + 来源 + 未解析字段 + 配额快照）。
  /// 抛出：信封业务错误（40001 参数非法 / 40101 未登录 / 42901 配额耗尽 /
  ///   50301 AI 不可用）与传输错误归一后的异常。
  Future<AiParseResultDto> parse(
    AiParseRequestDto req, {
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/ai/publish/parse',
      data: req.toJson(),
      options: _interactionOptions(interactionId),
    );
    return AiParseResultDto.fromJson(response.data);
  }

  /// 查询今日 AI 配额（`GET /ai/publish/quota`，只读）。
  ///
  /// 参数：
  ///   [completenessLevel] 当前草稿完整度档（0/1/2；缺省视为最保守档）；
  ///   [leafCategoryId] 当前叶子类目 ID（用于高敏类目 +10）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[AiQuotaDto]（used/limit/reset_at）。
  /// 抛出：[ApiException] 信封业务错误（40101 未登录）与传输错误归一后的异常。
  Future<AiQuotaDto> fetchQuota({
    int? completenessLevel,
    int? leafCategoryId,
    String? interactionId,
  }) async {
    final query = <String, Object?>{};
    if (completenessLevel != null) query['completeness_level'] = completenessLevel;
    if (leafCategoryId != null) query['leaf_category_id'] = leafCategoryId;
    final response = await _dio.get<Object?>(
      '/ai/publish/quota',
      queryParameters: query,
      options: _interactionOptions(interactionId),
    );
    return AiQuotaDto.fromJson(response.data);
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options]；null 时走 BaseOptions 默认，由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// ai 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final aiRepositoryProvider = Provider<AiRepository>(
  (ref) => AiRepository(ref.watch(dioProvider)),
);
