/// 登录会话（PRD §3.4.1 登录页 / §3.7 会话 Token / §3.8 边界 / §12.2 鉴权接口）。
///
/// **为什么先做会话再做页面**：`contact_repository.dart:23` 的
/// [ContactFailure.notLoggedIn]、列表页与详情页的收藏按钮，三处都已在等一个
/// 「当前是否登录」的答案，此前各自留 TODO。会话是这三处的共同前置，
/// 而登录页只是它的一个入口。
///
/// **本文件模拟的是服务端而非本地逻辑**（同 `contact_repository.dart` 的取向）：
/// §12.2 的 `/auth/sms/send` 与 `/auth/sms/login` 都在服务端，验证码由服务端
/// 生成与校验。因此这里必须表现为「会失败、会被风控锁、有网络耗时」的远程调用，
/// 而不是一个本地比对字符串的函数。接后端时只替换 [AuthRepository] 的两个方法，
/// 页面侧的倒计时、错误态、按钮禁用逻辑都不用改。
///
/// **失败为什么建成枚举而不是返回 null 或 bool**：§3.8 边界表把「5 次失败锁定
/// 15 分钟」「协议未勾选按钮 Disabled」列为两条独立规则，§12.2 给了独立错误码
/// `40105`。只回答「登录成功没有」的话，页面无从区分「验证码错了，可以再试」
/// 与「已被锁 15 分钟，再试也没用」—— 而后者若说成前者，用户会一直重试到放弃。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 短信验证码有效期（§12.2 `/auth/sms/send` 出参 `expire_in`）。
///
/// 与 [kSmsResendCooldown] 是两件事：冷却是「多久能再发一条」（§3.5 步骤 2 的
/// 60s 倒计时），有效期是「这条码多久作废」。合成一个值会导致倒计时结束的同时
/// 码也失效，用户按 §3.5 的节奏操作反而永远登录不上。
const Duration kSmsCodeTtl = Duration(minutes: 5);

/// 重新发送验证码的冷却时长（§3.5 步骤 2「发送短信 → 60s 倒计时」）。
const Duration kSmsResendCooldown = Duration(seconds: 60);

/// 同一手机号连续校验失败达此次数即锁定（§3.8 / §12.2 登录风控）。
const int kMaxFailedAttempts = 5;

/// 风控锁定时长（§12.2「返回 `40105` 并锁定 15 分钟」）。
const Duration kLockoutDuration = Duration(minutes: 15);

/// 登录失败原因（文案与原因绑定，避免同一错误在不同页面说法不一）。
enum AuthFailure {
  /// 手机号格式非法。客户端可判，不必往服务端跑一趟。
  invalidPhone('请输入 11 位手机号'),

  /// 协议未勾选（§3.8「协议未勾选 → 登录按钮 Disabled」）。
  ///
  /// 按钮已禁用却仍保留这个失败态：§12.2 的 `agreement_accepted` 是**必 true**
  /// 的入参，服务端也会校验。只靠禁用按钮等于把合规校验放在最容易被绕过的一侧。
  agreementNotAccepted('请先勾选并同意用户协议与隐私政策'),

  /// 验证码错误，仍可重试（剩余次数见 [AuthResult.remainingAttempts]）。
  wrongCode('验证码不正确，请重新输入'),

  /// 验证码已过期（超过 [kSmsCodeTtl]）。
  ///
  /// 与 [wrongCode] 分开：过期该引导「重新获取」，输错该引导「再输一次」。
  /// 文案混用会让用户反复输一个已经作废的码。
  codeExpired('验证码已过期，请重新获取'),

  /// 尚未请求过验证码就点了登录。
  codeNotRequested('请先获取短信验证码'),

  /// 风控锁定（§12.2 错误码 `40105`）。
  ///
  /// 文案里的剩余分钟数由页面按 [AuthResult.lockedUntil] 拼接 ——
  /// 写死「15 分钟」会在用户等了 10 分钟后再试时仍显示 15 分钟。
  lockedOut('操作过于频繁，账号已临时锁定'),

