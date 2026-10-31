/// 会话详情状态层（计划 U13）：消息、已读回执、申请卡、发送与举报。
///
/// 口径：
///   - 消息恒按 `seq` 正序，跨日分组在视图层做（R6）；
///   - 已读回执只读 `MessagePage.peer_last_read_seq`，不自己维护计数器（R17）；
///   - 发送失败保留本地行，重发沿用首次的幂等键，重复提交不产生重复消息（R7）；
///   - 敏感词（40901）与维护只读（40305）把原文交还输入框，由视图层决定保留方式（R28 / R30）；
///   - 申请卡状态只认 `ContactApplyState`，完整号码仍走 `/posts/{id}/contact`（R22）。
///
/// 未读刷新复用 [unreadSummaryProvider] 与 [conversationsProvider]，
/// 本层不另算未读（KTD14）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../nfr_constants.dart';
import '../auth/auth_repository.dart';
import 'message_dto.dart';
import 'message_list_provider.dart';
import 'message_repository.dart';

/// 误拦反馈的契约原因值（openapi `ConversationReportRequest.reason`）。
///
/// 与普通举报共用同一入口，服务端按原因筛选处置（R28 / KTD10）。
const String misblockReportReason = 'misblock';

/// 维护只读的专用文案前缀（openapi `sendMessage` 的 maintenance 示例）。
///
/// 40305 三态共用码值，契约只靠文案区分场景（R30）。客户端据此识别
/// 「维护中」并展示横幅；码值、HTTP 状态与文案真源都在契约，本层不另造。
const String _maintenanceCopy = '消息功能维护中';

/// 未回复额度的专用文案前缀（openapi `sendMessage` 的 unrepliedLimit 示例）。
///
/// 服务端拒绝即代表额度已满，客户端置为只读并提示等待回复（R26）。
const String _unrepliedCopy = '等待对方回复后可继续发送';

/// 本地未落库消息的状态（R7 / R17）。
enum PendingMessageStatus {
  /// 请求在途。
  sending,

  /// 请求失败，可点击重发（沿用同一幂等键）。
  failed,
}

/// 一条尚未被服务端确认的消息。
class PendingMessage {
  /// 构造本地消息。
  ///
  /// 参数：[localId] 本地临时 ID；[content] 正文；[idempotencyKey] 首次发送的
  ///   幂等键（重发必须沿用）；[status] 当前状态。
  const PendingMessage({
    required this.localId,
    required this.content,
    required this.idempotencyKey,
    required this.status,
  });

  /// 本地临时 ID（仅用于列表定位与重发，不与服务端 ID 混用）。
  final String localId;

  /// 正文。
  final String content;

  /// 首次发送的幂等键。
  final String idempotencyKey;

  /// 当前状态。
  final PendingMessageStatus status;

  /// 复制并覆盖状态。
  ///
  /// 参数：[status] 新状态；null 表示保持原值。
  /// 返回：[PendingMessage] 新实例。
  PendingMessage copyWith({PendingMessageStatus? status}) {
    return PendingMessage(
      localId: localId,
      content: content,
      idempotencyKey: idempotencyKey,
      status: status ?? this.status,
    );
  }
}

/// 发送结果（视图层据此决定是否清空输入框）。
class SendFeedback {
  /// 构造发送结果。
  ///
  /// 参数：[keepDraft] true=原文保留在输入框；[error] 失败原因（成功为 null）。
  const SendFeedback({required this.keepDraft, this.error});

  /// 是否把原文交还输入框（敏感词 / 业务拒绝时为 true）。
  final bool keepDraft;

  /// 失败原因；null 表示已发出（或已落到本地失败行）。
  final ApiException? error;
}

/// 申请卡动作结果。
class ApplyActionResult {
  /// 构造结果。
  ///
  /// 参数：[apply] 成功后的卡片状态；[error] 失败原因。
  const ApplyActionResult({this.apply, this.error});

  /// 成功后的卡片状态。
  final ContactApplyStateDto? apply;

  /// 失败原因；null 表示成功。
  final ApiException? error;
}

