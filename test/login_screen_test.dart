/// 登录页交互守门测试（PRD §3.4.1 / §3.5 / §3.8）。
///
/// **这些用例为什么必须存在**：§3.8 边界表里「协议未勾选 → 登录按钮 Disabled」
/// 是一条**合规要求**而不是交互偏好（《个人信息保护法》的单独同意）。它在代码里
/// 只是 [bool] 的一个与项，任何一次重构把 `_agreed` 从 `_canSubmit` 里漏掉，
/// 编译器不会报错、界面也照常能用 —— 只有断言能拦住。同理「默认不勾」这一条：
/// 把初值写成 true 是一行字的事，人眼过页面时反而最容易当成「已经勾好了，挺好」。
///
/// **为什么不测登录成功路径**：成功分支会调 `GoRouter.of(context).pop(true)`，
/// 需要搭一整套路由环境；而「成功后写入会话并返回上一页」这件事，
/// 在 contact 页的登录门接线处才是真正的观察点。这里只守住本页自己的判断逻辑。
library;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/features/auth/auth_repository.dart';
import 'package:zhaoyazhao/features/auth/login_screen.dart';

/// 测试用假仓库：不触网，直接返回可控结果（页面交互逻辑的观察对象）。
///
/// U10 前 login_screen_test 依赖内存 mock 的 AuthRepository；U10 改真网络后，
/// 若页面测试走真 dio + MockApiServer 会撞上 testWidgets 的 FakeAsync——真实
/// socket I/O 的多阶段异步链（连接→发送→接收）的 continuation 在 FakeAsync 里
/// 无法推进，发码/登录会永久挂起。页面测试只关心「给定 AuthResult/AuthFailure
/// 后页面怎么反应」，服务端错误码映射已由
/// `test/features/auth/auth_repository_test.dart`（真 HTTP 栈）覆盖，故此处注入
/// 不触网的假仓库，聚焦页面交互本身。
class _FakeAuthRepository extends AuthRepository {
  _FakeAuthRepository() : super(Dio());

  /// 是否已发码（驱动 resendCooldownLeft 返回 60s 冷却）。
  bool _sent = false;

  @override
  Future<AuthFailure?> sendCode(String phone, {DateTime? now}) async {
    if (!AuthRepository.isValidPhone(phone)) return AuthFailure.invalidPhone;
    _sent = true;
    return null;
  }

  @override
  Duration resendCooldownLeft(String phone, {DateTime? now}) =>
      _sent ? const Duration(seconds: 60) : Duration.zero;

  @override
  Future<AuthResult> loginWithSms({
    required String phone,
    required String code,
    required bool agreementAccepted,
    DateTime? now,
  }) async {
    if (!AuthRepository.isValidPhone(phone)) {
      return const AuthResult.failure(AuthFailure.invalidPhone);
    }
    if (!agreementAccepted) {
      return const AuthResult.failure(AuthFailure.agreementNotAccepted);
    }
    if (code == AuthRepository.debugCode) {
      return AuthResult.success(
        AuthSession(
          userId: '10086',
          phone: phone,
          token: 'jwt-test-fake',
          expireAt: DateTime(2099),
          isNewUser: false,
        ),
      );
    }
    return const AuthResult.failure(AuthFailure.wrongCode);
  }
}

