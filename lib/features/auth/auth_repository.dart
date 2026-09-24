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

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../core/storage/token_storage.dart';

/// 重新发送验证码的冷却时长（§3.5 步骤 2「发送短信 → 60s 倒计时」）。
const Duration kSmsResendCooldown = Duration(seconds: 60);

/// 同一手机号连续校验失败达此次数即锁定（§3.8 / §12.2 登录风控）。
const int kMaxFailedAttempts = 5;

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

  /// 序列化为可持久化的 JSON（键名与字段语义对齐，非 openapi 信封）。
  ///
  /// 用于 Token 持久化（KTD7）：冷启动恢复会话需要全部字段——
  /// [token] 供 API 鉴权、[userId]/[phone] 供个人中心展示、
  /// [isNewUser]/[realNameVerified] 供首进引导与权限展示。只存
  /// token + expireAt 的话，重启后 userId/phone 丢失，个人中心无法显示
  /// 本人号码（完整号码只在登录时输入过，服务端只回脱敏 phone_mask）。
  ///
  /// 返回：[Map<String, dynamic>] 会话 JSON。
  Map<String, dynamic> toJson() => {
        'user_id': userId,
        'phone': phone,
        'token': token,
        'expire_at': expireAt.toIso8601String(),
        'is_new_user': isNewUser,
        'real_name_verified': realNameVerified,
      };

  /// 从持久化 JSON 反序列化会话。
  ///
  /// 参数：[json] 由 [toJson] 产出的会话 JSON。
  /// 返回：[AuthSession] 会话实例。
  /// 抛出：[ApiException.parse] 字段缺失/类型不符时（不静默吞，§10.3）。
  static AuthSession fromJson(Map<String, dynamic> json) {
    final userId = json['user_id'];
    final phone = json['phone'];
    final token = json['token'];
    final expireAtRaw = json['expire_at'];
    if (userId is! String || phone is! String || token is! String) {
      throw ApiException.parse(
        '会话 JSON 缺 user_id/phone/token 或类型不符: $json',
      );
    }
    final expireAt = DateTime.tryParse(expireAtRaw is String ? expireAtRaw : '');
    if (expireAt == null) {
      throw ApiException.parse('会话 JSON expire_at 非时间: $expireAtRaw');
    }
    return AuthSession(
      userId: userId,
      phone: phone,
      token: token,
      expireAt: expireAt,
      isNewUser: json['is_new_user'] as bool? ?? false,
      realNameVerified: json['real_name_verified'] as bool? ?? false,
    );
  }
}

/// 鉴权仓库（§12.2 `/auth/sms/send` 与 `/auth/sms/login` 的真网络实现）。
///
/// 接后端后（U10）删除本地验证码生成/校验 mock，改为经 [Dio] 调真接口：
///   - 验证码生成与校验在服务端，客户端永不持有正确验证码；
///   - 失败原因由服务端错误码映射（§12.1 错误码表），本层不吞信封；
///   - 本地仅保留「60s 重发冷却」的计时状态（[kSmsResendCooldown]），
///     用于页面倒计时展示，服务端侧另有更细的限频（42905）。
///
/// 仍须单实例（见 [authRepositoryProvider]）：60s 冷却的计时存在实例字段里，
/// 每次读 Provider 新建会把冷却清零。
class AuthRepository {
  /// 构造鉴权仓库，注入业务网络客户端。
  ///
  /// 参数：[dio] 经 [buildNetworkDio] 装配的业务 dio（[dioProvider] 注入；
  ///   测试注入 [NetworkChainHarness] 装配的同款实例）。
  AuthRepository(this._dio);

  /// 业务网络客户端（生产同款五拦截器链）。
  final Dio _dio;

  /// 各手机号最近一次成功发码时刻（本地 60s 冷却计时，非服务端真源）。
  final Map<String, DateTime> _lastSentAt = {};

  /// 手机号格式校验（11 位、1[3-9] 开头，对齐契约 pattern）。
  ///
  /// 不做运营商号段白名单：号段年年新增，写死会把持有新号段的真实用户挡在门外，
  /// 而这类问题上线后极难被发现（用户装不上就走了，不会来报错）。
  static bool isValidPhone(String phone) =>
      RegExp(r'^1[3-9]\d{9}$').hasMatch(phone);

  /// 联调固定验证码（与后端 `SmsCodePolicy.DEBUG_CODE` 对齐）。
  ///
  /// 只用于 debug 提示条（login_screen 内 `kDebugMode` 包裹），客户端**不参与**
  /// 验证码生成/校验。release 下提示条被树摇，字面量不进产物。
  static const String debugCode = '888888';

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

