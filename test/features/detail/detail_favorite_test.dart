/// 详情页收藏交互测试（U6；R1–R5 / R12）。
///
/// 覆盖：三态渲染、乐观写 + 再点复原、失败回滚、41001 两类入口、登录后补收藏、
/// 浏览上报只发一次。网络层用假仓库，不触真实 dio。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/detail/detail_screen.dart';
import 'package:zhaoyazhao/features/favorite/favorite_dto.dart';
import 'package:zhaoyazhao/features/favorite/favorite_repository.dart';
import 'package:zhaoyazhao/features/post/post_dto.dart';
import 'package:zhaoyazhao/features/post/post_repository.dart';

import '../../support/post_fixtures.dart';

/// 内存假收藏仓库：只记录调用与成败，不发网络请求。
class _FakeFavoriteRepository extends FavoriteRepository {
  _FakeFavoriteRepository() : super(Dio());

  /// addFavorite 调用次数。
  int addCalls = 0;

  /// removeFavorite 调用次数。
  int removeCalls = 0;

  /// 置 true 时请求抛网络异常（验证回滚）。
  bool fail = false;

  @override
  Future<FavoriteResultDto> addFavorite(int postId, {String? interactionId}) async {
    addCalls++;
    if (fail) {
      throw const ApiException(
        code: ApiErrorCode.networkFailure,
        message: '网络异常',
      );
    }
    return const FavoriteResultDto(favorited: true);
  }

  @override
  Future<FavoriteResultDto> removeFavorite(int postId, {String? interactionId}) async {
    removeCalls++;
    if (fail) {
      throw const ApiException(
        code: ApiErrorCode.networkFailure,
        message: '网络异常',
      );
    }
    return const FavoriteResultDto(favorited: false);
  }
}

/// 假 post 仓库：详情按用例给数据或异常，浏览上报只计数。
class _FakePostRepository extends PostRepository {
  _FakePostRepository({this.detail, this.detailError}) : super(Dio());

  /// 详情成功响应；[detailError] 为 null 时使用。
  final PostDetailDto? detail;

  /// 详情异常（41001 / 40301 等）。
  final Object? detailError;

  /// 浏览上报调用次数（R12：详情渲染成功只发一次）。
  int reportCalls = 0;

  @override
  Future<PostDetailDto> fetchDetail(int postId, {String? interactionId}) async {
    if (detailError != null) throw detailError!;
    return detail!;
  }

  @override
  Future<void> reportView(int postId, {String? interactionId}) async {
    reportCalls++;
  }
}

/// 固定会话 Notifier（不触登录流程与安全存储）。
class _StubSessionNotifier extends AuthSessionNotifier {
  _StubSessionNotifier(this._session);

  AuthSession? _session;

  @override
  AuthSession? build() => _session;

  /// 切换会话（模拟登录成功）。
  ///
  /// 参数：[session] 新会话。
  /// 返回：void。
  void switchTo(AuthSession session) {
    _session = session;
    state = session;
  }
}

/// 构造最小合法会话。
///
/// 参数：[userId] 用户 ID。
/// 返回：[AuthSession]。
AuthSession _session(String userId) => AuthSession(
      userId: userId,
      phone: '13800008000',
      token: 'jwt-detail-test',
      expireAt: DateTime(2099),
      isNewUser: false,
    );

/// 构造详情 DTO。
///
/// 参数：[favorited] 服务端收藏态（null = 游客视角不返回）。
/// 返回：[PostDetailDto]。
PostDetailDto _detailDto({bool? favorited}) {
  final payload = postDetailPayload();
  if (favorited != null) payload['favorited'] = favorited;
  return PostDetailDto.fromJson(payload);
}

/// 泵入详情页并返回假 post 仓库。
///
/// 参数：[favoriteRepository] 假收藏仓库；[session] 初始会话；
///   [detail] 详情数据；[detailError] 详情异常；[args] 入口参数；
///   [router] 非 null 时用 `MaterialApp.router`（登录重放用例）；
///   [accessibleNavigation] true 时注入无障碍导航语义（验证不产生底部浮条）。
/// 返回：[_FakePostRepository]。
Future<_FakePostRepository> _pumpDetail(
  WidgetTester tester, {
  required _FakeFavoriteRepository favoriteRepository,
  AuthSession? session,
  PostDetailDto? detail,
  Object? detailError,
  DetailScreenArgs args = const DetailScreenArgs(),
  GoRouter? router,
  _StubSessionNotifier? sessionNotifier,
  bool accessibleNavigation = false,
}) async {
  final postRepository = _FakePostRepository(
    detail: detail,
    detailError: detailError,
  );
  // 只建一次：登录重放用例要跨「登录后」继续观察同一实例的状态。
  final authNotifier = sessionNotifier ?? _StubSessionNotifier(session);
  // accessibleNavigation 必须在 MaterialApp 内部注入：WidgetsApp 会用
  // fromView 覆盖外层的 MediaQuery，包在 MaterialApp 外面不生效。
  Widget wrapMediaQuery(Widget child) => accessibleNavigation
      ? Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(accessibleNavigation: true),
            child: child,
          ),
        )
      : child;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authSessionProvider.overrideWith(() => authNotifier),
        favoriteRepositoryProvider.overrideWithValue(favoriteRepository),
        postRepositoryProvider.overrideWithValue(postRepository),
      ],
      child: router != null
          ? MaterialApp.router(routerConfig: router)
          : MaterialApp(
              builder: (context, child) => wrapMediaQuery(child!),
              home: DetailScreen(listingId: 1001, args: args),
            ),
    ),
  );
  await tester.pumpAndSettle();
  return postRepository;
}

