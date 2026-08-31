/// 鉴权仓库守门测试（PRD §3.4.1 / §3.5 / §3.7 / §3.8 / §12.2）。
///
/// **这些用例为什么必须存在**：`AuthRepository` 的风控与时效分支在页面上几乎
/// 无法手测触发 —— 「连错 5 次」要真的错 5 次，「锁 15 分钟自动解锁」要真的等
/// 15 分钟，「成功登录清空失败计数」要跨两次登录才能看出差别。这类分支既不会被
/// 编译器发现（都是合法代码），也不会被人眼发现（手测走不到），属于典型的
/// 机读盲区与人眼盲区重叠处。一旦写错，表现是「老用户莫名被锁」这种上线后
/// 极难复现的故障。
///
/// **时间为什么全部注入而不用 `DateTime.now()`**：这里断言的正是时间边界
/// （5 分钟有效期、60 秒冷却、15 分钟锁定）。用真实时钟就只能靠 sleep，
/// 既慢又会在 CI 上偶发失败；注入固定时刻后，「第 4 分 59 秒仍有效、
/// 第 5 分 00 秒失效」这种一秒之差的边界才能被稳定断言。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';

void main() {
  // 固定基准时刻：所有相对时间都从它偏移，避免用例之间因时钟推进而互相影响。
  final base = DateTime(2026, 8, 31, 10, 0, 0);
  const phone = '13800138000';
  final code = AuthRepository.debugCode;

  /// 新建一个已发过验证码的仓库，返回仓库本身。
  ///
  /// 参数 [at] 发码时刻，默认用 [base]。
  /// 多数用例都要先发码，这里收敛掉重复的两行。
  Future<AuthRepository> repoWithCodeSent({DateTime? at}) async {
    final repo = AuthRepository();
    final failure = await repo.sendCode(phone, now: at ?? base);
    expect(failure, isNull, reason: '前置发码不应失败');
    return repo;
  }

  group('手机号格式', () {
    test('11 位 1 开头合法', () {
      expect(AuthRepository.isValidPhone('13800138000'), isTrue);
      expect(AuthRepository.isValidPhone('19912345678'), isTrue);
      // 号段不做白名单（见实现注释）：新号段必须能过。
      expect(AuthRepository.isValidPhone('19812345678'), isTrue);
    });

    test('位数不对、开头不是 1、含非数字一律非法', () {
      expect(AuthRepository.isValidPhone('1380013800'), isFalse, reason: '10 位');
      expect(
        AuthRepository.isValidPhone('138001380000'),
        isFalse,
        reason: '12 位',
      );
      expect(AuthRepository.isValidPhone('23800138000'), isFalse, reason: '2 开头');
      expect(
        AuthRepository.isValidPhone('1380013800a'),
        isFalse,
        reason: '含字母',
      );
      expect(AuthRepository.isValidPhone(''), isFalse);
    });

    test('非法手机号在发码与登录两处都被挡下', () async {
      final repo = AuthRepository();
      expect(
        await repo.sendCode('138', now: base),
        AuthFailure.invalidPhone,
        reason: '非法号码不该消耗一条短信',
      );

      final result = await repo.loginWithSms(
        phone: '138',
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(result.isSuccess, isFalse);
      expect(result.failure, AuthFailure.invalidPhone);
    });
  });

  group('协议勾选（§3.8 / §12.2 agreement_accepted 必 true）', () {
    test('协议未勾时即便验证码正确也不放行', () async {
      final repo = await repoWithCodeSent();
      final result = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: false,
        now: base,
      );
      expect(result.isSuccess, isFalse);
      expect(result.failure, AuthFailure.agreementNotAccepted);
    });

    test('协议未勾的失败不计入风控次数', () async {
      final repo = await repoWithCodeSent();
      for (var i = 0; i < kMaxFailedAttempts + 1; i++) {
        await repo.loginWithSms(
          phone: phone,
          code: code,
          agreementAccepted: false,
          now: base,
        );
      }
      // 若把「没勾协议」也算作一次验证码失败，用户勾上协议后会发现自己已被锁 15 分钟，
      // 而他一次验证码都还没输错。
      final result = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(result.isSuccess, isTrue, reason: '协议类失败不应触发风控锁定');
    });
  });

  group('验证码生命周期（§12.2 expire_in / §3.5）', () {
    test('未请求验证码就登录 → codeNotRequested，而不是 wrongCode', () async {
      final repo = AuthRepository();
      final result = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(result.failure, AuthFailure.codeNotRequested);
    });

    test('有效期内输入正确验证码登录成功', () async {
      final repo = await repoWithCodeSent();
      final result = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base.add(const Duration(minutes: 1)),
      );
      expect(result.isSuccess, isTrue);
      expect(result.session, isNotNull);
    });

    test('有效期边界：差 1 秒仍有效，到点即过期', () async {
      final justInTime = await repoWithCodeSent();
      final ok = await justInTime.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base.add(kSmsCodeTtl - const Duration(seconds: 1)),
      );
      expect(ok.isSuccess, isTrue, reason: '4 分 59 秒应当仍可用');

      final expired = await repoWithCodeSent();
      final failed = await expired.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base.add(kSmsCodeTtl),
      );
      expect(failed.failure, AuthFailure.codeExpired, reason: '满 5 分钟即失效');
    });

    test('过期码被立即废弃：再试一次变成「请先获取」而不是继续报过期', () async {
      final repo = await repoWithCodeSent();
      final at = base.add(kSmsCodeTtl);
      await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: at,
      );
      final second = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: at,
      );
      // 过期码若继续占着「已请求过」的位置，页面就分不清该引导重新获取还是重新输入。
      expect(second.failure, AuthFailure.codeNotRequested);
    });

    test('登录成功后验证码作废，同一码不能二次使用', () async {
      final repo = await repoWithCodeSent();
      final first = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(first.isSuccess, isTrue);

      final replay = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(replay.failure, AuthFailure.codeNotRequested, reason: '验证码必须一次性');
    });
  });

  group('重发冷却（§3.5 步骤 2 的 60s 倒计时）', () {
    test('冷却期内重发被拒，冷却结束后可再发', () async {
      final repo = await repoWithCodeSent();
      expect(
        await repo.sendCode(phone, now: base.add(const Duration(seconds: 30))),
        AuthFailure.resendTooSoon,
      );
      expect(
        await repo.sendCode(phone, now: base.add(kSmsResendCooldown)),
        isNull,
        reason: '满 60 秒应当允许重发',
      );
    });

    test('resendCooldownLeft 随时间递减，未发码与已超时都返回零', () async {
      final repo = AuthRepository();
      expect(
        repo.resendCooldownLeft(phone, now: base),
        Duration.zero,
        reason: '从未发码时不该有冷却',
      );

      await repo.sendCode(phone, now: base);
      expect(repo.resendCooldownLeft(phone, now: base), kSmsResendCooldown);
      expect(
        repo.resendCooldownLeft(phone, now: base.add(const Duration(seconds: 40))),
        const Duration(seconds: 20),
      );
      // 不能返回负值：页面拿它做倒计时秒数，负数会显示成「-3s 后重发」。
      expect(
        repo.resendCooldownLeft(phone, now: base.add(const Duration(minutes: 5))),
        Duration.zero,
      );
    });

    test('冷却是按手机号分别计的，换号不受上一号影响', () async {
      final repo = await repoWithCodeSent();
      const other = '13900139000';
      expect(
        await repo.sendCode(other, now: base.add(const Duration(seconds: 5))),
        isNull,
        reason: '风控维度是 phone，不该被别的号码的冷却挡住',
      );
    });
  });

  group('风控锁定（§3.8 5 次 / §12.2 错误码 40105 锁 15 分钟）', () {
    test('阈值取值本身即契约：5 次、15 分钟、5 分钟有效期、60 秒冷却', () {
      // **这条用字面量而非常量自比**：其余用例的循环上界都写成 kMaxFailedAttempts，
      // 好处是阈值调整时用例不用改，代价是「阈值被改错」这件事它们一条都发现不了 ——
      // 常量改成 6，那些用例会跟着错 6 次然后照样通过。
      // PRD §3.8 与 §12.2 写死的是具体数字，这里就必须钉住具体数字。
      expect(kMaxFailedAttempts, 5, reason: '§3.8：连续失败 5 次锁定');
      expect(kLockoutDuration, const Duration(minutes: 15), reason: '§12.2 40105');
      expect(kSmsCodeTtl, const Duration(minutes: 5), reason: '§12.2 expire_in');
      expect(kSmsResendCooldown, const Duration(seconds: 60), reason: '§3.5 步骤 2');
    });

    test('前 4 次失败逐次递减剩余机会', () async {
      final repo = await repoWithCodeSent();
      for (var i = 1; i <= kMaxFailedAttempts - 1; i++) {
        final result = await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
        expect(result.failure, AuthFailure.wrongCode, reason: '第 $i 次仍应可重试');
        expect(
          result.remainingAttempts,
          kMaxFailedAttempts - i,
          reason: '第 $i 次失败后剩余机会应为 ${kMaxFailedAttempts - i}',
        );
      }
    });

    test('第 5 次失败即锁定，并带回锁定截止时刻', () async {
      final repo = await repoWithCodeSent();
      AuthResult? last;
      for (var i = 0; i < kMaxFailedAttempts; i++) {
        last = await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
      }
      expect(last!.failure, AuthFailure.lockedOut, reason: '达到 5 次即锁，不是超过才锁');
      expect(last.remainingAttempts, 0);
      // 页面要靠它拼「请在 N 分钟后重试」，缺了就只能写死 15 分钟。
      expect(last.lockedUntil, base.add(kLockoutDuration));
    });

    test('锁定期内即使验证码正确也不放行', () async {
      final repo = await repoWithCodeSent();
      for (var i = 0; i < kMaxFailedAttempts; i++) {
        await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
      }
      final result = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base.add(const Duration(minutes: 1)),
      );
      expect(result.failure, AuthFailure.lockedOut, reason: '锁定优先于验证码校验');
    });

    test('锁定期内连发码也不给（短信按条计费）', () async {
      final repo = await repoWithCodeSent();
      for (var i = 0; i < kMaxFailedAttempts; i++) {
        await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
      }
      expect(
        await repo.sendCode(phone, now: base.add(const Duration(minutes: 2))),
        AuthFailure.lockedOut,
        reason: '只拦登录不拦发码，攻击者仍能持续消耗短信费用',
      );
    });

    test('锁到期自动解锁，且失败计数一并清零', () async {
      final repo = await repoWithCodeSent();
      for (var i = 0; i < kMaxFailedAttempts; i++) {
        await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
      }

      final afterLock = base.add(kLockoutDuration);
      expect(
        await repo.sendCode(phone, now: afterLock),
        isNull,
        reason: '锁到期后应可重新获取验证码',
      );

      final result = await repo.loginWithSms(
        phone: phone,
        code: '000000',
        agreementAccepted: true,
        now: afterLock,
      );
      // 若解锁时只清锁不清计数，用户解锁后输错第一次就会立刻又被锁 15 分钟。
      expect(result.failure, AuthFailure.wrongCode);
      expect(
        result.remainingAttempts,
        kMaxFailedAttempts - 1,
        reason: '解锁后应重新拥有完整次数',
      );
    });

    test('登录成功清空历史失败计数', () async {
      final repo = await repoWithCodeSent();
      for (var i = 0; i < kMaxFailedAttempts - 1; i++) {
        await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
      }
      final success = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(success.isSuccess, isTrue);

      // 下一轮登录再输错一次，应当还剩 4 次而不是直接被锁。
      final later = base.add(const Duration(hours: 1));
      await repo.sendCode(phone, now: later);
      final result = await repo.loginWithSms(
        phone: phone,
        code: '000000',
        agreementAccepted: true,
        now: later,
      );
      expect(result.failure, AuthFailure.wrongCode);
      expect(result.remainingAttempts, kMaxFailedAttempts - 1);
    });

    test('风控按手机号隔离，一个号被锁不影响另一个号', () async {
      final repo = await repoWithCodeSent();
      for (var i = 0; i < kMaxFailedAttempts; i++) {
        await repo.loginWithSms(
          phone: phone,
          code: '000000',
          agreementAccepted: true,
          now: base,
        );
      }
      const other = '13900139000';
      expect(await repo.sendCode(other, now: base), isNull);
      final result = await repo.loginWithSms(
        phone: other,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(result.isSuccess, isTrue, reason: '锁定维度必须是单个号码');
    });
  });

  group('会话（§3.7 / §12.2 is_new_user）', () {
    test('首次登录 is_new_user 为 true，再次登录为 false', () async {
      final repo = await repoWithCodeSent();
      final first = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      );
      expect(first.session!.isNewUser, isTrue, reason: '§3.4.1 未注册号码验证后自动注册');

      final later = base.add(const Duration(days: 1));
      await repo.sendCode(phone, now: later);
      final second = await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: later,
      );
      // §3.5 步骤 4 的「完善资料抽屉」只该在首次弹出，靠的就是这个标志。
      expect(second.session!.isNewUser, isFalse);
    });

    test('会话字段：手机号存完整值、有效期 30 天、默认未实名', () async {
      final repo = await repoWithCodeSent();
      final session = (await repo.loginWithSms(
        phone: phone,
        code: code,
        agreementAccepted: true,
        now: base,
      )).session!;

      // §3.7 的脱敏针对「别人的联系方式」，本人号码要完整存（个人中心与改绑要用）。
      expect(session.phone, phone);
      expect(session.expireAt, base.add(const Duration(days: 30)));
      // §3.8：未实名不等于未登录，登录后默认未实名且仍可浏览与发受限帖。
      expect(session.realNameVerified, isFalse);
      expect(session.token, isNotEmpty);
      expect(session.userId, isNotEmpty);
    });

    test('isExpired 边界：到期当刻即算过期', () {
      final session = AuthSession(
        userId: 'u1',
        phone: phone,
        token: 't',
        expireAt: base,
        isNewUser: false,
      );
      expect(
        session.isExpired(base.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      // 到期时刻本身算过期：判成未过期会让「刚好在这一刻」的请求带着废 Token 出门。
      expect(session.isExpired(base), isTrue);
      expect(session.isExpired(base.add(const Duration(seconds: 1))), isTrue);
    });
  });
}
