/// 个人中心登录态测试（2026-11-02 真机缺陷回归）。
///
/// 缺陷现象：退出登录后再次进入「我的」，仍显示上一个账号的昵称/角标/退出登录。
/// 根因：本页不读登录态，且资料与角标 Provider 不随会话变化失效。
/// 本文件覆盖三件事：未登录形态、登录后形态、登出/换号后不残留上一个账号数据。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/favorite/favorite_dto.dart';
import 'package:zhaoyazhao/features/favorite/favorite_repository.dart';
import 'package:zhaoyazhao/features/notify/notification_dto.dart';
import 'package:zhaoyazhao/features/notify/notification_repository.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';
import 'package:zhaoyazhao/features/profile/profile_dto.dart';
import 'package:zhaoyazhao/features/profile/profile_repository.dart';
import 'package:zhaoyazhao/features/profile/profile_screen.dart';

/// 可变会话 Notifier：不触登录流程与安全存储，直接置/切会话。
class _StubSessionNotifier extends AuthSessionNotifier {
  /// 构造可变会话 Notifier。
  ///
  /// 参数：[session] 初始会话（null = 未登录）。
  _StubSessionNotifier(this._session);

  AuthSession? _session;

  @override
  AuthSession? build() => _session;

  /// 切换会话（模拟登录/登出/换号）。
  ///
  /// 参数：[session] 新会话，null 表示登出。
  /// 返回：void。
  void switchTo(AuthSession? session) {
    _session = session;
    state = session;
  }
}

/// 内存假 profile 仓库：只回固定资料，记录调用次数。
class _FakeProfileRepository extends ProfileRepository {
  /// 构造假仓库。
  ///
  /// 参数：[profile] 待返回的本人资料。
  _FakeProfileRepository(this.profile) : super(Dio());

  /// 当前待返回资料（换号用例会替换）。
  MyProfileDto profile;

  /// fetchMyProfile 调用次数。
  int calls = 0;

  @override
  Future<MyProfileDto> fetchMyProfile({String? interactionId}) async {
    calls++;
    return profile;
  }
}

/// 内存假 post 仓库：只回「我的发布」总数。
class _FakePostRepository extends PostRepository {
  /// 构造假仓库。
  _FakePostRepository() : super(Dio());

  @override
  Future<MyPostsPageDto> fetchMine({
    int page = 1,
    int pageSize = 10,
    String? status,
    String? interactionId,
  }) async => const MyPostsPageDto(items: [], total: 3, page: 1, pageSize: 1);
}

/// 内存假收藏仓库：只回收藏总数。
class _FakeFavoriteRepository extends FavoriteRepository {
  /// 构造假仓库。
  _FakeFavoriteRepository() : super(Dio());

  @override
  Future<FavoritesPageDto> fetchFavorites({
    String type = 'all',
    int page = 1,
    int pageSize = 10,
    String? interactionId,
  }) async => const FavoritesPageDto(items: [], total: 2, page: 1, pageSize: 1);
}

/// 内存假通知仓库：只回未读数。
class _FakeNotificationRepository extends NotificationRepository {
  /// 构造假仓库。
  _FakeNotificationRepository() : super(Dio());

  @override
  Future<NotificationsPageDto> fetchNotifications({
    String? type,
    int page = 1,
    int pageSize = 10,
    String? interactionId,
  }) async => const NotificationsPageDto(
    items: [],
    total: 0,
    page: 1,
    pageSize: 1,
    unreadCount: 0,
  );
}

/// 构造最小合法会话。
///
/// 参数：[userId] 用户 ID（会话键）。
/// 返回：[AuthSession]。
AuthSession _session(String userId) => AuthSession(
  userId: userId,
  phone: '13800008000',
  token: 'jwt-profile-test',
  expireAt: DateTime(2099),
  isNewUser: false,
);

