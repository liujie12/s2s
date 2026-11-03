/// 消息列表页测试（计划 U12）。
///
/// 覆盖 R33 三态、R12 服务号置顶、R9 角标 99+、R4 下架标注与 R16 权限提示条。
/// 数据层与权限态全部经 Provider override 注入，不走网络与真实本地存储。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/message/message_dto.dart';
import 'package:zhaoyazhao/features/message/message_list_provider.dart';
import 'package:zhaoyazhao/features/message/message_list_screen.dart';
import 'package:zhaoyazhao/features/message/message_permission.dart';

/// 固定快照的会话列表状态机。
class _FakeConversations extends ConversationsNotifier {
  _FakeConversations(this.value);

  /// 固定返回的状态。
  final AsyncValue<ConversationsData> value;

  /// refresh 调用次数。
  int refreshCalls = 0;

  /// 删除调用次数（V33 左滑删除）。
  int deleteCalls = 0;

  @override
  AsyncValue<ConversationsData> build() => value;

  @override
  Future<void> refresh() async {
    refreshCalls++;
  }

  @override
  Future<void> deleteConversation(int conversationId) async {
    deleteCalls++;
    final current = state.asData?.value;
    if (current == null) return;
    state = AsyncValue.data(
      ConversationsData(
        items: current.items
            .where((item) => item.conversationId != conversationId)
            .toList(growable: false),
        total: current.total > 0 ? current.total - 1 : 0,
        page: current.page,
      ),
    );
  }

  @override
  Future<void> loadMore() async {}
}

/// 固定快照的未读汇总状态机。
class _FakeUnread extends UnreadSummaryNotifier {
  _FakeUnread(this.value);

  /// 固定返回的状态。
  final AsyncValue<UnreadSummaryDto> value;

  @override
  AsyncValue<UnreadSummaryDto> build() => value;

  @override
  Future<void> refresh() async {}
}

/// 固定快照的权限引导状态机。
class _FakePermission extends MessageNotifyPermissionNotifier {
  _FakePermission(this.value);

  /// 固定返回的状态。
  final MessageNotifyPermissionState value;

  /// dismissBanner 调用次数。
  int dismissCalls = 0;

  @override
  MessageNotifyPermissionState build() => value;

  @override
  Future<void> markExplainerSeen() async {}

  @override
  Future<void> markDenied() async {}

  @override
  Future<void> dismissBanner() async {
    dismissCalls++;
  }
}

/// 构造一条会话行。
///
/// 参数：[id] 会话 ID；[nickname] 对方昵称；[unread] 是否有未读；
///   [gone] 帖子是否下架；[thumbnailUrl] 帖子首图。
/// 返回：[ConversationDto]。
ConversationDto _conversation({
  required int id,
  required String nickname,
  bool unread = false,
  bool gone = false,
  String? thumbnailUrl,
}) {
  return ConversationDto(
    conversationId: id,
    postId: 100 + id,
    postGone: gone,
    peerId: 200 + id,
    peerNickname: nickname,
    unread: unread,
    applyStatus: 'none',
    postTitle: '$nickname 的帖子',
    postThumbnailUrl: thumbnailUrl,
    lastMessageType: 'text',
    lastMessagePreview: '最后一条消息',
    lastMessageAt: DateTime.now(),
  );
}

/// 挂载消息列表页。
///
/// 参数：[conversations] 会话状态；[notificationUnread] 通知未读；
///   [permission] 权限引导态。
/// 返回：注入的会话状态机（用于断言 refresh 调用）。
Future<_FakeConversations> _pumpScreen(
  WidgetTester tester, {
  required AsyncValue<ConversationsData> conversations,
  int notificationUnread = 0,
  MessageNotifyPermissionState permission =
      MessageNotifyPermissionState.initial,
}) async {
  final fakeConversations = _FakeConversations(conversations);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        conversationsProvider.overrideWith(() => fakeConversations),
        unreadSummaryProvider.overrideWith(
          () => _FakeUnread(
            AsyncValue.data(
              UnreadSummaryDto(
                total: notificationUnread,
                conversationUnread: 0,
                notificationUnread: notificationUnread,
              ),
            ),
          ),
        ),
        messageNotifyPermissionProvider.overrideWith(
          () => _FakePermission(permission),
        ),
      ],
      child: const MaterialApp(home: MessageListScreen()),
    ),
  );
  await tester.pump();
  return fakeConversations;
}

