/// 通知中心交互回归（2026-11-03 真机缺陷）。
///
/// 缺陷现象：①点击系统通知没有任何反应；②点「全部已读」后底部「消息」Tab 与
/// 「我的 › 通知中心」的未读角标不消失。
/// 根因：行点击只处理 `target.kind=post`，既未写已读也无反馈；已读后只重拉了
/// 通知列表，没有刷新 [unreadSummaryProvider] 与「我的」页角标。
/// 本文件覆盖：单条已读、全部已读、认证类通知跳「信任与认证」。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/favorite/favorite_dto.dart';
import 'package:zhaoyazhao/features/favorite/favorite_repository.dart';
import 'package:zhaoyazhao/features/message/message_dto.dart';
import 'package:zhaoyazhao/features/message/message_repository.dart';
import 'package:zhaoyazhao/features/notify/notification_dto.dart';
import 'package:zhaoyazhao/features/notify/notification_repository.dart';
import 'package:zhaoyazhao/features/notify/notification_screen.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';

/// 固定登录态（本页所有请求都要求登录）。
class _SignedInNotifier extends AuthSessionNotifier {
  @override
  AuthSession? build() => AuthSession(
        userId: 'u-1',
        phone: '13800008000',
        token: 'jwt-notify-test',
        expireAt: DateTime(2099),
        isNewUser: false,
      );
}

/// 内存假通知仓库：持有可变通知表，记录 markRead 的入参。
class _FakeNotificationRepository extends NotificationRepository {
  /// 构造假仓库。
  ///
  /// 参数：[items] 初始通知行（可变 map，模拟服务端 `read_at` 落库）。
  _FakeNotificationRepository(this.items) : super(Dio());

  /// 通知行（`is_read` 会被 markRead 改写）。
  final List<Map<String, Object?>> items;

  /// 每次 markRead 的 ids 入参（空列表＝全部已读）。
  final List<List<int>> markCalls = [];

  @override
  Future<NotificationsPageDto> fetchNotifications({
    String? type,
    int page = 1,
    int pageSize = 10,
    String? interactionId,
  }) async {
    return NotificationsPageDto.fromJson({
      'items': items,
      'total': items.length,
      'page': page,
      'page_size': pageSize,
      'unread_count': items.where((row) => row['is_read'] != true).length,
    });
  }

  @override
  Future<int> markRead({List<int>? ids, String? interactionId}) async {
    markCalls.add(ids ?? const <int>[]);
    final all = ids == null || ids.isEmpty;
    final targets = ids ?? const <int>[];
    var updated = 0;
    for (final row in items) {
      if ((all || targets.contains(row['id'])) && row['is_read'] != true) {
        row['is_read'] = true;
        updated++;
      }
    }
    return updated;
  }
}

/// 内存假消息仓库：只用于 [unreadSummaryProvider] 重拉计数。
class _FakeMessageRepository extends MessageRepository {
  /// 构造假仓库。
  _FakeMessageRepository() : super(Dio());

  /// fetchUnreadSummary 调用次数（>1 说明已读后确实同步了角标）。
  int summaryCalls = 0;

  @override
  Future<UnreadSummaryDto> fetchUnreadSummary({String? interactionId}) async {
    summaryCalls++;
    return const UnreadSummaryDto(
      total: 0,
      conversationUnread: 0,
      notificationUnread: 0,
    );
  }
}

/// 内存假 post 仓库（「我的」页角标聚合用）。
class _FakePostRepository extends PostRepository {
  /// 构造假仓库。
  _FakePostRepository() : super(Dio());

  @override
  Future<MyPostsPageDto> fetchMine({
    int page = 1,
    int pageSize = 10,
    String? status,
    String? interactionId,
  }) async => const MyPostsPageDto(items: [], total: 0, page: 1, pageSize: 1);
}

/// 内存假收藏仓库（「我的」页角标聚合用）。
class _FakeFavoriteRepository extends FavoriteRepository {
  /// 构造假仓库。
  _FakeFavoriteRepository() : super(Dio());

  @override
  Future<FavoritesPageDto> fetchFavorites({
    String type = 'all',
    int page = 1,
    int pageSize = 10,
    String? interactionId,
  }) async => const FavoritesPageDto(items: [], total: 0, page: 1, pageSize: 1);
}

