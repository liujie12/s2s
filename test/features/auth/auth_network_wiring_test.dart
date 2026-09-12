/// KTD5 焊接点测试：features/auth → core/network 单向接线。
///
/// 验证 `wiredNetworkHooksProvider` 把 Riverpod 会话态/隐私同意态/设备 ID
/// 映射为 core 的 [NetworkHooks] 七回调（U3 四回调 + U5 三回调）：
///   - readToken 读 authSessionProvider 当前 Token（null = 未登录）；
///   - readPrivacyConsented 读 privacyConsentProvider 的 agreed 态；
///   - readDeviceId 读 DeviceIdProvider（同意门的拦截在 HeaderInterceptor）；
///   - newUuidV4 给真实 UUID v4 生成器（core 不感知 Riverpod）；
///   - writeToken（U5）转调 AuthSessionNotifier.updateToken：只轮换
///     Token/expireAt，不换代次、保留 userId/phone/isNewUser/realNameVerified；
///   - onSessionCleared（U5）转调 signOut：清会话并推进代次；
///   - readSessionEpoch（U5）读会话代次：signIn/signOut +1，updateToken 不增。
///
/// 依赖方向断言：lib/core/ 不得 import lib/features/（KTD5），由实现与
/// 本测试的 import 方向共同保证（本文件是 features 侧，反向依赖 core 合法）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/features/auth/auth_network_wiring.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/privacy/privacy_consent.dart';

import '../../support/test_support.dart';