void main() {
  testWidgets('无会话时显示空态，不渲染服务号行', (tester) async {
    await _pumpScreen(
      tester,
      conversations: const AsyncValue.data(ConversationsData.empty),
    );

    expect(find.text('还没有会话'), findsOneWidget);
    expect(find.text('服务号'), findsNothing);
  });

  testWidgets('首屏加载显示骨架', (tester) async {
    await _pumpScreen(tester, conversations: const AsyncValue.loading());

    expect(
      find.byKey(const ValueKey<String>('message-list-skeleton')),
      findsOneWidget,
    );
  });

  testWidgets('失败显示重试，点击触发 refresh', (tester) async {
    final fake = await _pumpScreen(
      tester,
      conversations: AsyncValue.error(
        const ApiException(
          code: ApiErrorCode.networkFailure,
          message: '网络异常，请稍后重试',
        ),
        StackTrace.empty,
      ),
    );

    expect(find.text('网络异常，请稍后重试'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pump();

    expect(fake.refreshCalls, 1);
  });

  testWidgets('服务号固定首位、通知未读 99+、下架帖标注「已下架」', (tester) async {
    await _pumpScreen(
      tester,
      notificationUnread: 120,
      conversations: AsyncValue.data(
        ConversationsData(
          items: [
            _conversation(id: 1, nickname: '王师傅', unread: true),
            _conversation(id: 2, nickname: '陈先生', gone: true),
          ],
          total: 2,
          page: 1,
        ),
      ),
    );

    expect(find.text('99+ 条未读通知'), findsOneWidget);
    expect(find.text('服务号'), findsOneWidget);
    expect(find.text('王师傅'), findsOneWidget);
    expect(find.text('已\n下架'), findsOneWidget);
    // 服务号在会话行之上（首位固定）。
    expect(
      tester.getTopLeft(find.text('服务号')).dy,
      lessThan(tester.getTopLeft(find.text('王师傅')).dy),
    );
  });

  testWidgets('会话行左滑删除：二次确认后移除，服务号行不可删', (tester) async {
    final fake = await _pumpScreen(
      tester,
      conversations: AsyncValue.data(
        ConversationsData(
          items: [_conversation(id: 1, nickname: '王师傅')],
          total: 1,
          page: 1,
        ),
      ),
    );

    // 只有会话行包了 Dismissible，服务号置顶行不可滑动删除（R12 / V33）
    expect(find.byType(Dismissible), findsOneWidget);

    await tester.drag(find.text('王师傅'), const Offset(-500, 0));
    await tester.pumpAndSettle();
    expect(find.text('删除会话'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(fake.deleteCalls, 1);
    expect(find.text('王师傅'), findsNothing);
  });

  testWidgets('权限被拒后顶部提示常驻，可关闭', (tester) async {
    final fakePermission = _FakePermission(
      const MessageNotifyPermissionState(
        explainerSeen: true,
        denied: true,
        bannerDismissed: false,
        loaded: true,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          conversationsProvider.overrideWith(
            () => _FakeConversations(
              const AsyncValue.data(ConversationsData.empty),
            ),
          ),
          unreadSummaryProvider.overrideWith(
            () => _FakeUnread(const AsyncValue.data(UnreadSummaryDto.zero)),
          ),
          messageNotifyPermissionProvider.overrideWith(() => fakePermission),
        ],
        child: const MaterialApp(home: MessageListScreen()),
      ),
    );
    await tester.pump();

    expect(find.text('通知未开启，可能收不到新消息提醒'), findsOneWidget);
    expect(find.byTooltip('关闭提示'), findsOneWidget);

    await tester.tap(find.byTooltip('关闭提示'));
    await tester.pump();
    expect(fakePermission.dismissCalls, 1);
  });
}
