/// 会话详情页（计划 U13；R6 / R7 / R10 / R17 / R18 / R20–R22 / R26 / R28–R30 / R32）。
///
/// 结构：顶部（维护横幅）→ 消息区（日分组 + 气泡 / 申请卡 / 联系方式卡）→ 输入区。
/// 数据与状态全部来自 [conversationProvider]，本页只做渲染与用户动作的编排：
///   - 打开即置已读（R10），未读口径由 Provider 统一刷新（KTD14）；
///   - 已读回执只读服务端的对方水位，页面不维护计数器（R17）；
///   - 发送失败的行保留在消息区，点击脚注重发并沿用同一幂等键（R7）；
///   - 举报入口只针对会话对方，帖子取会话锚点（R29）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/list_states.dart';
import '../../design_tokens.dart';
import '../contact/report_reason.dart';
import 'conversation_provider.dart';
import 'message_dto.dart';
import 'widgets/apply_card.dart';
import 'widgets/composer.dart';
import 'widgets/contact_card.dart';
import 'widgets/message_bubble.dart';

/// 会话详情页。
class ConversationScreen extends ConsumerStatefulWidget {
  /// 构造会话详情页。
  ///
  /// 参数：[conversationId] 会话 ID；[peer] 列表行数据（头像昵称 / 帖子 ID），
  ///   深链或推送进入时可为空，此时仅缺少标题与取号跳转所需的帖子上下文。
  const ConversationScreen({
    super.key,
    required this.conversationId,
    this.peer,
  });

  /// 会话 ID。
  final int conversationId;

  /// 会话列表行（可空）。
  final ConversationDto? peer;

  @override
  ConsumerState<ConversationScreen> createState() => _ConversationScreenState();
}

/// 会话详情页状态。
class _ConversationScreenState extends ConsumerState<ConversationScreen> {
  /// 距顶部多少像素时请求更早历史。
  static const double _historyLoadThreshold = 80;

  final ScrollController _scroll = ScrollController();
  final TextEditingController _input = TextEditingController();

  /// 行内提示（敏感词拒发时展示，不暴露命中词）。
  String? _inlineError;

  /// 被拒原文（「误拦反馈」随举报一并提交）。
  String? _rejectedText;

  /// 审批/申请请求在途。
  bool _decisionBusy = false;