    try {
      await _dio.post<Object?>(
        '/auth/sms/send',
        data: {'phone': phone, 'scene': 'login'},
      );
      _lastSentAt[phone] = at;
      return null;
    } catch (e) {
      return _mapSendFailure(e);
    }
  }

  /// 验证码登录（§12.2 `POST /auth/sms/login`，注册合并）。
  ///
  /// 参数 [phone] 手机号；[code] 用户输入的验证码；
  /// [agreementAccepted] 协议是否已勾（§12.2 必 true）；[now] 当前时刻。
  /// 返回 [AuthResult]：成功携 [AuthSession]，失败携具名原因。
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

    try {
      final response = await _dio.post<Object?>(
        '/auth/sms/login',
        data: {
          'phone': phone,
          'code': code,
          'agreed': agreementAccepted,
          'platform': _platformName,
        },
      );
      final session = _parseLoginResult(response.data, phone);
      _lastSentAt.remove(phone);
      return AuthResult.success(session);
    } catch (e) {
      return _mapLoginFailure(e, at);
    }
  }

  /// 距下次可重发验证码的剩余时长。返回 [Duration.zero] 表示可立即发送。
  ///
  /// 供页面驱动 60s 倒计时。倒计时的**计时真源在这里而不在页面**：
  /// 放在页面的话，用户退出重进登录页就能刷新倒计时，冷却被绕过。
  Duration resendCooldownLeft(String phone, {DateTime? now}) {
    final sentAt = _lastSentAt[phone];
    if (sentAt == null) return Duration.zero;
    final elapsed = (now ?? DateTime.now()).difference(sentAt);
    final left = kSmsResendCooldown - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// 客户端平台名（契约 `platform` 枚举：android / ios）。
  ///
  /// 用 [defaultTargetPlatform] 而非 `dart:io Platform`：纯 Dart 仓库层不
  /// 依赖平台通道，测试无需 mock 平台通道即可固定判定。
  String get _platformName =>
      defaultTargetPlatform == TargetPlatform.android ? 'android' : 'ios';

  /// 把发送验证码的异常映射为失败原因（发码只区分「限频」与「其他」）。
  ///
  /// 参数：[error] catch 到的异常（DioException 包 ApiException 或裸 ApiException）。
  /// 返回：[AuthFailure] 限频 → resendTooSoon，其余 → networkError。
  AuthFailure _mapSendFailure(Object error) {
    final api = _asApiException(error);
    if (api.code == ApiErrorCode.smsLimit) return AuthFailure.resendTooSoon;
    return AuthFailure.networkError;
  }

  /// 把登录异常映射为失败结果（§12.1 错误码 → [AuthFailure]）。
  ///
  /// 参数：[error] catch 到的异常；[at] 锁定截止的基准时刻。
  /// 返回：[AuthResult] 锁定 → lockedOut（拼 lockedUntil）、限频 → resendTooSoon、
  ///   协议 → agreementNotAccepted、其余（含 40001 验证码错误）→ wrongCode。
  AuthResult _mapLoginFailure(Object error, DateTime at) {
    final api = _asApiException(error);
    switch (api.code) {
      case ApiErrorCode.loginLocked:
        final retryAfter = api.retryAfterSec;
        return AuthResult.failure(
          AuthFailure.lockedOut,
          remainingAttempts: 0,
          lockedUntil: retryAfter == null
              ? null
              : at.add(Duration(seconds: retryAfter)),
        );
      case ApiErrorCode.smsLimit:
        return const AuthResult.failure(AuthFailure.resendTooSoon);
      case ApiErrorCode.agreementRequired:
        return const AuthResult.failure(AuthFailure.agreementNotAccepted);
      default:
        // 40001（验证码错误/过期统一，服务端不区分）、网络失败等兜底为
        // wrongCode —— 页面据此引导「重输」；验证码过期由用户重新获取。
        return const AuthResult.failure(AuthFailure.wrongCode);
    }
  }

  /// 解析登录响应为会话（§12.2 LoginResult：token/expire_at/is_new_user/user）。
  ///
  /// 参数：[data] EnvelopeInterceptor 拆出的信封 data（LoginResult）；[phone] 用户
  ///   输入的完整手机号（服务端只回脱敏 phone_mask，完整号只能取输入值）。
  /// 返回：[AuthSession] 会话。
  /// 抛出：[ApiException.parse] 字段缺失/类型不符时（不静默吞，§10.3）。
  AuthSession _parseLoginResult(Object? data, String phone) {
    if (data is! Map) {
      throw ApiException.parse(
        '登录响应 data 应为 Map，实际: ${data.runtimeType}',
      );
    }
    final token = data['token'];
    final expireAtRaw = data['expire_at'];
    final isNewUser = data['is_new_user'];
    if (token is! String || token.isEmpty) {
      throw ApiException.parse('登录响应 data.token 缺失或非 String: $token');
    }
    final expireAt = DateTime.tryParse(expireAtRaw is String ? expireAtRaw : '');
    if (expireAt == null) {
      throw ApiException.parse('登录响应 data.expire_at 非时间: $expireAtRaw');
    }
    if (isNewUser is! bool) {
      throw ApiException.parse('登录响应 data.is_new_user 缺失: $isNewUser');
    }
    return AuthSession(
      userId: _parseUserId(data['user']),
      phone: phone,
      token: token,
      expireAt: expireAt,
      isNewUser: isNewUser,
    );
  }

  /// 从 LoginResult.user（MyProfile）取 userId（int64 → String）。
  ///
  /// 参数：[user] 登录响应 data.user（MyProfile）。
  /// 返回：[String] 用户 ID 的字符串形式（int64 不丢精度）。
  /// 抛出：[ApiException.parse] user 非 Map 或 id 缺失。
  String _parseUserId(Object? user) {
    if (user is! Map) {
      throw ApiException.parse('登录响应 data.user 应为 Map，实际: $user');
    }
    final id = user['id'];
    if (id is! num) {
      throw ApiException.parse('登录响应 data.user.id 缺失或非数值: $id');
    }
    return id.toString();
  }

  /// 归一链上异常为 [ApiException]（§11.3 两形态 + 传输层归一）。
  ///
  /// 参数：[error] catch 到的对象。
  /// 返回：[ApiException] 业务异常；传输层/未知异常归一为 networkFailure。
  ApiException _asApiException(Object error) {
    if (error is ApiException) return error;
    if (error is DioException) {
      final inner = error.error;
      if (inner is ApiException) return inner;
      return ApiException(
        code: ApiErrorCode.networkFailure,
        message: error.message ?? '网络异常',
      );
    }
    return ApiException(
      code: ApiErrorCode.networkFailure,
      message: '$error',
    );
  }
}

