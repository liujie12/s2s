/// post 域仓库（[124]/[125] 前端段 / B4）：发布前置校验。
///
/// 与 `CategoryRepository` 同一模式：真网络走 [dioProvider] 生产同款
/// 五拦截器链（mock 期打 MockApiServer，后端就绪切 baseUrl 断言一行
/// 不改）；本层只做「发请求 + 交 DTO 解析」，信封由 EnvelopeInterceptor
/// 拆、业务错误以 [ApiException] 抛出，本层不吞不改写（编码规范 §1.2）。
///
/// **幂等头说明**：precheck 是 POST，HeaderInterceptor 会按「写接口
/// 缺失即注入」纪律注入 Idempotency-Key；precheck 不写库（契约
/// description），服务端不做 SETNX 判定，多余头无副作用——不为单一
/// 端点在拦截器开例外，例外比无害头更危险（详设 §11.2 幂等键仅
/// POST/PATCH 注入的通用纪律优先）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import 'post_dto.dart';

/// post 域仓库。
///
/// 无实例状态，不需要单实例纪律；dio 由构造注入，与 [dioProvider]
/// 生产装配同源。
class PostRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness
  ///   注入，生产经 [postRepositoryProvider] 注入）。
  PostRepository(this._dio);

  final Dio _dio;

  /// 发布前置校验（`POST /posts/precheck`，不落库）。
  ///
  /// 在用户点击「发布」之后、正式提交之前调用，提前暴露阻断项
  /// （敏感词/图片/禁发/资质/未实名上限），避免填完长表单才在
  /// `POST /posts` 被打回。**发现问题时服务端仍回 200 + code=0**，
  /// 阻断项在 [PrecheckResultDto.blocks]，链上不报错。
  ///
  /// 参数：
  ///   [draft] PostDraft 载荷（契约全字段非必填，允许对半成品预校验；
  ///     由 `PublishFormState.postDraftPayload` 构造，B5 `POST /posts`
  ///     复用同一构造）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id（详设 §11.2
  ///     逐层透传）；null 时由 HeaderInterceptor 兜底生成。
  /// 返回：[PrecheckResultDto]（passed=false 时 blocks 一次性给全）。
  /// 抛出：[ApiException] 信封业务错误/解析失败/传输错误归一后的异常
  ///   （precheck 本身失败属链路错误，与「校验不通过」语义不同，由
  ///   调用方按 §12.2 行为表处理）。
  Future<PrecheckResultDto> precheck(
    Map<String, Object?> draft, {
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/posts/precheck',
      data: draft,
      options: _interactionOptions(interactionId),
    );
    return PrecheckResultDto.fromJson(response.data);
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options]；null（dio 接受 null options 走 BaseOptions 默认）。
  ///   头注入走「containsKey 才写」纪律：这里显式设了头，
  ///   HeaderInterceptor 不会覆盖；null 时由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// post 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final postRepositoryProvider = Provider<PostRepository>(
  (ref) => PostRepository(ref.watch(dioProvider)),
);