  /// 消息区末尾标识（用于判断「有新消息追加」而非「向前翻历史」）。
  String _tailKey = '';

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final conversations = ref.watch(
      conversationProvider(widget.conversationId),
    );

    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          peer?.peerNickname ?? '会话',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey<String>('conversation-menu'),
            onSelected: (value) {
              if (value == 'report') _showReportSheet();
            },
            itemBuilder: (context) => const [
              PopupMenuItem<String>(value: 'report', child: Text('举报对方')),
            ],
          ),
        ],
      ),
      body: conversations.when(
        loading: () => const Center(
          key: ValueKey<String>('conversation-loading'),
          child: CircularProgressIndicator(),
        ),
        error: (error, _) => ListErrorView(
          error: asApiException(error),
          onRetry: () => ref
              .read(conversationProvider(widget.conversationId).notifier)
              .refresh(),
        ),
        data: (data) => _buildBody(data),
      ),
    );
  }

  /// 组装页面主体（横幅 + 消息区 + 输入区）。
  ///
  /// 参数：[data] 会话快照。
  /// 返回：Widget。
  Widget _buildBody(ConversationData data) {
    return Column(
      children: [
        if (data.maintenance) const _MaintenanceBanner(),
        Expanded(child: _buildMessages(data)),
        Composer(
          controller: _input,
          disabled: data.isComposerDisabled,
          hintText: _composerHint(data),
          onSend: _submit,
          inlineError: _inlineError,
          onMisblockFeedback: _rejectedText == null ? null : _reportMisblock,
        ),
      ],
    );
  }

  /// 输入区占位/禁用提示。
  ///
  /// 参数：[data] 会话快照。
  /// 返回：三态之一对应的提示文案（R26 / R30）。
  String _composerHint(ConversationData data) {
    if (data.maintenance) return '消息功能维护中，暂不可发送';
    if (data.isUnrepliedLimitReached) return '等待对方回复后可继续发送';
    return '说点什么…';
  }

  /// 组装消息区（日分组 + 三类消息 + 本地未落库行）。
  ///
  /// 参数：[data] 会话快照。
  /// 返回：Widget。
  Widget _buildMessages(ConversationData data) {
    _syncTail(data);

    final entries = <Widget>[];
    DateTime? lastDay;
    ChatMessageDto? lastOutgoing;
    for (final message in data.messages) {
      if (message.senderId == data.myUserId && message.type == 'text') {
        lastOutgoing = message;
      }
    }
    final hasPending = data.pending.isNotEmpty;

    for (final message in data.messages) {
      final day = _dayStart(message.createdAt);
      if (lastDay != day) {
        entries.add(DayDivider(label: _dayLabel(message.createdAt)));
        lastDay = day;
      }
      switch (message.type) {
        case 'apply':
          entries.add(
            ApplyCard(
              apply: data.apply,
              busy: _decisionBusy,
              onApply: _applyContact,
              onApprove: () => _decideApply(true),
              onReject: () => _decideApply(false),
            ),
          );
        case 'contact':
          entries.add(
            ContactCard(onViewContact: _canOpenContact() ? _openContact : null),
          );
        default:
          entries.add(
            MessageBubble(
              key: ValueKey<String>('message-${message.messageId}'),
              content: message.content ?? '',
              mine: message.senderId == data.myUserId,
              footnote: _receiptFor(
                data: data,
                message: message,
                lastOutgoing: lastOutgoing,
                hasPending: hasPending,
              ),
            ),
          );
      }
    }

    if (data.pending.isNotEmpty) {
      final today = _dayStart(DateTime.now());
      if (lastDay != today) {
        entries.add(const DayDivider(label: '今天'));
      }
      for (final pending in data.pending) {
        final failed = pending.status == PendingMessageStatus.failed;
        entries.add(
          MessageBubble(
            key: ValueKey<String>('pending-${pending.localId}'),
            content: pending.content,
            mine: true,
            footnote: failed ? '发送失败（点击重发）' : '发送中',
            footnoteIsError: failed,
            onRetry: failed ? () => _retry(pending.localId) : null,
          ),
        );
      }
    }

    if (entries.isEmpty) {
      return Center(
        child: Text(
          '和对方打个招呼吧',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textPlaceholder),
          ),
        ),
      );
    }

    return ListView.builder(
      key: const ValueKey<String>('conversation-messages'),
      controller: _scroll,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      itemCount: entries.length,
      itemBuilder: (context, index) => entries[index],
    );
  }

  /// 计算某条消息的已读脚注（R17）。
  ///
  /// 参数：[data] 会话快照；[message] 当前消息；[lastOutgoing] 我方最后一条
  ///   已确认文本消息；[hasPending] 是否存在本地未落库行。
  /// 返回：`已读` / `未读` / null；最后一条仍在本地的消息不参与已读判定。
  String? _receiptFor({
    required ConversationData data,
    required ChatMessageDto message,
    required ChatMessageDto? lastOutgoing,
    required bool hasPending,
  }) {
    if (hasPending) return null;
    if (lastOutgoing == null || message.messageId != lastOutgoing.messageId) {
      return null;
    }
    return data.peerLastReadSeq >= message.seq ? '已读' : '未读';
  }

  /// 有新消息追加时滚动到底部（向前翻历史不动位置）。
  ///
  /// 参数：[data] 会话快照。
  /// 返回：void。
  void _syncTail(ConversationData data) {
    final tail = data.pending.isNotEmpty
        ? 'p${data.pending.last.localId}'
        : data.messages.isNotEmpty
        ? 'm${data.messages.last.messageId}'
        : '';
    if (tail == _tailKey) return;
    _tailKey = tail;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// 滚动到顶部附近时请求更早历史。
  ///
  /// 返回：void。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <= _historyLoadThreshold) {
      ref
          .read(conversationProvider(widget.conversationId).notifier)
          .loadHistory();
    }
  }

  /// 提交输入框内容。
  ///
  /// 参数：[raw] 输入框原文。
  /// 返回：[Future<void>]。
  Future<void> _submit(String raw) async {
    final feedback = await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .send(raw);
    if (!mounted) return;
    final error = feedback.error;
    if (error == null) {
      _input.clear();
      setState(() {
        _inlineError = null;
        _rejectedText = null;
      });
      return;
    }
    if (error.code == ApiErrorCode.sensitiveWord) {
      // R28：原文留在输入框，行内提示不展示命中词
      setState(() {
        _inlineError = error.message;
        _rejectedText = raw.trim();
      });
      return;
    }
    // 维护只读 / 未回复上限由 Provider 置位，输入区的禁用与横幅已接管提示
    if (!feedback.keepDraft) _input.clear();
    setState(() {
      _inlineError = null;
      _rejectedText = null;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.uiMessage)));
  }

  /// 点击失败脚注重发（沿用同一幂等键，R7）。
  ///
  /// 参数：[localId] 本地临时 ID。
  /// 返回：[Future<void>]。
  Future<void> _retry(String localId) async {
    final feedback = await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .retry(localId);
    if (!mounted) return;
    final error = feedback.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.uiMessage)));
    }
  }

  /// 提交或再次提交联系方式申请（R20 / R21）。
  ///
  /// 返回：[Future<void>]。
  Future<void> _applyContact() async {
    if (_decisionBusy) return;
    setState(() => _decisionBusy = true);
    final result = await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .applyContact();
    if (!mounted) return;
    setState(() => _decisionBusy = false);
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.uiMessage)));
    }
  }

  /// 发布者审批申请（R22）。
  ///
  /// 参数：[approved] true=同意，false=拒绝。
  /// 返回：[Future<void>]。
  Future<void> _decideApply(bool approved) async {
    if (_decisionBusy) return;
    setState(() => _decisionBusy = true);
    final result = await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .decideApply(approved);
    if (!mounted) return;
    setState(() => _decisionBusy = false);
    final error = result.error;
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.uiMessage)));
    }
  }

  /// 是否可以跳中转页取号（需要帖子上下文）。
  ///
  /// 返回：bool。
  bool _canOpenContact() {
    final peer = widget.peer;
    return peer != null && peer.postId > 0;
  }

  /// 跳中转页查看完整号码（R22：号码只由唯一出口返回）。
  ///
  /// 返回：void。
  void _openContact() {
    final peer = widget.peer;
    if (peer == null) return;
    context.push('/contact/${peer.postId}');
  }

  /// 打开举报原因面板（R29）。
  ///
  /// 返回：[Future<void>]。
  Future<void> _showReportSheet() async {
    final reason = await showModalBottomSheet<ReportReason>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Text(
                '举报对方',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.textPrimary),
                ),
              ),
            ),
            for (final item in ReportReason.values)
              ListTile(
                key: ValueKey<String>('report-${item.apiValue}'),
                title: Text(item.label),
                onTap: () => Navigator.of(sheetContext).pop(item),
              ),
            TextButton(
              onPressed: () => Navigator.of(sheetContext).pop(),
              child: const Text('取消'),
            ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    final error = await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .reportPeer(reason: reason.apiValue);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error == null ? '已提交，我们会尽快处理' : error.uiMessage)),
    );
  }

  /// 提交敏感词误拦反馈（R28）。
  ///
  /// 返回：[Future<void>]。
  Future<void> _reportMisblock() async {
    final text = _rejectedText ?? '';
    final error = await ref
        .read(conversationProvider(widget.conversationId).notifier)
        .reportMisblock(text);
    if (!mounted) return;
    if (error == null) {
      setState(() {
        _inlineError = null;
        _rejectedText = null;
      });
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error == null ? '已提交误拦反馈，我们会复核' : error.uiMessage),
      ),
    );
  }
}

/// 维护只读横幅（R30：不做静默下线）。
class _MaintenanceBanner extends StatelessWidget {
  /// 构造横幅。
  const _MaintenanceBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('conversation-maintenance-banner'),
      width: double.infinity,
      color: Color(AppColors.primaryLight),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.construction_outlined,
            size: 16,
            color: Color(AppColors.primaryDark),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '消息功能维护中，请稍后再试',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.primaryDark),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 取某时刻的「日」起点（本地时区），用于跨日分组。
///
/// 参数：[time] 任意时刻。
/// 返回：当天 00:00 的 [DateTime]。
DateTime _dayStart(DateTime time) {
  final local = time.toLocal();
  return DateTime(local.year, local.month, local.day);
}

/// 日分组文案（今天 / 昨天 / 更早，R6）。
///
/// 参数：[time] 消息时刻。
/// 返回：[String] 分组标题。
String _dayLabel(DateTime time) {
  final diff = _dayStart(DateTime.now()).difference(_dayStart(time)).inDays;
  if (diff <= 0) return '今天';
  if (diff == 1) return '昨天';
  return '更早';
}
