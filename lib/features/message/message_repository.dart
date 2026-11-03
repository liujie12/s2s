/// chat 域仓库（2026-10-31）：会话、消息、已读、申请卡、举报与未读汇总。
///
/// 与 `PostRepository` 同一模式：真网络走 [dioProvider] 生产同款五拦截器链，
/// 本层只做「发请求 + 交 DTO 解析」，不做重试（唯一重试点是
/// `RetryInterceptor`，编码规范 §5.5）。
///
/// 幂等（R7）：写接口的 `Idempotency-Key` 默认由 `HeaderInterceptor` 缺失时
/// 注入；**用户点「重发」时必须传入首次的 [idempotencyKey]**，否则会拿到新键、
/// 产生第二条消息。本层只负责「给了就带上」，不生成键。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import '../../nfr_constants.dart';
import 'message_dto.dart';

/// chat 域仓库。
class MessageRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入）。
  MessageRepository(this._dio);

  final Dio _dio;

  /// 开启或复用 1:1 会话（`POST /conversations`，R1 / R5）。
  ///
  /// 参数：[postId] 帖子 ID（会话双方由服务端派生）；
  ///   [interactionId] X-Interaction-Id；[idempotencyKey] 幂等键（重发沿用）。
  /// 返回：[ConversationCreateResultDto]。
  /// 抛出：[ApiException]（41001 帖子不可见 / 40001 与自己开会话 /
  ///   42902 当日额度 / 40305 维护中）/解析失败/传输错误。
  Future<ConversationCreateResultDto> openConversation({
    required int postId,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    final response = await _dio.post<Object?>(
      '/conversations',
      data: <String, Object?>{'post_id': postId},
      options: _writeOptions(
        interactionId: interactionId,
        idempotencyKey: idempotencyKey,
      ),
    );
    return ConversationCreateResultDto.fromJson(response.data);
  }

  /// 会话列表（`GET /conversations`，R3 / R4）。
  ///
  /// 参数：[page] 页码；[pageSize] 每页条数（缺省 [NfrChat.conversationPageDefaultSize]）；
  ///   [interactionId] X-Interaction-Id。
  /// 返回：[ConversationPageDto]。
  /// 抛出：[ApiException]（40101 未登录）/解析失败/传输错误。
  Future<ConversationPageDto> fetchConversations({
    int page = 1,
    int pageSize = NfrChat.conversationPageDefaultSize,
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/conversations',
      queryParameters: <String, Object?>{'page': page, 'page_size': pageSize},
      options: _readOptions(interactionId),
    );
    return ConversationPageDto.fromJson(response.data);
  }

  /// 会话消息（`GET /conversations/{id}/messages`，R6 / R10）。
  ///
  /// 参数：[conversationId] 会话 ID；[beforeSeq] 向更早翻历史的游标（与
  ///   [afterSeq] 互斥）；[afterSeq] 增量拉取游标（取本地最大 seq）；
  ///   [pageSize] 每页条数（缺省 [NfrChat.messagePageDefaultSize]）；
  ///   [interactionId] X-Interaction-Id。
  /// 返回：[MessagePageDto]（items 恒按 seq 正序）。
  /// 抛出：[ApiException]（40001 两游标同传 / 40305 非成员）/解析失败/传输错误。
  Future<MessagePageDto> fetchMessages({
    required int conversationId,
    int? beforeSeq,
    int? afterSeq,
    int pageSize = NfrChat.messagePageDefaultSize,
    String? interactionId,
  }) async {
    final query = <String, Object?>{'page_size': pageSize};
    if (beforeSeq != null) query['before_seq'] = beforeSeq;
    if (afterSeq != null) query['after_seq'] = afterSeq;
    final response = await _dio.get<Object?>(
      '/conversations/$conversationId/messages',
      queryParameters: query,
      options: _readOptions(interactionId),
    );
    return MessagePageDto.fromJson(response.data);
  }

  /// 发送文本消息（`POST /conversations/{id}/messages`，R7 / R26 / R28）。
  ///
  /// 参数：[conversationId] 会话 ID；[content] 正文；[interactionId] X-Interaction-Id；
  ///   [idempotencyKey] 首次发送的幂等键（「重发」必须沿用，防重复消息）。
  /// 返回：[MessageSendResultDto]。
  /// 抛出：[ApiException]（40305 非成员/未回复额度/维护只读、40901 敏感词）等。
  Future<MessageSendResultDto> sendMessage({
    required int conversationId,
    required String content,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    final response = await _dio.post<Object?>(
      '/conversations/$conversationId/messages',
      data: <String, Object?>{'content': content},
      options: _writeOptions(
        interactionId: interactionId,
        idempotencyKey: idempotencyKey,
      ),
    );
    return MessageSendResultDto.fromJson(response.data);
  }

  /// 置会话已读（`POST /conversations/{id}/read`，R10）。
  ///
  /// 参数：[conversationId] 会话 ID；[interactionId] X-Interaction-Id；
  ///   [idempotencyKey] 幂等键（重复提交幂等）。
  /// 返回：[ConversationReadResultDto]（推进后的水位，只增不减）。
  /// 抛出：[ApiException]（40305 非成员）/解析失败/传输错误。
  Future<ConversationReadResultDto> markRead({
    required int conversationId,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    final response = await _dio.post<Object?>(
      '/conversations/$conversationId/read',
      options: _writeOptions(
        interactionId: interactionId,
        idempotencyKey: idempotencyKey,
      ),
    );
    return ConversationReadResultDto.fromJson(response.data);
  }

  /// 删除会话（`DELETE /conversations/{id}`，V33「仅自己删除」）。
  ///
  /// 只把会话从当前用户的消息列表移除，对方不受影响；会话与消息仍保留。
  /// 再次收到新消息或本人重新发起时会话自动恢复可见。重复删除幂等。
  ///
  /// 参数：[conversationId] 会话 ID；[interactionId] X-Interaction-Id。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException]（40305 非成员/会话不存在）/传输错误。
  Future<void> deleteConversation({
    required int conversationId,
    String? interactionId,
  }) async {
    await _dio.delete<Object?>(
      '/conversations/$conversationId',
      options: _writeOptions(interactionId: interactionId),
    );
  }

  /// 未读汇总（`GET /unread-summary`，R8 / KTD9 唯一出口）。
  ///
  /// 参数：[interactionId] X-Interaction-Id。
  /// 返回：[UnreadSummaryDto]。
  /// 抛出：[ApiException]（40101 未登录）/解析失败/传输错误。
  Future<UnreadSummaryDto> fetchUnreadSummary({String? interactionId}) async {
    final response = await _dio.get<Object?>(
      '/unread-summary',
      options: _readOptions(interactionId),
    );
    return UnreadSummaryDto.fromJson(response.data);
  }

  /// 查询申请卡状态（`GET /conversations/{id}/apply`，R20 / R21a / R24）。
  ///
  /// 参数：[conversationId] 会话 ID；[interactionId] X-Interaction-Id。
  /// 返回：[ContactApplyStateDto]。
  /// 抛出：[ApiException]（40305 非成员）/解析失败/传输错误。
  Future<ContactApplyStateDto> fetchApplyState({
    required int conversationId,
    String? interactionId,
  }) async {
    final response = await _dio.get<Object?>(
      '/conversations/$conversationId/apply',
      options: _readOptions(interactionId),
    );
    return ContactApplyStateDto.fromJson(response.data);
  }

  /// 提交（或再次提交）联系方式申请（`POST /conversations/{id}/apply`，R20 / R21）。
  ///
  /// 参数：[conversationId] 会话 ID；[interactionId] X-Interaction-Id；
  ///   [idempotencyKey] 幂等键。
  /// 返回：[ContactApplyStateDto] 提交后的卡片状态。
  /// 抛出：[ApiException]（40001 无需申请/冷却中、40305 非成员/维护中）等。
  Future<ContactApplyStateDto> applyContact({
    required int conversationId,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    final response = await _dio.post<Object?>(
      '/conversations/$conversationId/apply',
      options: _writeOptions(
        interactionId: interactionId,
        idempotencyKey: idempotencyKey,
      ),
    );
    return ContactApplyStateDto.fromJson(response.data);
  }

  /// 审批联系方式申请（`POST /conversations/{id}/apply/decision`，R22 / R23）。
  ///
  /// 参数：[conversationId] 会话 ID；[approved] true=同意，false=拒绝；
  ///   [interactionId] X-Interaction-Id；[idempotencyKey] 幂等键。
  /// 返回：[ContactApplyStateDto] 审批后的卡片状态。
  /// 抛出：[ApiException]（40001 非发布者/无待审批卡、40305 非成员/维护中）等。
  Future<ContactApplyStateDto> decideApply({
    required int conversationId,
    required bool approved,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    final response = await _dio.post<Object?>(
      '/conversations/$conversationId/apply/decision',
      data: <String, Object?>{'approved': approved},
      options: _writeOptions(
        interactionId: interactionId,
        idempotencyKey: idempotencyKey,
      ),
    );
    return ContactApplyStateDto.fromJson(response.data);
  }

  /// 会话内举报 / 误拦反馈（`POST /conversations/{id}/report`，R28 / R29）。
  ///
  /// 参数：[conversationId] 会话 ID；[reason] 原因（含 `misblock`）；
  ///   [remark] 补充说明；[evidence] 证据媒体 ID；[blockedText] 被误拦原文
  ///   （仅 `reason=misblock`）；[interactionId] X-Interaction-Id；
  ///   [idempotencyKey] 幂等键。
  /// 返回：[ConversationReportResultDto]。
  /// 抛出：[ApiException]（40001 参数非法、40305 非成员、41001 会话所在帖不可用）等。
  Future<ConversationReportResultDto> reportConversation({
    required int conversationId,
    required String reason,
    String? remark,
    List<String>? evidence,
    String? blockedText,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    final body = <String, Object?>{
      'reason': reason,
      'remark': ?remark,
      'evidence': ?evidence,
      'blocked_text': ?blockedText,
    };
    final response = await _dio.post<Object?>(
      '/conversations/$conversationId/report',
      data: body,
      options: _writeOptions(
        interactionId: interactionId,
        idempotencyKey: idempotencyKey,
      ),
    );
    return ConversationReportResultDto.fromJson(response.data);
  }

  /// 组装只带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID；null 表示无透传值。
  /// 返回：[Options?]；null 时由拦截器兜底生成。
  Options? _readOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }

  /// 组装写接口选项（可选交互头 + 可选幂等键）。
  ///
  /// 参数：[interactionId] 交互 ID；[idempotencyKey] 幂等键。
  /// 返回：[Options?]；两者都为 null 时返回 null，让拦截器各自兜底生成 ——
  ///   传空表会覆盖 `HeaderInterceptor` 的「containsKey 才写」判断。
  Options? _writeOptions({
    String? interactionId,
    String? idempotencyKey,
  }) {
    if (interactionId == null && idempotencyKey == null) return null;
    return Options(
      headers: {
        HeaderInterceptor.interactionIdHeader: ?interactionId,
        HeaderInterceptor.idempotencyKeyHeader: ?idempotencyKey,
      },
    );
  }
}

/// chat 仓库 Provider（dio 经 [dioProvider] 注入）。
final messageRepositoryProvider = Provider<MessageRepository>(
  (ref) => MessageRepository(ref.watch(dioProvider)),
);
