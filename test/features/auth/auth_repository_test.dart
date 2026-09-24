/// 鉴权仓库真网络测试（[123] U10：mock 删除后经生产同款 dio 链调真接口）。
///
/// 用 [NetworkChainHarness] + [MockApiServer] 走真 HTTP 栈 + 五拦截器链，
/// 断言 AuthRepository 的「服务端错误码 → [AuthFailure]/[AuthResult] 映射」：
///   - 发码成功/限频（42905 → resendTooSoon）；
///   - 登录成功（LoginResult → AuthSession）、验证码错误（40001 → wrongCode）、
///     锁定（40105 + Retry-After → lockedOut 拼 lockedUntil）；
///   - 客户端本地判（手机号非法/协议未勾）不触网。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';

import '../../support/network_chain_harness.dart';
import '../../support/test_support.dart';

/// 合法手机号（契约 pattern `^1[3-9]\d{9}$`）。
const String validPhone = '13800138000';

/// 登录成功响应的 LoginResult.data（契约 §12.2）。
Map<String, Object?> loginResultData({
  String token = 'jwt-test-fake',
  String expireAt = '2099-01-01T00:00:00Z',
  bool isNewUser = true,
  int userId = 10086,
}) {
  return {
    'token': token,
    'expire_at': expireAt,
    'is_new_user': isNewUser,
    'user': {
      'id': userId,
      'nickname': '老王',
      'realname_status': 'none',
    },
  };
}

void main() {
  late NetworkChainHarness harness;
  late AuthRepository repo;

  setUp(() async {
    harness = NetworkChainHarness();
    await harness.start();
    repo = AuthRepository(harness.dio);
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('sendCode 发码', () {
    test('手机号非法：本地判，不触网', () async {
      final failure = await repo.sendCode('123');
      expect(failure, AuthFailure.invalidPhone);
    });

    test('成功：返回 null 并启动本地 60s 冷却', () async {
      harness.stub('POST', '/api/v1/auth/sms/send', (req) async {
        return MockResponse(
          status: 200,
          body: ApiEnvelope.success(data: {'expire_in': 300}),
        );
      });

      final at = DateTime(2026, 9, 30, 12);
      final failure = await repo.sendCode(validPhone, now: at);
      expect(failure, isNull);
      // 冷却真源在仓库侧：刚发完立即重发应还剩约 60s。
      expect(repo.resendCooldownLeft(validPhone, now: at).inSeconds, 60);
    });

    test('限频 42905：映射 resendTooSoon', () async {
      harness.stubRateLimited(
        'POST',
        '/api/v1/auth/sms/send',
        code: 42905,
      );

      final failure = await repo.sendCode(validPhone);
      expect(failure, AuthFailure.resendTooSoon);
    });
  });

  group('loginWithSms 登录', () {
    test('协议未勾：本地判，不触网', () async {
      final result = await repo.loginWithSms(
        phone: validPhone,
        code: '123456',
        agreementAccepted: false,
      );
      expect(result.failure, AuthFailure.agreementNotAccepted);
    });

    test('手机号非法：本地判，不触网', () async {
      final result = await repo.loginWithSms(
        phone: '123',
        code: '123456',
        agreementAccepted: true,
      );
      expect(result.failure, AuthFailure.invalidPhone);
    });

    test('成功：解析 LoginResult 为会话（userId 取 user.id 字符串）', () async {
      harness.stub('POST', '/api/v1/auth/sms/login', (req) async {
        return MockResponse(
          status: 200,
          body: ApiEnvelope.success(data: loginResultData()),
        );
      });

      final result = await repo.loginWithSms(
        phone: validPhone,
        code: '123456',
        agreementAccepted: true,
      );
      expect(result.isSuccess, isTrue);
      final session = result.session!;
      expect(session.token, 'jwt-test-fake');
      expect(session.userId, '10086', reason: 'int64 id 转字符串不丢精度');
      expect(session.phone, validPhone, reason: '完整手机号取输入值（服务端只回脱敏）');
      expect(session.isNewUser, isTrue);
      expect(session.expireAt, DateTime.utc(2099));
    });

    test('验证码错误 40001：映射 wrongCode', () async {
      harness.stub('POST', '/api/v1/auth/sms/login', (req) async {
        return MockResponse(
          status: 400,
          body: ApiEnvelope.failure(40001, '验证码不正确'),
        );
      });

      final result = await repo.loginWithSms(
        phone: validPhone,
        code: '000000',
        agreementAccepted: true,
      );
      expect(result.failure, AuthFailure.wrongCode);
    });

    test('锁定 40105 + Retry-After：映射 lockedOut 并拼 lockedUntil', () async {
      harness.stub('POST', '/api/v1/auth/sms/login', (req) async {
        return MockResponse(
          status: 401,
          headers: const {'Retry-After': '900'},
          body: ApiEnvelope.failure(40105, '操作过于频繁'),
        );
      });

      final at = DateTime(2026, 9, 30, 12);
      final result = await repo.loginWithSms(
        phone: validPhone,
        code: '000000',
        agreementAccepted: true,
        now: at,
      );
      expect(result.failure, AuthFailure.lockedOut);
      expect(result.remainingAttempts, 0);
      expect(
        result.lockedUntil,
        at.add(const Duration(seconds: 900)),
        reason: 'lockedUntil = 基准时刻 + Retry-After 秒数',
      );
    });
  });
}
