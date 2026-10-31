/// chat 域契约 DTO（2026-10-31）：`docs/api/openapi.yaml` 分组八之二的逐字段映射。
///
/// 口径（契约注释同源）：
///   - 会话列表行只出 `unread` 布尔，条数只在未读汇总与「服务号」行出现（R9）；
///   - 消息 `items` 恒按 `seq` 正序，客户端不按请求方向切换渲染顺序（R6）；
///   - 联系方式卡 `content` 恒为 null，卡片不承载完整号码（R22）；
///   - 申请卡状态只读 `ContactApplyState`，号码仍走 `GET /posts/{id}/contact`。
///
/// 解析统一引用 `core/contract_json.dart` 助手：类型违约经
/// [ApiException.parse] 抛出（编码规范 §1.1 唯一解析失败入口）。
library;

import '../../core/contract_json.dart';

/// 开会话结果（openapi `ConversationCreateResult`）。
class ConversationCreateResultDto {
  /// 构造结果。
  ///
  /// 参数：[conversationId] 会话 ID；[created] 是否本次新建。
  const ConversationCreateResultDto({
    required this.conversationId,
    required this.created,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `POST /conversations` 的 data。
  /// 返回：[ConversationCreateResultDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ConversationCreateResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'ConversationCreateResult');
    return ConversationCreateResultDto(
      conversationId: requireInt(map, 'conversation_id', 'ConversationCreateResult'),
      created: requireBool(map, 'created', 'ConversationCreateResult'),
    );
  }

  /// 会话 ID。
  final int conversationId;

  /// true=本次新建（消耗一次每日额度）；false=复用既有会话。
  final bool created;
}

/// 会话列表行（openapi `ConversationItem`）。
class ConversationDto {
  /// 构造会话行。
  ///
  /// 参数：字段与契约一一对应，含义见各属性注释。
  const ConversationDto({
    required this.conversationId,
    required this.postId,
    required this.postGone,
    required this.peerId,
    required this.peerNickname,
    required this.unread,
    required this.applyStatus,
    this.postTitle,
    this.peerAvatarUrl,
    this.lastMessageType,
    this.lastMessagePreview,
    this.lastMessageAt,
  });

  /// 由信封 data.items 元素构造。
  ///
  /// 参数：[json] `GET /conversations` 的 data.items 元素。
  /// 返回：[ConversationDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ConversationDto.fromJson(Object? json) {
    final map = requireMap(json, 'ConversationItem');
    return ConversationDto(
      conversationId: requireInt(map, 'conversation_id', 'ConversationItem'),
      postId: requireInt(map, 'post_id', 'ConversationItem'),
      postGone: requireBool(map, 'post_gone', 'ConversationItem'),
      peerId: requireInt(map, 'peer_id', 'ConversationItem'),
      peerNickname: requireString(map, 'peer_nickname', 'ConversationItem'),
      unread: requireBool(map, 'unread', 'ConversationItem'),
      applyStatus: requireString(map, 'apply_status', 'ConversationItem'),
      postTitle: optString(map, 'post_title', 'ConversationItem'),
      peerAvatarUrl: optString(map, 'peer_avatar_url', 'ConversationItem'),
      lastMessageType: optString(map, 'last_message_type', 'ConversationItem'),
      lastMessagePreview: optString(map, 'last_message_preview', 'ConversationItem'),
      lastMessageAt: optDateTime(map, 'last_message_at', 'ConversationItem'),
    );
  }

  /// 会话 ID。
  final int conversationId;

  /// 会话所锚定的帖子 ID。
  final int postId;

  /// 帖子对他人是否已不可见（下架/过期）；true 时缩略图置灰并标注「已下架」。
  final bool postGone;

  /// 对方 user_id。
  final int peerId;

  /// 对方昵称。
  final String peerNickname;

  /// 是否有未读（红点，不含本人发出的消息）。
  final bool unread;

  /// 申请卡状态（`none`/`pending`/`approved`/`rejected`）。
  final String applyStatus;

  /// 帖子标题（可空）。
  final String? postTitle;

  /// 对方头像 URL（可空）。
  final String? peerAvatarUrl;

  /// 最后一条消息类型（`text`/`apply`/`contact`；空会话为 null）。
  final String? lastMessageType;

  /// 最后一条消息摘要（可空）。
  final String? lastMessagePreview;

  /// 最后一条消息时刻（可空）。
  final DateTime? lastMessageAt;
}