/// 构造本人资料。
///
/// 参数：[nickname] 昵称；[phoneMask] 脱敏手机号。
/// 返回：[MyProfileDto]。
MyProfileDto _profile(String nickname, {String phoneMask = '186****0845'}) =>
    MyProfileDto.fromJson({
      'id': 1,
      'nickname': nickname,
      'realname_status': 'passed',
      'phone_mask': phoneMask,
    });

/// 泵入个人中心页。
///
/// 参数：
///   [tester] 测试句柄；[sessionNotifier] 可变会话；
///   [profileRepository] 假资料仓库。
/// 返回：[Future<void>]。
Future<void> _pumpProfile(
  WidgetTester tester, {
  required _StubSessionNotifier sessionNotifier,
  required _FakeProfileRepository profileRepository,
}) async {
  final router = GoRouter(
    initialLocation: '/profile',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfileScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const Scaffold(body: Text('login')),
      ),
      GoRoute(
        path: '/profile/edit',
        builder: (context, state) => const Scaffold(body: Text('edit')),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authSessionProvider.overrideWith(() => sessionNotifier),
        profileRepositoryProvider.overrideWithValue(profileRepository),
        postRepositoryProvider.overrideWithValue(_FakePostRepository()),
        favoriteRepositoryProvider.overrideWithValue(_FakeFavoriteRepository()),
        notificationRepositoryProvider.overrideWithValue(
          _FakeNotificationRepository(),
        ),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('未登录：显示未登录与登录入口，不渲染条目、不请求资料', (tester) async {
    final repository = _FakeProfileRepository(_profile('用户0845'));
    await _pumpProfile(
      tester,
      sessionNotifier: _StubSessionNotifier(null),
      profileRepository: repository,
    );

    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('登录 / 注册'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
    expect(find.text('我的发布'), findsNothing);
    expect(repository.calls, 0);
  });

  testWidgets('登录成功：显示昵称、脱敏号、角标与退出登录', (tester) async {
    await _pumpProfile(
      tester,
      sessionNotifier: _StubSessionNotifier(_session('u-1')),
      profileRepository: _FakeProfileRepository(_profile('用户0845')),
    );

    expect(find.text('用户0845 186****0845'), findsOneWidget);
    expect(find.text('3 在架'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('0 未读'), findsOneWidget);
    expect(find.text('退出登录'), findsOneWidget);
    expect(find.text('未登录'), findsNothing);
  });

  testWidgets('点击头部卡进入编辑资料页', (tester) async {
    await _pumpProfile(
      tester,
      sessionNotifier: _StubSessionNotifier(_session('u-1')),
      profileRepository: _FakeProfileRepository(_profile('用户0845')),
    );

    await tester.tap(find.text('用户0845 186****0845'));
    await tester.pumpAndSettle();

    expect(find.text('edit'), findsOneWidget);
  });

  testWidgets('退出登录后回到未登录形态，且换号登录不残留上一个账号资料', (tester) async {
    final repository = _FakeProfileRepository(_profile('用户0845'));
    final sessionNotifier = _StubSessionNotifier(_session('u-1'));
    await _pumpProfile(
      tester,
      sessionNotifier: sessionNotifier,
      profileRepository: repository,
    );
    expect(find.text('用户0845 186****0845'), findsOneWidget);

    // 模拟退出登录：会话置空后本页必须立刻回到未登录形态，旧资料不得残留。
    sessionNotifier.switchTo(null);
    await tester.pumpAndSettle();
    expect(find.text('未登录'), findsOneWidget);
    expect(find.text('用户0845 186****0845'), findsNothing);
    expect(find.text('退出登录'), findsNothing);

    // 换另一个账号登录：必须重新拉取并展示新账号资料。
    repository.profile = _profile('用户9999', phoneMask: '139****9999');
    sessionNotifier.switchTo(_session('u-2'));
    await tester.pumpAndSettle();
    expect(find.text('用户9999 139****9999'), findsOneWidget);
    expect(find.text('用户0845 186****0845'), findsNothing);
  });
}