/// 会话详情数据快照。
class ConversationData {
  /// 构造快照。
  ///
  /// 参数：字段含义见各属性注释。
  const ConversationData({
    required this.messages,
    required this.pending,
    required this.peerLastReadSeq,
    required this.hasMore,
    required this.myUserId,
    this.apply,
    this.maintenance = false,
    this.unrepliedBlocked = false,
  });

  /// 服务端已确认的消息（按 seq 正序）。
  final List<ChatMessageDto> messages;

  /// 本地未落库消息（按发送顺序追加在末尾）。
  final List<PendingMessage> pending;

  /// 对方已读水位（只增不减，R17）。
  final int peerLastReadSeq;

  /// 是否还有更早的历史。
  final bool hasMore;

  /// 当前登录用户 ID（左右气泡与已读回执判定）。
  final int myUserId;

  /// 申请卡状态（可空：拉取失败或帖子已不可用，不拖垮消息主链）。
  final ContactApplyStateDto? apply;

  /// 维护只读（服务端 40305 维护文案确认后置真，R30）。
  final bool maintenance;

  /// 未回复额度已用尽（服务端 40305 未回复文案确认后置真，R26）。
  final bool unrepliedBlocked;

  /// 我方连续未获回复的文本消息条数（R26）。
  ///
  /// 以「对方最后一条文本消息」为界，其后的我方文本消息计数；申请卡与
  /// 联系方式卡不计入。只看服务端已确认的消息，本地失败行不代表已落库。
  int get unrepliedTextCount {
    var lastPeerTextIndex = -1;
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      if (message.senderId != myUserId && message.type == 'text') {
        lastPeerTextIndex = i;
      }
    }
    var count = 0;
    for (var i = lastPeerTextIndex + 1; i < messages.length; i++) {
      final message = messages[i];
      if (message.senderId == myUserId && message.type == 'text') {
        count++;
      }
    }
    return count;
  }

  /// 输入区是否因未回复达上限而禁用。
  bool get isUnrepliedLimitReached =>
      unrepliedBlocked || unrepliedTextCount >= NfrChat.unrepliedTextLimit;

  /// 输入区是否整体禁用（维护只读优先于额度提示）。
  bool get isComposerDisabled => maintenance || isUnrepliedLimitReached;

  /// 复制并覆盖部分字段。
  ///
  /// 参数：[apply] 传 null 时保留原值（拉取失败不清掉已有卡片状态）。
  /// 返回：[ConversationData] 新实例。
  ConversationData copyWith({
    List<ChatMessageDto>? messages,
    List<PendingMessage>? pending,
    int? peerLastReadSeq,
    bool? hasMore,
    int? myUserId,
    ContactApplyStateDto? apply,
    bool? maintenance,
    bool? unrepliedBlocked,
  }) {
    return ConversationData(
      messages: messages ?? this.messages,
      pending: pending ?? this.pending,
      peerLastReadSeq: peerLastReadSeq ?? this.peerLastReadSeq,
      hasMore: hasMore ?? this.hasMore,
      myUserId: myUserId ?? this.myUserId,
      apply: apply ?? this.apply,
      maintenance: maintenance ?? this.maintenance,
      unrepliedBlocked: unrepliedBlocked ?? this.unrepliedBlocked,
    );
  }
}

/// 会话详情状态机。
///
/// family 参数由构造函数注入（Riverpod 3 约定），`build()` 不带参；
/// `isAutoDispose` 由 Provider 侧声明，离开页面即释放消息缓存。
class ConversationNotifier extends AsyncNotifier<ConversationData> {
  /// 构造状态机。
  ///
  /// 参数：[conversationId] 本实例对应的会话 ID。
  ConversationNotifier(this.conversationId);

  /// 会话 ID。
  final int conversationId;

  /// 本地幂等键生成器（仅在首次发送时取一次，重发复用）。
  static const Uuid _uuid = Uuid();

  /// 追加历史在途标志（防触底重复请求）。
  bool _loadingHistory = false;

  @override
  Future<ConversationData> build() async {
    return _load();
  }

