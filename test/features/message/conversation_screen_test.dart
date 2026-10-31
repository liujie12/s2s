/// 会话详情页测试（计划 U13）。
///
/// 覆盖 R6 正序与跨日分组、R17 已读回执、R7 失败重发与幂等键、R26 未回复上限、
/// R28 敏感词保留原文与误拦入口、R21a 申请卡倒计时、R22 联系方式卡与 R30 维护只读。
/// 数据层经 `messageRepositoryProvider` 注入假仓库，不走网络与本地存储。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/message/conversation_provider.dart';
import 'package:zhaoyazhao/features/message/conversation_screen.dart';
import 'package:zhaoyazhao/features/message/message_dto.dart';
import 'package:zhaoyazhao/features/message/message_repository.dart';

/// 当前用户 ID（与假仓库的消息 sender_id 口径一致）。
const int _me = 3;

/// 会话 ID。
const int _conversationId = 7;

/// 固定返回登录态的会话状态机。
class _FakeAuthSession extends AuthSessionNotifier {
  @override
  AuthSession? build() => AuthSession(
        userId: '$_me',
        phone: '13800000000',
        token: 'token',
        expireAt: DateTime.now().add(const Duration(days: 1)),
        isNewUser: false,
      );
}

/// 假 chat 仓库（只实现会话详情用到的读/写方法）。
class _FakeMessageRepository extends MessageRepository {
  /// 构造假仓库。
  ///
  /// 参数：[page] 消息页；[apply] 申请卡状态；[sendHandler] 发送处理（可抛异常）。
  _FakeMessageRepository({
    MessagePageDto? page,
    ContactApplyStateDto? apply,
    Future<MessageSendResultDto> Function(String content)? sendHandler,
  })  : _page = page ?? _defaultPage(),
        _apply = apply ?? _defaultApply(),
        _sendHandler = sendHandler,
        super(Dio());

  MessagePageDto _page;

  final ContactApplyStateDto _apply;

  final Future<MessageSendResultDto> Function(String content)? _sendHandler;

  /// 每次发送收到的幂等键（断言重发沿用同一个）。
  final List<String?> sentKeys = <String?>[];

  /// 置已读调用次数。
  int markReadCalls = 0;

  /// 设置新的消息页（用于增量拉取断言）。
  ///
  /// 参数：[page] 新消息页。
  /// 返回：void。
  void setPage(MessagePageDto page) {
    _page = page;
  }

  @override
  Future<MessagePageDto> fetchMessages({
    required int conversationId,
    int? beforeSeq,
    int? afterSeq,
    int pageSize = 30,
    String? interactionId,
  }) async {
    return _page;
  }

  @override
  Future<ContactApplyStateDto> fetchApplyState({
    required int conversationId,
    String? interactionId,
  }) async {
    return _apply;
  }