  /// 发送验证码时仍在冷却期内（§3.5 的 60s）。
  resendTooSoon('请稍后再获取验证码'),

  /// 网络或服务端异常。
  networkError('网络异常，请稍后重试');

  const AuthFailure(this.message);

  /// 面向用户的提示文案。
  final String message;
}

/// 一次鉴权调用的结果。
///
/// 用「成功/失败共用一个结果对象」而不是抛异常：登录失败是这一页的**主要流程
/// 之一**（输错验证码极常见），不是异常。且失败时要一并带回「还剩几次」与
/// 「锁到什么时候」这类页面必须展示的数据，异常里挂载这些字段会更别扭。
class AuthResult {
  const AuthResult.success(this.session)
    : failure = null,
      remainingAttempts = kMaxFailedAttempts,
      lockedUntil = null;

  const AuthResult.failure(
    AuthFailure this.failure, {
    this.remainingAttempts = kMaxFailedAttempts,
    this.lockedUntil,
  }) : session = null;

  /// 成功时的会话，失败为 null。
  final AuthSession? session;

  /// 失败原因，成功为 null。
  final AuthFailure? failure;

  /// 锁定前还剩几次机会（§3.8 5 次）。
  ///
  /// 剩 2 次及以内时页面应当提示 —— 直接被锁而事前毫无预警，用户会以为是故障。
  final int remainingAttempts;

  /// 锁定截止时刻，未锁定为 null。
  final DateTime? lockedUntil;

  bool get isSuccess => session != null;
}

/// 已登录会话（§3.7「JWT / 自有 Token，有效期 30 天，自动续期」）。
class AuthSession {
  const AuthSession({
    required this.userId,
    required this.phone,
    required this.token,
    required this.expireAt,
    required this.isNewUser,
    this.realNameVerified = false,
  });

  final String userId;

  /// 手机号（§3.4.1「唯一主标识」）。
  ///
  /// 存完整值：这是**本人**的号码，个人中心要显示、改绑要用。§3.7 的脱敏
  /// 规则针对的是「别人的联系方式」，两件事不要混。
  final String phone;

  /// 会话 Token。
  final String token;

  /// Token 过期时刻（§3.7 有效期 30 天）。
  ///
  /// 存绝对时刻而非「剩余天数」：应用可能在后台挂很久，剩余天数一旦算出就在变旧。
  final DateTime expireAt;

  /// 是否本次验证码登录顺带完成注册（§12.2 出参 `is_new_user`）。
  ///
  /// §3.5 步骤 4「首进首页 → 弹完善资料与认证抽屉」的触发条件就是它。
  final bool isNewUser;

  /// 是否已实名（§3.7 基础实名权限两档）。
  ///
  /// 未实名不是「未登录」：§3.8 明确未实名仍可登录、可发受限态帖子。
  /// 两者合成一个 bool 会让「登录了但没实名」这一大类用户无处可归。
  final bool realNameVerified;

  /// Token 是否已过期。
  ///
  /// 参数 [now] 由调用方注入而非内部取 `DateTime.now()`：便于测试固定输入，
  /// 也避免同一帧内两次调用得到不同答案。
  bool isExpired(DateTime now) => !now.isBefore(expireAt);
}

/// 鉴权仓库（§12.2 `/auth/sms/send` 与 `/auth/sms/login` 的本地替身）。
///
/// **状态存在实例字段里，因此它必须是单实例**（见 [authRepositoryProvider]）：
/// 待校验的验证码与失败计数在真实系统里存于服务端，这里只能存在内存。
/// 若每次读 Provider 都新建一个，失败计数会被重置，风控形同虚设。
class AuthRepository {
  AuthRepository();