  /// 首屏加载：消息 + 申请卡，随后异步置已读并刷新未读口径。
  ///
  /// 参数：无。
  /// 返回：[ConversationData] 首屏快照。
  /// 抛出：[ApiException] 非成员/未登录/传输错误，由 [AsyncValue] 收敛为错误态。
  Future<ConversationData> _load() async {
    final repository = ref.read(messageRepositoryProvider);
    final page = await repository.fetchMessages(conversationId: conversationId);
    final apply = await _fetchApplySafely();
    final data = ConversationData(
      messages: page.items,
      pending: const <PendingMessage>[],
      peerLastReadSeq: page.peerLastReadSeq,
      hasMore: page.hasMore,
      myUserId: _myUserId(),
      apply: apply,
    );
    // 打开会话即全部置已读（R10）；不阻塞首屏渲染
    unawaited(_markReadAndRefresh());
    return data;
  }

  /// 重新拉取首屏（错误态重试）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]。
  Future<void> refresh() async {
    state = const AsyncValue.loading();
    state = await AsyncValue.guard(_load);
  }

  /// 增量拉取（App 回前台 / 审批后刷新卡片与消息）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]；失败静默，保留当前快照。
  Future<void> refreshIncremental() async {
    final current = state.asData?.value;
    if (current == null) return;
    try {
      final repository = ref.read(messageRepositoryProvider);
      final afterSeq = current.messages.isEmpty ? 0 : current.messages.last.seq;
      final page = await repository.fetchMessages(
        conversationId: conversationId,
        afterSeq: afterSeq,
      );
      final apply = await _fetchApplySafely();
      _update(
        (data) => data.copyWith(
          messages: _mergeMessages(data.messages, page.items),
          peerLastReadSeq: math.max(data.peerLastReadSeq, page.peerLastReadSeq),
          apply: apply,
        ),
      );
    } catch (_) {
      // 增量是增益动作：失败保留现有消息，不把页面打成错误态
    }
  }

  /// 向更早翻一页历史。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]；失败静默（已加载消息仍可用）。
  Future<void> loadHistory() async {
    final current = state.asData?.value;
    if (_loadingHistory ||
        current == null ||
        !current.hasMore ||
        current.messages.isEmpty) {
      return;
    }
    _loadingHistory = true;
    try {
      final page = await ref
          .read(messageRepositoryProvider)
          .fetchMessages(
            conversationId: conversationId,
            beforeSeq: current.messages.first.seq,
          );
      _update(
        (data) => data.copyWith(
          messages: _mergeMessages(page.items, data.messages),
          hasMore: page.hasMore,
        ),
      );
    } catch (_) {
      // 同上：翻历史失败不清空已有消息
    } finally {
      _loadingHistory = false;
    }
  }

  /// 发送一条文本消息（R7 / R26 / R28）。
  ///
  /// 参数：[raw] 输入框原文（首尾空白会被裁掉）。
  /// 返回：[SendFeedback]；业务拒绝时 [SendFeedback.keepDraft] 为真，
  ///   网络失败时保留本地失败行，供点击重发。
  Future<SendFeedback> send(String raw) async {
    final content = raw.trim();
    if (content.isEmpty) return const SendFeedback(keepDraft: false);
    final pending = PendingMessage(
      localId: _uuid.v4(),
      content: content,
      idempotencyKey: _uuid.v4(),
      status: PendingMessageStatus.sending,
    );
    _update((data) => data.copyWith(pending: [...data.pending, pending]));
    return _dispatch(pending);
  }

  /// 重发一条本地失败消息（沿用首次的幂等键，R7）。
  ///
  /// 参数：[localId] 本地临时 ID。
  /// 返回：[SendFeedback]；找不到该行或在途时为空操作。
  Future<SendFeedback> retry(String localId) async {
    final current = state.asData?.value;
    if (current == null) return const SendFeedback(keepDraft: false);
    PendingMessage? pending;
    for (final item in current.pending) {
      if (item.localId == localId) {
        pending = item;
        break;
      }
    }
    if (pending == null || pending.status == PendingMessageStatus.sending) {
      return const SendFeedback(keepDraft: false);
    }
    _update(
      (data) => data.copyWith(
        pending: [
          for (final item in data.pending)
            item.localId == localId
                ? item.copyWith(status: PendingMessageStatus.sending)
                : item,
        ],
      ),
    );
    return _dispatch(pending);
  }