void main() {
  /// 挂载登录页。
  ///
  /// 参数 [tester] 测试驱动器。
  /// 不套 GoRouter：本页构建期不触碰路由，只有关闭按钮与成功分支才会用到。
  /// 经 [authRepositoryProvider] 注入不触网的假仓库。
  Future<void> pumpLogin(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_FakeAuthRepository()),
        ],
        child: const MaterialApp(home: LoginScreen()),
      ),
    );
  }

  /// 卸载登录页并让残留的倒计时 Timer 自行收尾。
  ///
  /// 参数 [tester] 测试驱动器。
  /// `_startCountdown` 用的是 `Timer.periodic`，它在下一次 tick 发现
  /// `!mounted` 才会 cancel。不给它这一次 tick，测试框架会报「Timer 仍待执行」——
  /// 而这个报错恰好证明了页面 dispose 时必须 cancel（见 login_screen 的 dispose）。
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  /// 驱动一次帧刷新。
  ///
  /// 假仓库的 sendCode/loginWithSms 是立即完成的异步方法（无真实 I/O），
  /// 只需一次 pump flush microtask 让 `_sendCode`/`_submit` 的 setState 落地。
  Future<void> settleAsync(WidgetTester tester) async {
    await tester.pump();
  }

  /// 取出主按钮当前是否可点。
  ///
  /// 参数 [tester] 测试驱动器。返回 true 表示可点。
  bool submitEnabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '登录 / 注册'),
    );
    return button.onPressed != null;
  }

  /// 取出「获取验证码」按钮当前是否可点。
  bool sendEnabled(WidgetTester tester) {
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, '获取验证码'),
    );
    return button.onPressed != null;
  }

  /// 完成「输入手机号 → 发码 → 输入验证码」三步，停在可提交前一刻。
  ///
  /// 参数 [tester] 测试驱动器；[code] 要填入的验证码。
  Future<void> fillPhoneAndCode(
    WidgetTester tester, {
    required String code,
  }) async {
    await tester.enterText(find.byType(TextField).first, '13800138000');
    await tester.pump();
    await tester.tap(find.text('获取验证码'));
    await settleAsync(tester);
    await tester.enterText(find.byType(TextField).last, code);
    await tester.pump();
  }

  group('初始态（§3.4.1 默认不勾 / §3.8 按钮 Disabled）', () {
    testWidgets('协议默认不勾选', (tester) async {
      await pumpLogin(tester);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      // 预勾在合规检查中属可判定的违规项，不是「更方便」。
      expect(checkbox.value, isFalse);
      await unmount(tester);
    });

    testWidgets('主按钮初始禁用', (tester) async {
      await pumpLogin(tester);
      expect(submitEnabled(tester), isFalse);
      await unmount(tester);
    });

    testWidgets('手机号为空时不能获取验证码', (tester) async {
      await pumpLogin(tester);
      expect(sendEnabled(tester), isFalse, reason: '空号码发码只会白费一条短信');
      await unmount(tester);
    });

    testWidgets('验证码框在发码前禁用，且提示语说明原因', (tester) async {
      await pumpLogin(tester);
      final codeField = tester.widget<TextField>(find.byType(TextField).last);
      expect(codeField.enabled, isFalse);
      // 只把框灰掉却不解释，用户会以为是故障。
      expect(find.text('请先获取验证码'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('第三方入口呈现但禁用（§3.4.1 本期不实现）', (tester) async {
      await pumpLogin(tester);
      for (final label in ['微信', 'QQ', 'Apple']) {
        final button = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, label),
        );
        // 隐藏掉会让「本期不实现」这个决定在验收时无从确认。
        expect(button.onPressed, isNull, reason: '$label 应为灰禁用而非可点');
      }
      await unmount(tester);
    });

    testWidgets('§3.4.1 固定文案逐字呈现', (tester) async {
      await pumpLogin(tester);
      expect(find.text('用就近的资源解决本地的需求'), findsOneWidget);
      expect(find.text('我同意用户协议与隐私政策'), findsOneWidget);
      expect(find.text('未注册手机号验证后自动注册'), findsOneWidget);
      await unmount(tester);
    });
  });

  group('手机号校验驱动发码按钮', () {
    testWidgets('位数不足时仍禁用，满 11 位才放开', (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, '1380013');
      await tester.pump();
      expect(sendEnabled(tester), isFalse);

      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      expect(sendEnabled(tester), isTrue);
      await unmount(tester);
    });
  });

  group('发码后（§3.5 步骤 2 的 60s 倒计时）', () {
    testWidgets('倒计时接管按钮文案，期间不可重发', (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      await tester.tap(find.text('获取验证码'));
      await settleAsync(tester);

      expect(find.text('获取验证码'), findsNothing, reason: '冷却中不该还显示可发送文案');
      expect(find.textContaining('s 后重发'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('给出联调验证码提示条，否则无短信通道时无法自测', (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      await tester.tap(find.text('获取验证码'));
      await settleAsync(tester);

      expect(
        find.textContaining(AuthRepository.debugCode),
        findsOneWidget,
        reason: '提示条须带出固定码，且文案标明「联调」',
      );
      await unmount(tester);
    });

    testWidgets('验证码框发码后启用', (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      await tester.tap(find.text('获取验证码'));
      await settleAsync(tester);

      final codeField = tester.widget<TextField>(find.byType(TextField).last);
      expect(codeField.enabled, isTrue);
      await unmount(tester);
    });
  });

  group('提交条件（§3.8 协议未勾 → Disabled）', () {
    testWidgets('手机号与验证码都填好，但协议未勾 → 主按钮仍禁用', (tester) async {
      await pumpLogin(tester);
      await fillPhoneAndCode(tester, code: AuthRepository.debugCode);
      // 这是本文件最重要的一条：其余条件全部满足，唯独协议未勾。
      expect(submitEnabled(tester), isFalse);
      await unmount(tester);
    });

    testWidgets('勾上协议后主按钮放开', (tester) async {
      await pumpLogin(tester);
      await fillPhoneAndCode(tester, code: AuthRepository.debugCode);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(submitEnabled(tester), isTrue);
      await unmount(tester);
    });

    testWidgets('协议已勾但只填了手机号（未发码）→ 主按钮禁用', (tester) async {
      await pumpLogin(tester);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(submitEnabled(tester), isFalse, reason: '未发码就提交必然失败，不该放行');
      await unmount(tester);
    });

    testWidgets('协议行整行文字可点切换（24px 勾选框低于 44px 触达下限）', (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.text('我同意用户协议与隐私政策'));
      await tester.pump();
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isTrue);
      await unmount(tester);
    });
  });

  group('错误提示（常驻横条而非 Toast）', () {
    testWidgets('验证码输错后横条显示原因，且不会自动消失', (tester) async {
      await pumpLogin(tester);
      await fillPhoneAndCode(tester, code: '000000');
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('登录 / 注册'));
      await settleAsync(tester);

      expect(find.text(AuthFailure.wrongCode.message), findsOneWidget);
      // 再推进几秒，横条必须还在 —— 用户要对照它改输入。
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(AuthFailure.wrongCode.message), findsOneWidget);
      await unmount(tester);
    });
  });
}