/// 鉴权仓库 Provider。
///
/// 全局单实例：60s 冷却计时存在实例内（见 [AuthRepository] 类注释）。
final authRepositoryProvider = Provider<AuthRepository>(
  (ref) => AuthRepository(ref.watch(dioProvider)),
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
  AuthSession? build() {
    _load();
    return null;
  }

  /// 读当前会话代次（经 NetworkHooks.readSessionEpoch 焊接给 core）。
  ///
  /// 返回：[int] 单调递增代次；会话存否均可读，登出态也有确定值。
  int get sessionEpoch => _sessionEpoch;

  /// 冷启动异步恢复会话（KTD7：Token 持久化 → 重启仍保持登录态）。
  ///
  /// build 返回 null（未登录）后异步读安全存储，命中则把 [state] 置为
  /// 恢复出的会话。读盘/解析失败一律视为未登录（不抛出、不清除损坏值，
  /// 下次覆盖即可），避免坏数据把用户挡在登录页外。
  Future<void> _load() async {
    try {
      final json = await ref.read(tokenStorageProvider).read();
      if (json == null) return;
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return;
      state = AuthSession.fromJson(decoded);
    } catch (_) {
      // 损坏/不可读的持久化：静默降级为未登录。
    }
  }

  /// 登录成功后写入会话并推进代次，同时落盘（KTD7）。
  ///
  /// 参数：[session] 新登录会话。
  /// 返回：void；同一账号重复登录同样视为新会话（代次 +1），使任何
  ///   在途的旧续期结果因代次不符而被丢弃。
  void signIn(AuthSession session) {
    _sessionEpoch += 1;
    state = session;
    _persist(session);
  }

  /// 续期成功后写回新 Token（单 Token 模型，契约 `/auth/token/refresh`）。
  ///
  /// 与 [signIn] 的区别：续期不推进代次、不更换 userId/phone 等会话身份
  /// 字段，只轮换 Token 与到期时刻；新 Token 同样落盘（KTD7）。
  ///
  /// 参数：
  ///   [token]    续期响应的新 JWT（`data.token`）；
  ///   [expireAt] 续期响应的新到期时刻（`data.expire_at`）。
  /// 返回：void；当前无会话（续期在途期间已登出）时**拒绝写回**——
  ///   这是代次校验之外的第二道防线，避免旧会话被续期结果复活。
  void updateToken({required String token, required DateTime expireAt}) {
    final current = state;
    if (current == null) return;
    final next = AuthSession(
      userId: current.userId,
      phone: current.phone,
      token: token,
      expireAt: expireAt,
      isNewUser: current.isNewUser,
      realNameVerified: current.realNameVerified,
    );
    state = next;
    _persist(next);
  }

  /// 退出登录（§3.4.2 个人中心的退出按钮）并推进代次，同时清除持久化。
  ///
  /// 本期由 UI 侧调用（登录页/个人中心）；服务端 `POST /auth/logout` 的
  /// 调用点与失败处置见 plan U7（后端已实现），前端登出时先清本地会话。
  void signOut() {
    _sessionEpoch += 1;
    state = null;
    ref.read(tokenStorageProvider).clear();
  }

  /// 落盘会话（KTD7：token 持久化）。
  ///
  /// 参数：[session] 待持久化的会话。
  /// 返回：void；落盘失败不阻塞内存态（下次 signIn/updateToken 会再写）。
  void _persist(AuthSession session) {
    ref.read(tokenStorageProvider).save(jsonEncode(session.toJson()));
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