/// 会话列表分页（openapi `ConversationPage`）。
class ConversationPageDto {
  /// 构造分页。
  ///
  /// 参数：[items] 当前页；[total] 总数；[page] 页码；[pageSize] 每页条数。
  const ConversationPageDto({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `GET /conversations` 的 data。
  /// 返回：[ConversationPageDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ConversationPageDto.fromJson(Object? json) {
    final map = requireMap(json, 'ConversationPage');
    return ConversationPageDto(
      items: [
        for (final item in requireList(map, 'items', 'ConversationPage'))
          ConversationDto.fromJson(item),
      ],
      total: requireInt(map, 'total', 'ConversationPage'),
      page: requireInt(map, 'page', 'ConversationPage'),
      pageSize: requireInt(map, 'page_size', 'ConversationPage'),
    );
  }

  /// 当前页会话行。
  final List<ConversationDto> items;

  /// 符合条件的总条数。
  final int total;

  /// 当前页码。
  final int page;

  /// 每页条数。
  final int pageSize;
}

/// 单条消息（openapi `ChatMessageItem`）。
class ChatMessageDto {
  /// 构造消息。
  ///
  /// 参数：字段与契约一一对应，含义见各属性注释。
  const ChatMessageDto({
    required this.messageId,
    required this.seq,
    required this.senderId,
    required this.type,
    required this.createdAt,
    this.content,
  });

  /// 由信封 data.items 元素构造。
  ///
  /// 参数：[json] `GET /conversations/{id}/messages` 的 data.items 元素。
  /// 返回：[ChatMessageDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ChatMessageDto.fromJson(Object? json) {
    final map = requireMap(json, 'ChatMessageItem');
    return ChatMessageDto(
      messageId: requireInt(map, 'message_id', 'ChatMessageItem'),
      seq: requireInt(map, 'seq', 'ChatMessageItem'),
      senderId: requireInt(map, 'sender_id', 'ChatMessageItem'),
      type: requireString(map, 'type', 'ChatMessageItem'),
      createdAt: requireDateTime(map, 'created_at', 'ChatMessageItem'),
      content: optString(map, 'content', 'ChatMessageItem'),
    );
  }

  /// 消息 ID。
  final int messageId;

  /// 会话内序号（单调递增，兼作增量游标与已读水位）。
  final int seq;

  /// 发送者 user_id（据此判断左右气泡）。
  final int senderId;

  /// 消息类型（`text`/`apply`/`contact`）。
  final String type;

  /// 创建时间。
  final DateTime createdAt;

  /// 文本正文；卡片类为 null。
  final String? content;
}

/// 消息分页（openapi `MessagePage`）。
class MessagePageDto {
  /// 构造分页。
  ///
  /// 参数：[items] 消息（恒按 seq 正序）；[hasMore] 是否还有更多。
  const MessagePageDto({required this.items, required this.hasMore});

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `GET /conversations/{id}/messages` 的 data。
  /// 返回：[MessagePageDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory MessagePageDto.fromJson(Object? json) {
    final map = requireMap(json, 'MessagePage');
    return MessagePageDto(
      items: [
        for (final item in requireList(map, 'items', 'MessagePage'))
          ChatMessageDto.fromJson(item),
      ],
      hasMore: requireBool(map, 'has_more', 'MessagePage'),
    );
  }

  /// 当前页消息（按 seq 正序）。
  final List<ChatMessageDto> items;

  /// 是否还有更多（历史方向=更早；增量方向=更新）。
  final bool hasMore;
}

/// 发送结果（openapi `MessageSendResult`）。
class MessageSendResultDto {
  /// 构造发送结果。
  ///
  /// 参数：[messageId] 消息 ID；[conversationId] 会话 ID；[seq] 会话内序号；
  ///   [createdAt] 服务端落库时刻。
  const MessageSendResultDto({
    required this.messageId,
    required this.conversationId,
    required this.seq,
    required this.createdAt,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `POST /conversations/{id}/messages` 的 data。
  /// 返回：[MessageSendResultDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory MessageSendResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'MessageSendResult');
    return MessageSendResultDto(
      messageId: requireInt(map, 'message_id', 'MessageSendResult'),
      conversationId: requireInt(map, 'conversation_id', 'MessageSendResult'),
      seq: requireInt(map, 'seq', 'MessageSendResult'),
      createdAt: requireDateTime(map, 'created_at', 'MessageSendResult'),
    );
  }

  /// 消息 ID。
  final int messageId;

  /// 会话 ID。
  final int conversationId;

  /// 会话内序号（客户端据此替换本地「发送中」行）。
  final int seq;

  /// 落库时刻。
  final DateTime createdAt;
}

/// 置已读结果（openapi `ConversationReadResult`）。
class ConversationReadResultDto {
  /// 构造结果。
  ///
  /// 参数：[lastReadSeq] 推进后的已读水位。
  const ConversationReadResultDto({required this.lastReadSeq});

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `POST /conversations/{id}/read` 的 data。
  /// 返回：[ConversationReadResultDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ConversationReadResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'ConversationReadResult');
    return ConversationReadResultDto(
      lastReadSeq: requireInt(map, 'last_read_seq', 'ConversationReadResult'),
    );
  }