/// 等页面稳定（无 SnackBar 残留定时器，收藏成功不再弹浮条）。
///
/// 参数：[tester] 测试器。
/// 返回：[Future<void>]。
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('已登录未收藏：空心星 +「收藏」', (tester) async {
    await _pumpDetail(
      tester,
      favoriteRepository: _FakeFavoriteRepository(),
      session: _session('u1'),
      detail: _detailDto(favorited: false),
    );

    expect(find.text('收藏'), findsOneWidget);
    expect(find.text('已收藏'), findsNothing);
  });

  testWidgets('点击收藏：立即实心，不弹底部浮条', (tester) async {
    final repository = _FakeFavoriteRepository();
    await _pumpDetail(
      tester,
      favoriteRepository: repository,
      session: _session('u1'),
      detail: _detailDto(favorited: false),
    );

    await tester.tap(find.text('收藏'));
    await _settle(tester);

    expect(repository.addCalls, 1);
    expect(find.text('已收藏'), findsOneWidget);
    // 2026-10-28 裁定：成功反馈只靠星标变色，不再出现浮条 / 撤销入口。
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('撤销'), findsNothing);
  });

  testWidgets('再点一次取消收藏：发出 DELETE 并恢复空心', (tester) async {
    final repository = _FakeFavoriteRepository();
    await _pumpDetail(
      tester,
      favoriteRepository: repository,
      session: _session('u1'),
      detail: _detailDto(favorited: false),
    );

    await tester.tap(find.text('收藏'));
    await _settle(tester);
    await tester.tap(find.text('已收藏'));
    await _settle(tester);

    expect(repository.removeCalls, 1);
    expect(find.text('收藏'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('无障碍开启：收藏后仍无底部浮条（真机黑条不复现）', (tester) async {
    await _pumpDetail(
      tester,
      favoriteRepository: _FakeFavoriteRepository(),
      session: _session('u1'),
      detail: _detailDto(favorited: false),
      accessibleNavigation: true,
    );

    await tester.tap(find.text('收藏'));
    await _settle(tester);

    // 无障碍开启时带 action 的 SnackBar 不会自动消失，故这里根本不该产生浮条。
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('撤销'), findsNothing);
    expect(find.text('已收藏'), findsOneWidget);
  });

  testWidgets('POST 失败：图标回滚并提示错误', (tester) async {
    final repository = _FakeFavoriteRepository()..fail = true;
    await _pumpDetail(
      tester,
      favoriteRepository: repository,
      session: _session('u1'),
      detail: _detailDto(favorited: false),
    );

    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();

    expect(find.text('收藏'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);

    await _settle(tester);
  });

  testWidgets('41001 深链：星标未知不可点，联系按钮禁用', (tester) async {
    await _pumpDetail(
      tester,
      favoriteRepository: _FakeFavoriteRepository(),
      session: _session('u1'),
      detailError: const ApiException(
        code: ApiErrorCode.postGone,
        message: '信息已下架或不存在',
      ),
    );

    expect(find.text('这条信息已下架或不存在'), findsOneWidget);
    final action =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '收藏'));
    expect(action.onPressed, isNull);
    final contact = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(contact.onPressed, isNull);
  });

  testWidgets('41001 来自我的收藏：星标按已收藏可点', (tester) async {
    await _pumpDetail(
      tester,
      favoriteRepository: _FakeFavoriteRepository(),
      session: _session('u1'),
      detailError: const ApiException(
        code: ApiErrorCode.postGone,
        message: '信息已下架或不存在',
      ),
      args: const DetailScreenArgs(fromFavorites: true, initialFavorited: true),
    );

    expect(find.text('已收藏'), findsOneWidget);
    final action =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '已收藏'));
    expect(action.onPressed, isNotNull);
  });

  testWidgets('游客点击：登录成功后自动补执行收藏（R3）', (tester) async {
    final repository = _FakeFavoriteRepository();
    final sessionNotifier = _StubSessionNotifier(null);

    final router = GoRouter(
      initialLocation: '/detail/1001',
      routes: [
        GoRoute(
          path: '/detail/:id',
          builder: (context, state) => const DetailScreen(listingId: 1001),
        ),
        GoRoute(
          path: '/login',
          builder: (context, state) => Scaffold(
            body: Center(
              child: Builder(
                builder: (innerContext) => TextButton(
                  onPressed: () {
                    sessionNotifier.switchTo(_session('u1'));
                    innerContext.pop(true);
                  },
                  child: const Text('模拟登录成功'),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    await _pumpDetail(
      tester,
      favoriteRepository: repository,
      detail: _detailDto(),
      router: router,
      sessionNotifier: sessionNotifier,
    );

    expect(find.text('收藏'), findsOneWidget);
    await tester.tap(find.text('收藏'));
    await tester.pumpAndSettle();

    // 未登录先进入登录页，此时不得发收藏请求。
    expect(repository.addCalls, 0);
    await tester.tap(find.text('模拟登录成功'));
    await tester.pumpAndSettle();

    expect(repository.addCalls, 1);
    expect(find.text('已收藏'), findsWidgets);

    await _settle(tester);
  });

  testWidgets('详情渲染成功：浏览上报只发一次（R12）', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final postRepository = await _pumpDetail(
      tester,
      favoriteRepository: _FakeFavoriteRepository(),
      session: _session('u1'),
      detail: _detailDto(favorited: false),
    );

    expect(postRepository.reportCalls, 1);

    // 触发整树重建（屏幕尺寸变化会让 MaterialApp 重算 MediaQuery）。
    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpAndSettle();

    expect(postRepository.reportCalls, 1);
  });
}