/// 构造一条通知行。
///
/// 参数：[id] 通知 ID；[type] 类型线值；[title] 标题；[isRead] 初始已读态；
///   [target] 契约 `target` 对象（null 表示无）。
/// 返回：`GET /notifications` 的 items 元素。
Map<String, Object?> _notification(
  int id, {
  String type = 'system',
  String title = '资质认证已通过',
  bool isRead = false,
  Map<String, Object?>? target,
}) =>
    {
      'id': id,
      'type': type,
      'title': title,
      'content': '你的资质认证已通过，可在信任与认证中查看',
      'is_read': isRead,
      'created_at': DateTime(2026, 11, 3).toIso8601String(),
      'target': target ?? {'kind': 'none'},
    };

/// 泵入通知中心页（含跳转目标空页）。
///
/// 参数：[tester] 测试句柄；[notificationRepository] 假通知仓库；
///   [messageRepository] 假消息仓库。
/// 返回：[Future<void>]。
Future<void> _pumpNotification(
  WidgetTester tester, {
  required _FakeNotificationRepository notificationRepository,
  required _FakeMessageRepository messageRepository,
}) async {
  final router = GoRouter(
    initialLocation: '/notifications',
    routes: [
      GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationScreen(),
      ),
      GoRoute(
        path: '/trust',
        builder: (context, state) => const Scaffold(body: Text('trust-page')),
      ),
      GoRoute(
        path: '/detail/:id',
        builder: (context, state) =>
            Scaffold(body: Text('detail-${state.pathParameters['id']}')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authSessionProvider.overrideWith(_SignedInNotifier.new),
        notificationRepositoryProvider.overrideWithValue(
          notificationRepository,
        ),
        messageRepositoryProvider.overrideWithValue(messageRepository),
        postRepositoryProvider.overrideWithValue(_FakePostRepository()),
        favoriteRepositoryProvider.overrideWithValue(_FakeFavoriteRepository()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('点击系统通知：写入已读、红点消失、未读角标同步重拉', (tester) async {
    final notifications = _FakeNotificationRepository([_notification(1)]);
    final messages = _FakeMessageRepository();
    await _pumpNotification(
      tester,
      notificationRepository: notifications,
      messageRepository: messages,
    );
    expect(find.byKey(const ValueKey('unread-dot-1')), findsOneWidget);

    await tester.tap(find.text('资质认证已通过'));
    await tester.pumpAndSettle();

    expect(notifications.markCalls, [
      [1],
    ]);
    expect(find.byKey(const ValueKey('unread-dot-1')), findsNothing);
    // 角标真源被重拉（build 时一次 + 已读后一次）。
    expect(messages.summaryCalls, greaterThanOrEqualTo(2));
    // 系统通知无跳转目标：不应离开本页。
    expect(find.text('trust-page'), findsNothing);
  });

  testWidgets('全部已读：服务端收到空 ids（全部）、红点消失', (tester) async {
    final notifications = _FakeNotificationRepository([
      _notification(1),
      _notification(2, title: '实名认证已通过'),
    ]);
    final messages = _FakeMessageRepository();
    await _pumpNotification(
      tester,
      notificationRepository: notifications,
      messageRepository: messages,
    );
    expect(find.byKey(const ValueKey('unread-dot-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('unread-dot-2')), findsOneWidget);

    await tester.tap(find.text('全部已读'));
    await tester.pumpAndSettle();

    expect(notifications.markCalls, [<int>[]]);
    expect(find.byKey(const ValueKey('unread-dot-1')), findsNothing);
    expect(find.byKey(const ValueKey('unread-dot-2')), findsNothing);
    expect(messages.summaryCalls, greaterThanOrEqualTo(2));
  });

  testWidgets('认证类通知：点击标记已读后跳「信任与认证」', (tester) async {
    final notifications = _FakeNotificationRepository([
      _notification(
        3,
        type: 'cert',
        title: '认证审核已通过',
        target: {'kind': 'cert'},
      ),
    ]);
    await _pumpNotification(
      tester,
      notificationRepository: notifications,
      messageRepository: _FakeMessageRepository(),
    );

    await tester.tap(find.text('认证审核已通过'));
    await tester.pumpAndSettle();

    expect(notifications.markCalls, [
      [3],
    ]);
    expect(find.text('trust-page'), findsOneWidget);
  });
}