  /// 已下发但未使用的验证码，按手机号索引。
  ///
  /// **明文存内存仅因为这里在扮演服务端**：真实客户端永远不该知道正确的验证码。
  /// 这也是为什么校验逻辑放在本类而不是页面里 —— 页面若能拿到正确答案，
  /// 「验证码」这道门就只是一个装饰。
  final Map<String, _PendingCode> _pending = {};

  /// 连续失败计数与锁定截止，按手机号索引（§3.8 风控维度是 phone）。
  final Map<String, _RiskState> _risk = {};

  /// 手机号格式校验（11 位、1 开头）。
  ///
  /// 不做运营商号段白名单：号段年年新增，写死会把持有新号段的真实用户挡在门外，
  /// 而这类问题上线后极难被发现（用户装不上就走了，不会来报错）。
  static bool isValidPhone(String phone) =>
      RegExp(r'^1\d{10}$').hasMatch(phone);

  /// 发送短信验证码（§12.2 `POST /auth/sms/send`）。
  ///
  /// 参数 [phone] 手机号；[now] 当前时刻（注入以便测试）。
  /// 返回失败原因，**null 表示已发送成功**。
  ///
  /// 不复用 [AuthResult]：发码不产生会话，硬塞进那个类型会出现
  /// 「成功了但 session 是 null」的结果，而 [AuthResult.isSuccess] 正是靠
  /// session 判定的 —— 那样每个调用点都得记住「发码这里别看 isSuccess」。
  Future<AuthFailure?> sendCode(String phone, {DateTime? now}) async {
    final at = now ?? DateTime.now();

    if (!isValidPhone(phone)) return AuthFailure.invalidPhone;

    // 锁定期内连发码都不给：只拦登录不拦发码的话，攻击者仍能持续消耗短信费用，
    // 而短信是按条计费的真实成本。
    if (_lockedUntil(phone, at) != null) return AuthFailure.lockedOut;

    final prev = _pending[phone];
    if (prev != null && at.difference(prev.sentAt) < kSmsResendCooldown) {
      return AuthFailure.resendTooSoon;
    }

    // 模拟网络往返：按钮点下去到倒计时开始之间若无反馈，用户会连点，
    // 而连点在真实环境下每次都是一条计费短信。
    await Future<void>.delayed(const Duration(milliseconds: 400));

    _pending[phone] = _PendingCode(
      // 固定码仅用于本地联调（真实码由服务端生成后经短信下发，客户端不可知）。
      // TODO(接后端)：删除本地生成，改为只记录 expire_in。
      // kDebugMode 编译期包裹（规范 §5.9 第①层）：release 折叠为 ''，常量
      // 因无引用被树摇，产物 grep 不到固定码（出包 L3 双零兜底）。
      code: kDebugMode ? _debugCode : '',
      sentAt: at,
    );
    return null;
  }

