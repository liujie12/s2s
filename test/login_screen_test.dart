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
import 'package:zhaoyazhao/features/auth/wechat_auth_bridge.dart';

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

  /// 最近一次发码使用的 scene（测试绑定模式时校验 `bind`）。
  String? lastScene;

  @override
  Future<AuthFailure?> sendCode(
    String phone, {
    DateTime? now,
    String scene = 'login',
  }) async {
    if (!AuthRepository.isValidPhone(phone)) return AuthFailure.invalidPhone;
    lastScene = scene;
    _sent = true;
    return null;
  }

  @override
  Future<AuthFailure?> bindPhone({
    required String phone,
    required String code,
  }) async => bindPhoneFailure;

  /// 绑定手机号的预设失败（null = 成功）。
  AuthFailure? bindPhoneFailure;

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

  @override
  Future<AuthResult> loginWithWechat({
    required String code,
    required bool agreementAccepted,
  }) async {
    if (!agreementAccepted) {
      return const AuthResult.failure(AuthFailure.agreementNotAccepted);
    }
    // 页面测试不进入成功分支（成功会 pop 路由），固定回「暂未开放」。
    return const AuthResult.failure(AuthFailure.wechatUnavailable);
  }
}

/// 测试用微信授权桥：可控抛取消 / 抛未配置（成功时返回固定 code）。
class _FakeWechatBridge implements WechatAuthBridge {
  _FakeWechatBridge({this.error});

  /// 非 null 时 `requestCode` 抛出该异常。
  final Object? error;

  /// `requestCode` 被调用的次数（用于断言「未经同意不得拉起授权」）。
  int calls = 0;

  @override
  bool get isAvailable => error is! WechatAuthUnavailableException;

  @override
  Future<String> requestCode() async {
    calls++;
    final failure = error;
    if (failure != null) throw failure;
    return 'wx-code';
  }
}