/// 构造一个会话态已覆写的测试容器。
ProviderContainer buildContainer({
  AuthSession? session,
  PrivacyConsentStatus consent = PrivacyConsentStatus.notAgreed,
}) {
  final container = ProviderContainer(overrides: [
    authSessionProvider.overrideWith(() => _FixedAuthSessionNotifier(session)),
    // Riverpod 3 的 NotifierProvider 无 overrideWithValue（仅 Provider/
    // FutureProvider/StreamProvider 有），固定三态走 overrideWith。
    privacyConsentProvider.overrideWith(
      () => _FixedPrivacyConsentNotifier(consent),
    ),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// 固定会话态的 Notifier（不依赖登录流程，直接置初始值）。
class _FixedAuthSessionNotifier extends AuthSessionNotifier {
  _FixedAuthSessionNotifier(this._session);

  final AuthSession? _session;

  @override
  AuthSession? build() => _session;
}

/// 固定同意态的 Notifier（不触发真实 SharedPreferences 读盘）。
class _FixedPrivacyConsentNotifier extends PrivacyConsentNotifier {
  _FixedPrivacyConsentNotifier(this._status);

  final PrivacyConsentStatus _status;

  @override
  PrivacyConsentStatus build() => _status;
}

/// 构造最小合法会话。
AuthSession sessionWithToken(String token) => AuthSession(
      userId: 'user-test',
      phone: '13800008000',
      token: token,
      expireAt: DateTime(2099),
      isNewUser: false,
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues(const {});
  });

  test('未登录：readToken 返回 null', () async {
    final container = buildContainer();
    final hooks = container.read(wiredNetworkHooksProvider);
    expect(await hooks.readToken(), isNull,
        reason: 'HeaderInterceptor 据此不注入 Authorization（非空串）');
  });

  test('已登录：readToken 返回当前会话 Token', () async {
    final container =
        buildContainer(session: sessionWithToken('jwt-wired-1'));
    final hooks = container.read(wiredNetworkHooksProvider);
    expect(await hooks.readToken(), 'jwt-wired-1');
  });

  test('会话变化经同一 hooks 实例读到最新 Token（read 闭包实时读）', () async {
    final container =
        buildContainer(session: sessionWithToken('jwt-old'));
    final hooks = container.read(wiredNetworkHooksProvider);
    expect(await hooks.readToken(), 'jwt-old');

    container.read(authSessionProvider.notifier).signIn(sessionWithToken('jwt-new'));
    expect(await hooks.readToken(), 'jwt-new',
        reason: '回调闭包内 ref.read 实时取态，登录态变化不需重建 dio');
  });

  test('readPrivacyConsented 与同意 Provider 三态映射', () async {
    final notAgreed =
        buildContainer(consent: PrivacyConsentStatus.notAgreed);
    expect(
      await notAgreed.read(wiredNetworkHooksProvider).readPrivacyConsented(),
      isFalse,
    );

    final unknown = buildContainer(consent: PrivacyConsentStatus.unknown);
    expect(
      await unknown.read(wiredNetworkHooksProvider).readPrivacyConsented(),
      isFalse,
      reason: 'unknown 不得按已同意处理（冷启动读盘完成前不外发设备 ID）');

    final agreed = buildContainer(consent: PrivacyConsentStatus.agreed);
    expect(
      await agreed.read(wiredNetworkHooksProvider).readPrivacyConsented(),
      isTrue,
    );
  });

  test('readDeviceId 返回 UUID v4 形态设备 ID', () async {
    final container = buildContainer(consent: PrivacyConsentStatus.agreed);
    final hooks = container.read(wiredNetworkHooksProvider);
    final id = await hooks.readDeviceId();
    expect(id, isNotNull);
    expect(TestFixtures.uuidV4Pattern.hasMatch(id!), isTrue);
  });

  test('newUuidV4 产出合法 UUID v4（默认生成器可直接用）', () {
    final container = buildContainer();
    final hooks = container.read(wiredNetworkHooksProvider);
    expect(TestFixtures.uuidV4Pattern.hasMatch(hooks.newUuidV4()), isTrue);
  });

  group('U5 续期三回调焊接（KTD5：core 经回调操作会话态）', () {
    test('writeToken 转调 updateToken：只换 Token/expireAt，身份字段保留',
        () async {
      final container = buildContainer(
        session: AuthSession(
          userId: 'user-wired',
          phone: '13800008000',
          token: 'jwt-old-wired',
          expireAt: DateTime.utc(2026),
          isNewUser: true,
          realNameVerified: true,
        ),
      );
      final hooks = container.read(wiredNetworkHooksProvider);
      final epochBefore = await hooks.readSessionEpoch();

      const newToken = 'jwt-new-wired';
      final newExpireAt = DateTime.utc(2099, 6, 1);
      await hooks.writeToken(newToken, newExpireAt);

      final session = container.read(authSessionProvider);
      expect(session, isNotNull);
      expect(session!.token, newToken, reason: '新 Token 必须写回');
      expect(session.expireAt, newExpireAt);
      expect(session.userId, 'user-wired', reason: '续期不得更换身份字段');
      expect(session.phone, '13800008000');
      expect(session.isNewUser, isTrue, reason: 'isNewUser 逐字保留');
      expect(session.realNameVerified, isTrue, reason: '实名态逐字保留');
      expect(await hooks.readToken(), newToken,
          reason: '同一 hooks 实例随后能读到新 Token（重放换新 Authorization）');
      expect(await hooks.readSessionEpoch(), epochBefore,
          reason: '续期是同一会话的 Token 轮换，代次不得递增');
    });

    test('无会话时 updateToken 拒绝写回（第二道防线：不复活已登出会话）',
        () async {
      final container = buildContainer();
      final hooks = container.read(wiredNetworkHooksProvider);

      await hooks.writeToken('jwt-zombie', DateTime.utc(2099));

      expect(container.read(authSessionProvider), isNull,
          reason: '登出态收到迟到续期结果时必须丢弃，禁止复活会话');
      expect(await hooks.readToken(), isNull);
    });

    test('onSessionCleared 转调 signOut：清空会话并推进代次', () async {
      final container =
          buildContainer(session: sessionWithToken('jwt-to-clear'));
      final hooks = container.read(wiredNetworkHooksProvider);
      final epochBefore = await hooks.readSessionEpoch();

      await hooks.onSessionCleared();

      expect(container.read(authSessionProvider), isNull,
          reason: '认证类续期失败必须清空会话，UI 侧 watch 态跳登录');
      expect(await hooks.readToken(), isNull);
      expect(await hooks.readSessionEpoch(), epochBefore + 1,
          reason: 'signOut 推进代次，在途的其他续期结果将因代次不符被丢弃');
    });

    test('readSessionEpoch：signIn/signOut 各 +1，updateToken 不增', () async {
      final container = buildContainer();
      final hooks = container.read(wiredNetworkHooksProvider);
      final notifier = container.read(authSessionProvider.notifier);
      final initialEpoch = await hooks.readSessionEpoch();

      notifier.signIn(sessionWithToken('jwt-a'));
      final epochAfterSignIn = await hooks.readSessionEpoch();
      expect(epochAfterSignIn, initialEpoch + 1);

      notifier.updateToken(
        token: 'jwt-a-rotated',
        expireAt: DateTime.utc(2099),
      );
      expect(
        await hooks.readSessionEpoch(),
        epochAfterSignIn,
        reason: 'updateToken 不得推进代次',
      );

      notifier.signOut();
      expect(await hooks.readSessionEpoch(), epochAfterSignIn + 1,
          reason: 'signOut 推进代次');
    });
  });
}