  /// 提交（或再次提交）联系方式申请（R21）。
  ///
  /// 参数：无。
  /// 返回：[ApplyActionResult]；成功后刷新申请卡与消息（申请卡本身是一条消息）。
  Future<ApplyActionResult> applyContact() async {
    try {
      final apply = await ref
          .read(messageRepositoryProvider)
          .applyContact(conversationId: conversationId);
      _update((data) => data.copyWith(apply: apply));
      unawaited(refreshIncremental());
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      return ApplyActionResult(apply: apply);
    } catch (e) {
      final error = asApiException(e);
      _flagMaintenanceIfNeeded(error);
      return ApplyActionResult(error: error);
    }
  }

  /// 审批联系方式申请（仅发布者，R22）。
  ///
  /// 参数：[approved] true=同意，false=拒绝。
  /// 返回：[ApplyActionResult]；同意后增量拉取会带回仅申请人可见的联系方式卡。
  Future<ApplyActionResult> decideApply(bool approved) async {
    try {
      final apply = await ref
          .read(messageRepositoryProvider)
          .decideApply(conversationId: conversationId, approved: approved);
      _update((data) => data.copyWith(apply: apply));
      unawaited(refreshIncremental());
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      return ApplyActionResult(apply: apply);
    } catch (e) {
      final error = asApiException(e);
      _flagMaintenanceIfNeeded(error);
      return ApplyActionResult(error: error);
    }
  }

  /// 举报会话对方（R29）。
  ///
  /// 参数：[reason] 契约原因值；[remark] 补充说明（可空）；
  ///   [blockedText] 被误拦原文（仅 `reason=misblock` 使用，可空）。
  /// 返回：[ApiException?]；null 表示已受理。
  Future<ApiException?> reportPeer({
    required String reason,
    String? remark,
    String? blockedText,
  }) async {
    try {
      await ref
          .read(messageRepositoryProvider)
          .reportConversation(
            conversationId: conversationId,
            reason: reason,
            remark: remark,
            blockedText: blockedText,
          );
      return null;
    } catch (e) {
      return asApiException(e);
    }
  }

  /// 敏感词误拦反馈（R28）。
  ///
  /// 参数：[blockedText] 被拦原文。
  /// 返回：[ApiException?]；null 表示已受理。
  Future<ApiException?> reportMisblock(String blockedText) {
    return reportPeer(
      reason: misblockReportReason,
      blockedText: blockedText.isEmpty ? null : blockedText,
    );
  }

  /// 执行一次发送（首次与重发共用）。
  ///
  /// 参数：[pending] 待发送的本地行。
  /// 返回：[SendFeedback]；业务拒绝时移除本地行并把原文交还输入框，
  ///   网络失败时保留本地行并置为可重发。
  Future<SendFeedback> _dispatch(PendingMessage pending) async {
    try {
      final result = await ref
          .read(messageRepositoryProvider)
          .sendMessage(
            conversationId: conversationId,
            content: pending.content,
            idempotencyKey: pending.idempotencyKey,
          );
      final sent = ChatMessageDto(
        messageId: result.messageId,
        seq: result.seq,
        senderId: _myUserId(),
        type: 'text',
        createdAt: result.createdAt,
        content: pending.content,
      );
      _update(
        (data) => data.copyWith(
          messages: _mergeMessages(data.messages, [sent]),
          pending: data.pending
              .where((item) => item.localId != pending.localId)
              .toList(),
          // 服务端接受即证明未回复额度未满，解除本地禁用
          unrepliedBlocked: false,
        ),
      );
      unawaited(ref.read(conversationsProvider.notifier).refresh());
      unawaited(ref.read(unreadSummaryProvider.notifier).refresh());
      return const SendFeedback(keepDraft: false);
    } catch (e) {
      final error = asApiException(e);
      if (error.code == ApiErrorCode.sensitiveWord) {
        _removePending(pending.localId);
        return SendFeedback(keepDraft: true, error: error);
      }
      if (error.code == ApiErrorCode.noPermission) {
        _removePending(pending.localId);
        if (error.message.contains(_maintenanceCopy)) {
          _update((data) => data.copyWith(maintenance: true));
        } else if (error.message.contains(_unrepliedCopy)) {
          _update((data) => data.copyWith(unrepliedBlocked: true));
        }
        return SendFeedback(keepDraft: true, error: error);
      }
      if (error.code != ApiErrorCode.networkFailure) {
        // 其余确定性失败（参数非法等）：原文交还输入框，避免用户重打一遍
        _removePending(pending.localId);
        return SendFeedback(keepDraft: true, error: error);
      }
      // 网络失败/离线：保留本地行，点击重发沿用同一幂等键（R7）
      _update(
        (data) => data.copyWith(
          pending: [
            for (final item in data.pending)
              item.localId == pending.localId
                  ? item.copyWith(status: PendingMessageStatus.failed)
                  : item,
          ],
        ),
      );
      return const SendFeedback(keepDraft: false);
    }
  }

