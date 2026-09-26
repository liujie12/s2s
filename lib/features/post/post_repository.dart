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

import '../../nfr_constants.dart';
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

  /// 发布帖子（`POST /posts`，[125] B5）。
  ///
  /// 幂等：契约挂 `Idempotency-Key` 参数，HeaderInterceptor 按「写接口
  /// 缺失即注入」纪律自动生成 UUID v4；重试链（RetryInterceptor）已按
  /// 「containsKey 才写」保全同键重发（详设 §11.1.1），本层不碰该头。
  /// 服务端 SETNX 首次成功响应缓存后，同键重放原样返回首次结果。
  ///
  /// 参数：
  ///   [draft] 与 precheck 同源的 PostDraft 载荷（必填项由
  ///     `PublishFormState.postDraftPayload` 构造侧保证齐全——本地闸门
  ///     全过才会走到本方法）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[PostCreatedDto]（服务端生成的 id/version 及派生字段回执）。
  /// 抛出：[ApiException] 信封业务错误（含发布阻断五码 40901/40902/
  ///   40302/40303/40304、参数 40001、未登录 40101 等）与传输错误归一
  ///   后的异常，由调用方按 §12.2 行为表处理。
  Future<PostCreatedDto> createPost(
    Map<String, Object?> draft, {
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/posts',
      data: draft,
      options: _interactionOptions(interactionId),
    );
    return PostCreatedDto.fromJson(response.data);
  }

  /// 查帖子详情（`GET /posts/{post_id}`，游客可读，[127]）。
  ///
  /// 参数：
  ///   [postId] 帖子 ID（契约路径参数 int64）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[PostDetailDto] 详情（详情页消费字段，映射到域模型在
  ///   `post_detail_provider.dart` 完成）。
  /// 抛出：[ApiException] 信封业务错误（含 41001 已下架、42907 游客限频）/
  ///   解析失败/传输错误归一后的异常，由调用方按 §12.2 行为表处理。
  Future<PostDetailDto> fetchDetail(
    int postId, {
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/posts/$postId',
      options: _interactionOptions(interactionId),
    );
    return PostDetailDto.fromJson(response.data);
  }

  /// 查「我的发布」列表（`GET /posts/mine`，[127] 前端段）。
  ///
  /// **筛选只接受契约单值**（openapi `status` 参数 `$ref: PostStatusEnum`）：
  /// 「已下架」Tab 只传 `offline`，`expired`/`archived` 仅在「全部」Tab
  /// 可见并各自标状态（2026-09-27 用户裁定，见说明文档 §2.9）。
  ///
  /// 参数：
  ///   [page] 页码（从 1 起；服务端会再钳制一次）；
  ///   [pageSize] 每页条数（默认 [NfrApi.pageSizeDefault]，服务端钳上限）；
  ///   [status] API 状态筛选值；null = 不筛选（「全部」Tab）；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[MyPostsPageDto]（items/total/page/page_size）。
  /// 抛出：[ApiException] 信封业务错误（40001 非法 status）/解析失败/传输错误。
  Future<MyPostsPageDto> fetchMine({
    int page = 1,
    int pageSize = NfrApi.pageSizeDefault,
    String? status,
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/posts/mine',
      queryParameters: <String, Object?>{
        'page': page,
        'page_size': pageSize,
        // 缺省不传 status：契约 required=false，传空串会被服务端判非法值
        if (status != null) 'status': status,
      },
      options: _interactionOptions(interactionId),
    );
    return MyPostsPageDto.fromJson(response.data);
  }

  /// 变更帖子状态（`PATCH /posts/{post_id}/status`，[127] 前端段）。
  ///
  /// **乐观锁强约束**：必须带上从 `fetchMine`/`fetchDetail` 取得的
  /// [version]（契约 description：缺失回 40001，服务端不得兜底）。影响行数
  /// 为 0（版本不符/非本人/行不存在三成因不区分）一律回 40903，客户端
  /// **不得自动重试**——40903 属 `forceRefetch`（§12.2），须重取列表后由
  /// 用户决定，自动重放只会再吃一次同码。
  ///
  /// 幂等：契约挂 `Idempotency-Key`，HeaderInterceptor 按写接口（POST/PATCH）
  /// 纪律缺失即注入，本层不碰该头。
  ///
  /// 参数：
  ///   [postId] 帖子 ID（契约路径参数 int64）；
  ///   [action] 动作（`offline` 下架 / `republish` 重新上架 / `renew` 延期）；
  ///   [version] 当前乐观锁版本号；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id；null 由拦截器兜底。
  /// 返回：[PostStatusResultDto]（变更后状态/新版本号/到期时间）。
  /// 抛出：[ApiException] 信封业务错误（40001 动作非法、40903 版本冲突、
  ///   40101 未登录）与传输错误归一后的异常。
  Future<PostStatusResultDto> changeStatus(
    int postId, {
    required String action,
    required int version,
    String? interactionId,
  }) async {
    final response = await _dio.patch<Object?>(
      '/posts/$postId/status',
      data: <String, Object?>{'action': action, 'version': version},
      options: _interactionOptions(interactionId),
    );
    return PostStatusResultDto.fromJson(response.data);
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