  /// 验证码登录（§12.2 `POST /auth/sms/login`，注册合并）。
  ///
  /// 参数 [phone] 手机号；[code] 用户输入的验证码；
  /// [agreementAccepted] 协议是否已勾（§12.2 必 true）；[now] 当前时刻。
  /// 返回 [AuthResult]：成功携 [AuthSession]，失败携具名原因与剩余次数。
  Future<AuthResult> loginWithSms({
    required String phone,
    required String code,
    required bool agreementAccepted,
    DateTime? now,
  }) async {
    final at = now ?? DateTime.now();

    if (!isValidPhone(phone)) {
      return const AuthResult.failure(AuthFailure.invalidPhone);
    }
    if (!agreementAccepted) {
      return const AuthResult.failure(AuthFailure.agreementNotAccepted);
    }

    final locked = _lockedUntil(phone, at);
    if (locked != null) {
      return AuthResult.failure(AuthFailure.lockedOut, lockedUntil: locked);
    }

    final pending = _pending[phone];
    if (pending == null) {
      return const AuthResult.failure(AuthFailure.codeNotRequested);
    }
    if (at.difference(pending.sentAt) >= kSmsCodeTtl) {
      // 过期码即刻废弃，避免它一直占着「已请求过」的位置。
      _pending.remove(phone);
      return const AuthResult.failure(AuthFailure.codeExpired);
    }

    await Future<void>.delayed(const Duration(milliseconds: 500));

    if (code != pending.code) {
      final risk = _recordFailure(phone, at);
      if (risk.lockedUntil != null) {
        return AuthResult.failure(
          AuthFailure.lockedOut,
          remainingAttempts: 0,
          lockedUntil: risk.lockedUntil,
        );
      }
      return AuthResult.failure(
        AuthFailure.wrongCode,
        remainingAttempts: kMaxFailedAttempts - risk.failedCount,
      );
    }

    // 成功即清空该号码的失败计数与待校验码：
    // 不清计数会让「昨天输错 4 次、今天成功登录」的用户在下次输错一次时直接被锁。
    _risk.remove(phone);
    _pending.remove(phone);

    // 「未注册手机号验证后自动注册」（§3.4.1 底部文案）：
    // 首次见到的号码即视为新用户。真实实现由服务端返回 `is_new_user`。
    final isNew = !_knownPhones.contains(phone);
    _knownPhones.add(phone);

    return AuthResult.success(
      AuthSession(
        userId: 'user-${phone.substring(phone.length - 4)}',
        phone: phone,
        token: 'local-token-${at.millisecondsSinceEpoch}',
        // §3.7 有效期 30 天。
        expireAt: at.add(const Duration(days: 30)),
        isNewUser: isNew,
      ),
    );
  }

  /// 距下次可重发验证码的剩余时长。返回 [Duration.zero] 表示可立即发送。
  ///
  /// 供页面驱动 60s 倒计时。倒计时的**真源在这里而不在页面**：
  /// 放在页面的话，用户退出重进登录页就能刷新倒计时，冷却被绕过。
  Duration resendCooldownLeft(String phone, {DateTime? now}) {
    final pending = _pending[phone];
    if (pending == null) return Duration.zero;
    final elapsed = (now ?? DateTime.now()).difference(pending.sentAt);
    final left = kSmsResendCooldown - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// 当前锁定截止时刻，未锁定返回 null（顺带清理已到期的锁）。
  DateTime? _lockedUntil(String phone, DateTime now) {
    final risk = _risk[phone];
    final until = risk?.lockedUntil;
    if (until == null) return null;
    if (!now.isBefore(until)) {
      // 锁已到期：连同失败计数一起清零，否则解锁后第一次输错就又被锁。
      _risk.remove(phone);
      return null;
    }
    return until;
  }

  /// 记一次失败，达阈值则置锁。返回更新后的风控状态。
  _RiskState _recordFailure(String phone, DateTime now) {
    final count = (_risk[phone]?.failedCount ?? 0) + 1;
    final state = _RiskState(
      failedCount: count,
      lockedUntil: count >= kMaxFailedAttempts
          ? now.add(kLockoutDuration)
          : null,
    );
    _risk[phone] = state;
    return state;
  }

  /// 已注册过的号码（仅样例，用于给出 `is_new_user`）。
  final Set<String> _knownPhones = {};

  /// 本地联调用固定验证码。
  ///
  /// 之所以是固定值而非随机：随机码在无短信通道时根本取不到，登录页就无法自测。
  /// 之所以定义为常量而非散落在代码里：接后端时删掉它，所有引用处立刻编译报错，
  /// 不会有一条漏网的本地后门留在包里。
  /// 引用点均已 `kDebugMode` 包裹（规范 §5.9 第①层）：release 下本常量无引用
  /// 被树摇，字面量不进产物；**新增引用点必须同样包裹**，否则出包 L3 双零中止。
  static const String _debugCode = '888888';

  /// 暴露给测试与登录页提示条使用的联调码。
  static String get debugCode => _debugCode;
}

/// 待校验的验证码。
class _PendingCode {
  const _PendingCode({required this.code, required this.sentAt});

