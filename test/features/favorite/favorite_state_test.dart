/// 收藏态容器测试（U6；KTD2 / KTD3 / R4 / R6）。
///
/// 只测容器本身：换号清空、首次填充不覆盖、乐观写与失败回滚、同帖单在途。
/// 页面级三态与撤销流程在 `detail_favorite_test.dart`。
library;

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_error_code.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/favorite/favorite_dto.dart';
import 'package:zhaoyazhao/features/favorite/favorite_repository.dart';
import 'package:zhaoyazhao/features/favorite/favorite_state.dart';

/// 内存假收藏仓库：记录调用次数，可按需失败或挂起。
class _FakeFavoriteRepository extends FavoriteRepository {
  _FakeFavoriteRepository() : super(Dio());

  /// addFavorite 调用次数。
  int addCalls = 0;

  /// removeFavorite 调用次数。
  int removeCalls = 0;

  /// 置 true 时请求抛网络异常（验证回滚）。
  bool fail = false;

  /// 非 null 时请求挂起，直到该 Completer 完成（验证同帖单在途）。
  Completer<void>? gate;

  @override
  Future<FavoriteResultDto> addFavorite(int postId, {String? interactionId}) async {
    addCalls++;
    if (gate != null) await gate!.future;
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
    if (gate != null) await gate!.future;
    if (fail) {
      throw const ApiException(
        code: ApiErrorCode.networkFailure,
        message: '网络异常',
      );
    }
    return const FavoriteResultDto(favorited: false);
  }
}

/// 可变会话 Notifier：不触登录流程与安全存储，直接置/切会话。
class _StubSessionNotifier extends AuthSessionNotifier {
  _StubSessionNotifier(this._session);

  AuthSession? _session;

  @override
  AuthSession? build() => _session;

  /// 切换会话（模拟登出/换号，推进状态即触发容器清空）。
  ///
  /// 参数：[session] 新会话，null 表示登出。
  /// 返回：void。
  void switchTo(AuthSession? session) {
    _session = session;
    state = session;
  }
}

/// 构造最小合法会话。
///
/// 参数：[userId] 用户 ID（会话键）。
/// 返回：[AuthSession]。
AuthSession _session(String userId) => AuthSession(
      userId: userId,
      phone: '13800008000',
      token: 'jwt-favorite-test',
      expireAt: DateTime(2099),
      isNewUser: false,
    );

/// 构造测试容器。
///
/// 参数：[session] 初始会话；[repository] 假仓库。
/// 返回：[ProviderContainer]（调用方负责 dispose）。
ProviderContainer _container({
  AuthSession? session,
  required _FakeFavoriteRepository repository,
}) {
  final container = ProviderContainer(
    overrides: [
      authSessionProvider.overrideWith(() => _StubSessionNotifier(session)),
      favoriteRepositoryProvider.overrideWithValue(repository),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('未登录：read 为 null，seed 不写', () {
    final repository = _FakeFavoriteRepository();
    final container = _container(repository: repository);
    final notifier = container.read(favoriteStateProvider.notifier);

    notifier.seed(1001, true);

    expect(notifier.read(1001), isNull);
    expect(container.read(favoriteStateProvider), isEmpty);
  });

  test('seed 首次填充；已有值不覆盖（服务端只做首次对账）', () {
    final repository = _FakeFavoriteRepository();
    final container = _container(
      session: _session('user-a'),
      repository: repository,
    );
    final notifier = container.read(favoriteStateProvider.notifier);

    notifier.seed(1001, true);
    notifier.seed(1001, false);

    expect(notifier.read(1001), isTrue);
  });

  test('set(true)：乐观立即为真，请求后保持服务端回执', () async {
    final repository = _FakeFavoriteRepository();
    final container = _container(
      session: _session('user-a'),
      repository: repository,
    );
    final notifier = container.read(favoriteStateProvider.notifier);

    final result = await notifier.set(1001, true);

    expect(result, isTrue);
    expect(notifier.read(1001), isTrue);
    expect(repository.addCalls, 1);
  });

  test('set 失败：回滚到请求前的值并把异常抛给页面', () async {
    final repository = _FakeFavoriteRepository()..fail = true;
    final container = _container(
      session: _session('user-a'),
      repository: repository,
    );
    final notifier = container.read(favoriteStateProvider.notifier);
    notifier.seed(1001, false);

    await expectLater(
      notifier.set(1001, true),
      throwsA(isA<ApiException>()),
    );

    expect(notifier.read(1001), isFalse);
  });

  test('set 失败且此前无值：回滚为未知（不留下确定态）', () async {
    final repository = _FakeFavoriteRepository()..fail = true;
    final container = _container(
      session: _session('user-a'),
      repository: repository,
    );
    final notifier = container.read(favoriteStateProvider.notifier);

    await expectLater(
      notifier.set(1001, true),
      throwsA(isA<ApiException>()),
    );

    expect(notifier.read(1001), isNull);
  });

  test('换号：旧会话条目清空，新会话读到 null（KTD2）', () async {
    final repository = _FakeFavoriteRepository();
    final container = _container(
      session: _session('user-a'),
      repository: repository,
    );
    final notifier = container.read(favoriteStateProvider.notifier);
    await notifier.set(1001, true);
    expect(notifier.read(1001), isTrue);

    (container.read(authSessionProvider.notifier) as _StubSessionNotifier)
        .switchTo(_session('user-b'));

    expect(notifier.read(1001), isNull);
    expect(container.read(favoriteStateProvider), isEmpty);
  });

  test('同帖在途：第二次调用不重复发请求，返回当前乐观值（KTD3）', () async {
    final repository = _FakeFavoriteRepository()..gate = Completer<void>();
    final container = _container(
      session: _session('user-a'),
      repository: repository,
    );
    final notifier = container.read(favoriteStateProvider.notifier);

    final first = notifier.set(1001, true);
    // 让 addFavorite 先进入在途状态。
    await Future<void>.delayed(Duration.zero);
    final second = await notifier.set(1001, false);

    expect(repository.addCalls, 1);
    expect(repository.removeCalls, 0);
    expect(second, isTrue);

    repository.gate!.complete();
    expect(await first, isTrue);
  });
}