void main() {
  /// 挂载登录页。
  ///
  /// 参数 [tester] 测试驱动器；[bridge] 可选微信授权桥（默认走真实 Provider 的
  /// 「未配置」实现）；[repo] 可选假仓库（默认新建）；[bindMode] 是否以绑定
  /// 手机号模式挂载。
  /// 不套 GoRouter：本页构建期不触碰路由，只有关闭按钮与成功分支才会用到。
  /// 经 [authRepositoryProvider] 注入不触网的假仓库。
  Future<void> pumpLogin(
    WidgetTester tester, {
    WechatAuthBridge? bridge,
    _FakeAuthRepository? repo,
    bool bindMode = false,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(repo ?? _FakeAuthRepository()),
          if (bridge != null)
            wechatAuthBridgeProvider.overrideWithValue(bridge),
        ],
        child: MaterialApp(home: LoginScreen(bindMode: bindMode)),
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

  /// 取出主按钮（微信登录 / 注册）当前是否可点。
  ///
  /// 参数 [tester] 测试驱动器。返回 true 表示可点。
  bool submitEnabled(WidgetTester tester) {
    final button = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, '微信登录 / 注册'),
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

    testWidgets('主按钮常开：未勾协议也可点（点击后弹确认框）', (tester) async {
      await pumpLogin(tester);
      // 2026-11-13 口径：灰按钮不说明原因，改为点击后弹窗强制选择。
      expect(submitEnabled(tester), isTrue);
      await unmount(tester);
    });

    testWidgets('登录态不出现手机号 / 验证码入口（2026-11-13 裁定：仅微信）', (tester) async {
      await pumpLogin(tester);
      expect(find.text('请输入手机号'), findsNothing);
      expect(find.text('获取验证码'), findsNothing);
      expect(find.byType(TextField), findsNothing, reason: '登录态不应有手机号/验证码输入框');
      await unmount(tester);
    });

    testWidgets('绑定模式：手机号为空时不能获取验证码', (tester) async {
      await pumpLogin(tester, bindMode: true);
      expect(sendEnabled(tester), isFalse, reason: '空号码发码只会白费一条短信');
      await unmount(tester);
    });

    testWidgets('绑定模式：验证码框在发码前禁用，且提示语说明原因', (tester) async {
      await pumpLogin(tester, bindMode: true);
      final codeField = tester.widget<TextField>(find.byType(TextField).last);
      expect(codeField.enabled, isFalse);
      // 只把框灰掉却不解释，用户会以为是故障。
      expect(find.text('请先获取验证码'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('登录态只呈现微信一种方式：QQ / Apple 不再出现', (tester) async {
      await pumpLogin(tester);
      expect(find.text('QQ'), findsNothing);
      expect(find.text('Apple'), findsNothing);
      expect(find.text('其他登录方式'), findsNothing);
      expect(find.text('微信登录 / 注册'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('固定文案与两处协议链接逐字呈现', (tester) async {
      await pumpLogin(tester);
      expect(find.text('用就近的资源解决本地的需求'), findsOneWidget);
      // 协议名必须单独成文本且带下划线主色，否则会被判为「协议不可见」。
      expect(find.text('我已阅读并同意'), findsOneWidget);
      expect(find.text('《用户协议》'), findsOneWidget);
      expect(find.text('《隐私政策》'), findsOneWidget);
      // 2026-11-13 起去掉「未注册微信账号授权后自动注册」这句无信息量文案。
      expect(find.text('未注册微信账号授权后自动注册'), findsNothing);
      await unmount(tester);
    });
  });

  group('手机号校验驱动发码按钮（仅绑定模式）', () {
    testWidgets('位数不足时仍禁用，满 11 位才放开', (tester) async {
      await pumpLogin(tester, bindMode: true);
      await tester.enterText(find.byType(TextField).first, '1380013');
      await tester.pump();
      expect(sendEnabled(tester), isFalse);

      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      expect(sendEnabled(tester), isTrue);
      await unmount(tester);
    });
  });

  group('发码后（§3.5 步骤 2 的 60s 倒计时，仅绑定模式）', () {
    testWidgets('倒计时接管按钮文案，期间不可重发', (tester) async {
      await pumpLogin(tester, bindMode: true);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      await tester.tap(find.text('获取验证码'));
      await settleAsync(tester);

      expect(find.text('获取验证码'), findsNothing, reason: '冷却中不该还显示可发送文案');
      expect(find.textContaining('s 后重发'), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('给出联调验证码提示条，否则无短信通道时无法自测', (tester) async {
      await pumpLogin(tester, bindMode: true);
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
      await pumpLogin(tester, bindMode: true);
      await tester.enterText(find.byType(TextField).first, '13800138000');
      await tester.pump();
      await tester.tap(find.text('获取验证码'));
      await settleAsync(tester);

      final codeField = tester.widget<TextField>(find.byType(TextField).last);
      expect(codeField.enabled, isTrue);
      await unmount(tester);
    });
  });

  group('协议门（2026-11-13 口径：未勾 → 弹窗强制选择，不可跳过）', () {
    testWidgets('未勾协议点登录 → 弹出确认框，且不拉起微信授权', (tester) async {
      final bridge = _FakeWechatBridge();
      await pumpLogin(tester, bridge: bridge);
      await tester.tap(find.text('微信登录 / 注册'));
      await tester.pumpAndSettle();

      expect(find.text('阅读并同意'), findsOneWidget);
      expect(bridge.calls, 0, reason: '未经同意不得拉起微信授权');
      await unmount(tester);
    });

    testWidgets('弹窗点「不同意」→ 关闭弹窗、协议仍未勾、不发起授权', (tester) async {
      final bridge = _FakeWechatBridge();
      await pumpLogin(tester, bridge: bridge);
      await tester.tap(find.text('微信登录 / 注册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不同意'));
      await tester.pumpAndSettle();

      expect(find.text('阅读并同意'), findsNothing);
      expect(bridge.calls, 0);
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isFalse, reason: '拒绝后不得自动勾选');
      await unmount(tester);
    });

    testWidgets('弹窗点「同意并继续」→ 自动勾选并继续登录', (tester) async {
      final bridge = _FakeWechatBridge();
      await pumpLogin(tester, bridge: bridge);
      await tester.tap(find.text('微信登录 / 注册'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('同意并继续'));
      await settleAsync(tester);

      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isTrue, reason: '同意后勾选框应同步为已勾');
      expect(bridge.calls, 1, reason: '同意后应立即发起微信授权');
      // 假仓库固定回「暂未开放」，用它证明确实走完了登录调用。
      expect(find.text(AuthFailure.wechatUnavailable.message), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('已勾选时点登录 → 不弹窗，直接发起授权', (tester) async {
      final bridge = _FakeWechatBridge();
      await pumpLogin(tester, bridge: bridge);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('微信登录 / 注册'));
      await tester.pump();
      await tester.pump();

      expect(find.text('阅读并同意'), findsNothing);
      expect(bridge.calls, 1);
      await unmount(tester);
    });

    testWidgets('协议行文字可点切换（24px 勾选框低于 44px 触达下限）', (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.text('我已阅读并同意'));
      await tester.pump();
      final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(checkbox.value, isTrue);
      await unmount(tester);
    });
  });

  group('错误提示（常驻横条而非 Toast；手机号提交只在绑定模式）', () {
    testWidgets('绑定失败后横条显示原因，且不会自动消失', (tester) async {
      final repo = _FakeAuthRepository()..bindPhoneFailure = AuthFailure.wrongCode;
      await pumpLogin(tester, repo: repo, bindMode: true);
      await fillPhoneAndCode(tester, code: '000000');
      await tester.tap(find.text('确认绑定'));
      await settleAsync(tester);

      expect(find.text(AuthFailure.wrongCode.message), findsOneWidget);
      // 再推进几秒，横条必须还在 —— 用户要对照它改输入。
      await tester.pump(const Duration(seconds: 3));
      expect(find.text(AuthFailure.wrongCode.message), findsOneWidget);
      await unmount(tester);
    });
  });

  group('微信登录（B2-6a；2026-11-13 起为唯一入口）', () {
    testWidgets('勾协议后微信按钮可点，且页面无其它登录方式', (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();

      expect(submitEnabled(tester), isTrue, reason: '协议已勾 → 微信入口放开');
      expect(find.text('QQ'), findsNothing);
      expect(find.text('Apple'), findsNothing);
      await unmount(tester);
    });

    testWidgets('通道未配置（AppID 未到位）→ 明确提示暂未开放', (tester) async {
      await pumpLogin(tester);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('微信登录 / 注册'));
      await tester.pump();
      await tester.pump();

      expect(find.text(AuthFailure.wechatUnavailable.message), findsOneWidget);
      await unmount(tester);
    });

    testWidgets('用户取消授权 → 不展示错误横幅', (tester) async {
      await pumpLogin(
        tester,
        bridge: _FakeWechatBridge(error: const WechatAuthCanceledException()),
      );
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('微信登录 / 注册'));
      await tester.pump();
      await tester.pump();

      expect(find.text(AuthFailure.wechatUnavailable.message), findsNothing);
      expect(find.text(AuthFailure.networkError.message), findsNothing);
      await unmount(tester);
    });
  });

  group('绑定手机号模式（B2-6a）', () {
    testWidgets('复用登录表单：scene=bind、无协议门、冲突引导切换登录', (tester) async {
      final repo = _FakeAuthRepository()
        ..bindPhoneFailure = AuthFailure.phoneAlreadyRegistered;
      await pumpLogin(tester, repo: repo, bindMode: true);

      expect(find.text('绑定手机号'), findsOneWidget);
      expect(find.text('确认绑定'), findsOneWidget);
      // 绑定前已登录并同意过协议，不再重复弹协议门
      expect(find.byType(Checkbox), findsNothing);

      await fillPhoneAndCode(tester, code: '888888');
      expect(repo.lastScene, 'bind', reason: '绑定模式必须用 scene=bind 下发验证码');

      await tester.tap(find.text('确认绑定'));
      await settleAsync(tester);
      expect(
        find.text(AuthFailure.phoneAlreadyRegistered.message),
        findsOneWidget,
      );
      await unmount(tester);
    });
  });
}