  final String code;
  final DateTime sentAt;
}

/// 单个手机号的风控状态。
class _RiskState {
  const _RiskState({required this.failedCount, this.lockedUntil});

  final int failedCount;
  final DateTime? lockedUntil;
}

/// 鉴权仓库 Provider。
///
/// 全局单实例：失败计数与待校验码存在实例内（见 [AuthRepository] 类注释）。
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(),
);

/// 当前会话状态。
///
/// 值为 null 表示未登录。用可空而非单独的 `isLoggedIn` 布尔：
/// 两个字段能表达出「已登录但会话为空」这种不该存在的组合，而组合一旦可表达，
/// 就一定会有某条分支忘了同步其中一个。
///
/// **会话代次（[sessionEpoch]，计划 KTD5/R10）**：单调递增整数，每次
/// 登录/登出 +1，续期写回（[updateToken]）**不**递增——续期是同一会话的
/// Token 轮换。AuthRefreshInterceptor 在续期发起时取样、写回前比对：
/// 在途续期期间用户登出/换号会使代次不一致，续期结果被丢弃，避免
/// 「已登出的旧会话被续期结果复活」竞态。
class AuthSessionNotifier extends Notifier<AuthSession?> {
  /// 当前会话代次（初值 0 表示从未建立过会话；每次 signIn/signOut 递增）。
  int _sessionEpoch = 0;

  @override
  AuthSession? build() => null;

  /// 读当前会话代次（经 NetworkHooks.readSessionEpoch 焊接给 core）。
  ///
  /// 返回：[int] 单调递增代次；会话存否均可读，登出态也有确定值。
  int get sessionEpoch => _sessionEpoch;

  /// 登录成功后写入会话并推进代次。
  ///
  /// 参数：[session] 新登录会话。
  /// 返回：void；同一账号重复登录同样视为新会话（代次 +1），使任何
  ///   在途的旧续期结果因代次不符而被丢弃。
  void signIn(AuthSession session) {
    _sessionEpoch += 1;
    state = session;
  }

  /// 续期成功后写回新 Token（单 Token 模型，契约 `/auth/token/refresh`）。
  ///
  /// 与 [signIn] 的区别：续期不推进代次、不更换 userId/phone 等会话身份
  /// 字段，只轮换 Token 与到期时刻。
  ///
  /// 参数：
  ///   [token]    续期响应的新 JWT（`data.token`）；
  ///   [expireAt] 续期响应的新到期时刻（`data.expire_at`）。
  /// 返回：void；当前无会话（续期在途期间已登出）时**拒绝写回**——
  ///   这是代次校验之外的第二道防线，避免旧会话被续期结果复活。
  void updateToken({required String token, required DateTime expireAt}) {
    final current = state;
    if (current == null) return;
    state = AuthSession(
      userId: current.userId,
      phone: current.phone,
      token: token,
      expireAt: expireAt,
      isNewUser: current.isNewUser,
      realNameVerified: current.realNameVerified,
    );
  }

  /// 退出登录（§3.4.2 个人中心的退出按钮）并推进代次。
  ///
  /// 本期只清内存：会话未落盘，故无需清持久化。
  /// TODO(接后端)：调 §12.2 `POST /auth/logout` 并清除持久化 Token。
  void signOut() {
    _sessionEpoch += 1;
    state = null;
  }
}

/// 会话 Provider。
final authSessionProvider = NotifierProvider<AuthSessionNotifier, AuthSession?>(
  AuthSessionNotifier.new,
);

/// 是否已登录（供收藏、联系等入口做前置判断）。
///
/// 单独提一个 Provider 而不让各页自己判 `!= null`：登录态的判定条件日后会变
/// （例如加上「Token 未过期」），判定散落各处时必然改漏。
final isLoggedInProvider = Provider<bool>(
  (ref) => ref.watch(authSessionProvider) != null,
);