  /// 推进后的已读水位（只增不减）。
  final int lastReadSeq;
}

/// 未读汇总（openapi `UnreadSummary`，R8 / KTD9 唯一出口）。
class UnreadSummaryDto {
  /// 构造汇总。
  ///
  /// 参数：[total] 未读总数；[conversationUnread] 会话未读；[notificationUnread] 通知未读。
  const UnreadSummaryDto({
    required this.total,
    required this.conversationUnread,
    required this.notificationUnread,
  });

  /// 全零汇总（未登录时的确定值，不发请求）。
  static const UnreadSummaryDto zero = UnreadSummaryDto(
    total: 0,
    conversationUnread: 0,
    notificationUnread: 0,
  );

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `GET /unread-summary` 的 data。
  /// 返回：[UnreadSummaryDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory UnreadSummaryDto.fromJson(Object? json) {
    final map = requireMap(json, 'UnreadSummary');
    return UnreadSummaryDto(
      total: requireInt(map, 'total', 'UnreadSummary'),
      conversationUnread: requireInt(map, 'conversation_unread', 'UnreadSummary'),
      notificationUnread: requireInt(map, 'notification_unread', 'UnreadSummary'),
    );
  }

  /// 未读总数（服务端相加，客户端不做二次求和）。
  final int total;

  /// 会话未读条数。
  final int conversationUnread;

  /// 通知未读条数。
  final int notificationUnread;
}

/// 联系方式申请卡状态（openapi `ContactApplyState`）。
class ContactApplyStateDto {
  /// 构造申请卡状态。
  ///
  /// 参数：[conversationId] 会话 ID；[applyRequired] 帖子是否需申请；
  ///   [applyStatus] 卡状态；[owner] 当前用户是否发布者；[canApply] 此刻能否申请；
  ///   [canViewContact] 此刻能否取号；[reapplyAt] 下次可再次申请时刻。
  const ContactApplyStateDto({
    required this.conversationId,
    required this.applyRequired,
    required this.applyStatus,
    required this.owner,
    required this.canApply,
    required this.canViewContact,
    this.reapplyAt,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] `GET/POST /conversations/{id}/apply` 等的 data。
  /// 返回：[ContactApplyStateDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ContactApplyStateDto.fromJson(Object? json) {
    final map = requireMap(json, 'ContactApplyState');
    return ContactApplyStateDto(
      conversationId: requireInt(map, 'conversation_id', 'ContactApplyState'),
      applyRequired: requireBool(map, 'apply_required', 'ContactApplyState'),
      applyStatus: requireString(map, 'apply_status', 'ContactApplyState'),
      owner: requireBool(map, 'owner', 'ContactApplyState'),
      canApply: requireBool(map, 'can_apply', 'ContactApplyState'),
      canViewContact: requireBool(map, 'can_view_contact', 'ContactApplyState'),
      reapplyAt: optDateTime(map, 'reapply_at', 'ContactApplyState'),
    );
  }

  /// 会话 ID。
  final int conversationId;

  /// 该帖是否设置了「查看联系方式需申请」。
  final bool applyRequired;

  /// 卡状态（`none`/`pending`/`approved`/`rejected`）。
  final String applyStatus;

  /// 当前用户是否为帖子发布者（发布者审批，不申请）。
  final bool owner;

  /// 此刻能否提交申请。
  final bool canApply;

  /// 此刻能否取号（发布者本人 / 无需申请 / 已同意）；取号仍走唯一出口。
  final bool canViewContact;

  /// 下次可再次申请的时刻（可空）。
  final DateTime? reapplyAt;
}

/// 会话内举报受理结果（openapi `POST /conversations/{id}/report` 的 data）。
class ConversationReportResultDto {
  /// 构造结果。
  ///
  /// 参数：[reportId] 工单 ID；[status] 工单状态。
  const ConversationReportResultDto({
    required this.reportId,
    required this.status,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 举报接口的 data。
  /// 返回：[ConversationReportResultDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory ConversationReportResultDto.fromJson(Object? json) {
    final map = requireMap(json, 'ConversationReportResult');
    return ConversationReportResultDto(
      reportId: requireInt(map, 'report_id', 'ConversationReportResult'),
      status: requireString(map, 'status', 'ConversationReportResult'),
    );
  }

  /// 举报工单 ID。
  final int reportId;

  /// 工单状态（`pending`/`handled`/`dismissed`）。
  final String status;
}