  /// 移除一条本地行。
  ///
  /// 参数：[localId] 本地临时 ID。
  /// 返回：void。
  void _removePending(String localId) {
    _update(
      (data) => data.copyWith(
        pending: data.pending.where((item) => item.localId != localId).toList(),
      ),
    );
  }

  /// 请求失败若为维护文案则置只读（R30）。
  ///
  /// 参数：[error] 归一后的异常。
  /// 返回：void。
  void _flagMaintenanceIfNeeded(ApiException error) {
    if (error.code == ApiErrorCode.noPermission &&
        error.message.contains(_maintenanceCopy)) {
      _update((data) => data.copyWith(maintenance: true));
    }
  }

  /// 置已读并刷新未读两个口径（R10 / KTD9）。
  ///
  /// 参数：无。
  /// 返回：[Future<void>]；失败静默（未读是增益信息）。
  Future<void> _markReadAndRefresh() async {
    try {
      await ref
          .read(messageRepositoryProvider)
          .markRead(conversationId: conversationId);
      unawaited(ref.read(unreadSummaryProvider.notifier).refresh());
      unawaited(ref.read(conversationsProvider.notifier).refresh());
    } catch (_) {
      // 页面已离开或服务端拒绝：不向 UI 报告，下次打开会再置一次
    }
  }

  /// 当前登录用户 ID（契约 `user_id` 为 int64，会话存储为字符串）。
  ///
  /// 参数：无。
  /// 返回：可解析时为对应用户 ID，未登录或格式异常时为 0（气泡退回对方侧）。
  int _myUserId() {
    final raw = ref.read(authSessionProvider)?.userId;
    return int.tryParse(raw ?? '') ?? 0;
  }

  /// 拉取申请卡状态，失败返回 null（不拖垮消息主链，R4）。
  ///
  /// 参数：无。
  /// 返回：[Future<ContactApplyStateDto?>]。
  Future<ContactApplyStateDto?> _fetchApplySafely() async {
    try {
      return await ref
          .read(messageRepositoryProvider)
          .fetchApplyState(conversationId: conversationId);
    } catch (_) {
      return null;
    }
  }

  /// 安全地更新快照（页面已释放时忽略）。
  ///
  /// 参数：[transform] 由旧快照产出新快照的函数。
  /// 返回：void。
  void _update(ConversationData Function(ConversationData) transform) {
    final current = state.asData?.value;
    if (current == null) return;
    try {
      state = AsyncValue.data(transform(current));
    } on StateError {
      // autoDispose 已释放：用户已离开会话，无需再改状态
    }
  }

  /// 合并两批消息并按 seq 去重排序。
  ///
  /// 参数：[left] 一批消息；[right] 另一批消息。
  /// 返回：按 `seq` 升序、`message_id` 去重后的新列表。
  List<ChatMessageDto> _mergeMessages(
    List<ChatMessageDto> left,
    List<ChatMessageDto> right,
  ) {
    final merged = <int, ChatMessageDto>{
      for (final message in left) message.messageId: message,
      for (final message in right) message.messageId: message,
    }.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
    return merged;
  }
}

/// 会话详情 Provider（离开页面自动释放）。
final conversationProvider =
    AsyncNotifierProvider.family<ConversationNotifier, ConversationData, int>(
      ConversationNotifier.new,
      isAutoDispose: true,
    );