  @override
  Future<ConversationReadResultDto> markRead({
    required int conversationId,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    markReadCalls++;
    return const ConversationReadResultDto(lastReadSeq: 99);
  }

  @override
  Future<MessageSendResultDto> sendMessage({
    required int conversationId,
    required String content,
    String? interactionId,
    String? idempotencyKey,
  }) async {
    sentKeys.add(idempotencyKey);
    final handler = _sendHandler;
    if (handler == null) {
      return MessageSendResultDto(
        messageId: 900 + sentKeys.length,
        conversationId: conversationId,
        seq: 90 + sentKeys.length,
        createdAt: DateTime.now(),
      );
    }
    return handler(content);
  }

  @override
  Future<ConversationPageDto> fetchConversations({
    int page = 1,
    int pageSize = 20,
    String? interactionId,
  }) async {
    return const ConversationPageDto(
      items: <ConversationDto>[],
      total: 0,
      page: 1,
      pageSize: 20,
    );
  }

  @override
  Future<UnreadSummaryDto> fetchUnreadSummary({String? interactionId}) async {
    return UnreadSummaryDto.zero;
  }
}

/// 默认消息页：对方一条、我方一条，均已读。
///
/// 返回：[MessagePageDto]。
MessagePageDto _defaultPage() {
  return MessagePageDto(
    items: [
      _message(id: 1, seq: 1, senderId: 9, content: '你好，这条还在吗'),
      _message(id: 2, seq: 2, senderId: _me, content: '在的，随时可以看'),
    ],
    hasMore: false,
    peerLastReadSeq: 2,
  );
}

/// 默认申请卡状态（无需申请、非发布者）。
///
/// 返回：[ContactApplyStateDto]。
ContactApplyStateDto _defaultApply() {
  return const ContactApplyStateDto(
    conversationId: _conversationId,
    applyRequired: false,
    applyStatus: 'none',
    owner: false,
    canApply: false,
    canViewContact: true,
  );
}

/// 构造一条消息。
///
/// 参数：[id] 消息 ID；[seq] 会话内序号；[senderId] 发送者；[content] 正文；
///   [type] 消息类型；[at] 创建时刻（缺省为现在）。
/// 返回：[ChatMessageDto]。
ChatMessageDto _message({
  required int id,
  required int seq,
  required int senderId,
  String? content,
  String type = 'text',
  DateTime? at,
}) {
  return ChatMessageDto(
    messageId: id,
    seq: seq,
    senderId: senderId,
    type: type,
    createdAt: at ?? DateTime.now(),
    content: content,
  );
}

/// 构造会话列表行（提供标题与帖子 ID）。
///
/// 返回：[ConversationDto]。
ConversationDto _peer() {
  return const ConversationDto(
    conversationId: _conversationId,
    postId: 66,
    postGone: false,
    peerId: 9,
    peerNickname: '王师傅',
    unread: false,
    applyStatus: 'none',
  );
}

/// 挂载会话详情页并等待首屏加载。
///
/// 参数：[tester] 测试器；[repository] 假仓库；[peer] 会话行（可空）。
/// 返回：[Future<void>]。
Future<void> _pumpScreen(
  WidgetTester tester, {
  required _FakeMessageRepository repository,
  ConversationDto? peer,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        messageRepositoryProvider.overrideWithValue(repository),
        authSessionProvider.overrideWith(_FakeAuthSession.new),
        isLoggedInProvider.overrideWithValue(true),
      ],
      child: MaterialApp(
        home: ConversationScreen(
          conversationId: _conversationId,
          peer: peer ?? _peer(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 在输入框输入并点发送。
///
/// 参数：[tester] 测试器；[text] 输入内容。
/// 返回：[Future<void>]。
Future<void> _sendText(WidgetTester tester, String text) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('composer-field')),
    text,
  );
  // 发送键的可用态由 ValueListenableBuilder 监听控制器，需先走一帧才刷新
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey<String>('composer-send')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('消息按时间正序渲染，跨日出现今天/昨天分组', (tester) async {
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final repository = _FakeMessageRepository(
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '昨天说到哪了', at: yesterday),
          _message(id: 2, seq: 2, senderId: _me, content: '今天继续聊'),
        ],
        hasMore: false,
        peerLastReadSeq: 1,
      ),
    );

    await _pumpScreen(tester, repository: repository);

    expect(find.text('昨天'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('昨天说到哪了')).dy,
      lessThan(tester.getTopLeft(find.text('今天继续聊')).dy),
    );
  });

  testWidgets('最后一条我方消息在对方已读时显示已读，且没有开关入口', (tester) async {
    final repository = _FakeMessageRepository(
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '收到'),
          _message(id: 2, seq: 2, senderId: _me, content: '好的'),
        ],
        hasMore: false,
        peerLastReadSeq: 2,
      ),
    );
    await _pumpScreen(tester, repository: repository);

    expect(find.text('已读'), findsOneWidget);
    expect(find.text('未读'), findsNothing);
    expect(find.byType(Switch), findsNothing);
  });

  testWidgets('对方未读时最后一条我方消息显示未读', (tester) async {
    final repository = _FakeMessageRepository(
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '收到'),
          _message(id: 2, seq: 2, senderId: _me, content: '好的'),
        ],
        hasMore: false,
        peerLastReadSeq: 1,
      ),
    );
    await _pumpScreen(tester, repository: repository);

    expect(find.text('未读'), findsOneWidget);
  });

  testWidgets('已读状态单向推进：水位回退不把已读改回未读', (tester) async {
    final repository = _FakeMessageRepository(
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '收到'),
          _message(id: 2, seq: 2, senderId: _me, content: '好的'),
        ],
        hasMore: false,
        peerLastReadSeq: 1,
      ),
    );
    await _pumpScreen(tester, repository: repository);
    expect(find.text('未读'), findsOneWidget);

    repository.setPage(
      MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '收到'),
          _message(id: 2, seq: 2, senderId: _me, content: '好的'),
        ],
        hasMore: false,
        peerLastReadSeq: 2,
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(ConversationScreen)),
    );
    await container
        .read(conversationProvider(_conversationId).notifier)
        .refreshIncremental();
    await tester.pumpAndSettle();
    expect(find.text('已读'), findsOneWidget);

    repository.setPage(
      MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '收到'),
          _message(id: 2, seq: 2, senderId: _me, content: '好的'),
        ],
        hasMore: false,
        peerLastReadSeq: 0,
      ),
    );
    await container
        .read(conversationProvider(_conversationId).notifier)
        .refreshIncremental();
    await tester.pumpAndSettle();
    expect(find.text('已读'), findsOneWidget);
    expect(find.text('未读'), findsNothing);
  });

  testWidgets('发送失败保留本地行，重发沿用同一幂等键', (tester) async {
    var attempts = 0;
    final repository = _FakeMessageRepository(
      sendHandler: (content) async {
        attempts++;
        if (attempts == 1) {
          throw const ApiException(
            code: ApiErrorCode.networkFailure,
            message: '网络不可用',
          );
        }
        return MessageSendResultDto(
          messageId: 99,
          conversationId: _conversationId,
          seq: 9,
          createdAt: DateTime.now(),
        );
      },
    );
    await _pumpScreen(tester, repository: repository);

    await _sendText(tester, '这条会失败吗');
    expect(find.text('发送失败（点击重发）'), findsOneWidget);

    await tester.tap(find.text('发送失败（点击重发）'));
    await tester.pumpAndSettle();

    expect(repository.sentKeys.length, 2);
    expect(repository.sentKeys.first, repository.sentKeys.last);
    expect(find.text('发送失败（点击重发）'), findsNothing);
    expect(find.text('这条会失败吗'), findsOneWidget);
  });

  testWidgets('未回复达上限时输入区禁用并提示等待回复', (tester) async {
    final repository = _FakeMessageRepository(
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, content: '在吗'),
          _message(id: 2, seq: 2, senderId: _me, content: '一'),
          _message(id: 3, seq: 3, senderId: _me, content: '二'),
          _message(id: 4, seq: 4, senderId: _me, content: '三'),
        ],
        hasMore: false,
        peerLastReadSeq: 1,
      ),
    );
    await _pumpScreen(tester, repository: repository);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('composer-field')),
    );
    expect(field.enabled, isFalse);
    expect(find.text('等待对方回复后可继续发送'), findsOneWidget);
  });

  testWidgets('敏感词拒发保留原文并给误拦反馈入口，不暴露命中词', (tester) async {
    final repository = _FakeMessageRepository(
      sendHandler: (content) async {
        throw const ApiException(
          code: ApiErrorCode.sensitiveWord,
          message: '消息包含敏感内容，请修改后再发送',
        );
      },
    );
    await _pumpScreen(tester, repository: repository);

    await _sendText(tester, '帮你代开正规发票');

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('composer-field')),
    );
    expect(field.controller?.text, '帮你代开正规发票');
    expect(
      find.byKey(const ValueKey<String>('composer-inline-error')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('composer-misblock')), findsOneWidget);
    expect(find.text('消息包含敏感内容，请修改后再发送'), findsOneWidget);
  });

  testWidgets('申请卡被拒后显示剩余天数，倒计时内入口置灰', (tester) async {
    final repository = _FakeMessageRepository(
      apply: ContactApplyStateDto(
        conversationId: _conversationId,
        applyRequired: true,
        applyStatus: 'rejected',
        owner: false,
        canApply: false,
        canViewContact: false,
        reapplyAt: DateTime.now().add(const Duration(hours: 50)),
      ),
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: _me, type: 'apply'),
        ],
        hasMore: false,
        peerLastReadSeq: 0,
      ),
    );
    await _pumpScreen(tester, repository: repository);

    expect(find.byKey(const ValueKey<String>('apply-card')), findsOneWidget);
    expect(find.textContaining('剩余 3 天'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey<String>('apply-reapply')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('联系方式卡只呈现取号入口，卡上不出现号码', (tester) async {
    final repository = _FakeMessageRepository(
      page: MessagePageDto(
        items: [
          _message(id: 1, seq: 1, senderId: 9, type: 'contact'),
        ],
        hasMore: false,
        peerLastReadSeq: 0,
      ),
    );
    await _pumpScreen(tester, repository: repository);

    expect(find.byKey(const ValueKey<String>('contact-card')), findsOneWidget);
    expect(find.text('查看完整号码'), findsOneWidget);
    expect(find.textContaining('138'), findsNothing);
  });

  testWidgets('维护只读时出现横幅并禁用输入区', (tester) async {
    final repository = _FakeMessageRepository(
      sendHandler: (content) async {
        throw const ApiException(
          code: ApiErrorCode.noPermission,
          message: '消息功能维护中，请稍后再试',
        );
      },
    );
    await _pumpScreen(tester, repository: repository);

    await _sendText(tester, '维护期间能发吗');

    expect(
      find.byKey(const ValueKey<String>('conversation-maintenance-banner')),
      findsOneWidget,
    );
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('composer-field')),
    );
    expect(field.enabled, isFalse);
  });
}
