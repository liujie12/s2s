/// 登录页（PRD §3.4.1，页面 ID：login-screen）。
///
/// 它是三处已有 TODO 的共同前置：列表页收藏、详情页收藏、
/// `contact_repository.dart` 的 [AuthFailure] 兄弟枚举 `ContactFailure.notLoggedIn`。
/// 三处此前都只能显示「请先登录」而无处可跳。
///
/// **§3.4.1 八条要件中本期不做的两条，及原因**：
/// ① **图形验证码**：客户端自绘图形码等于「自己出题自己判卷」，攻击者直接读
///    内存里的答案即可绕过；它必须由服务端生成图片与校验。留位不留假实现 ——
///    假实现会让人以为这道防线已经有了。
/// ② **密码登录折叠区**：§3.4.1 标注它是「次方案」，§12.2 的
///    `/auth/password/login` 同样无服务端。做一个点开后只能报错的折叠区，
///    比暂时不做更糟。
/// 两项均已在说明文档的本轮「不做」清单中写明。
///
/// **协议勾选为什么不预勾**：§3.4.1 明写「默认不勾，必须手动勾」，§3.8 边界表
/// 「协议未勾选 → 登录按钮 Disabled」。这是《个人信息保护法》的单独同意要求，
/// 不是交互偏好 —— 预勾在合规检查中属可判定的违规项。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../design_tokens.dart';
import '../../router/app_router.dart';
import 'auth_repository.dart';

/// 登录 / 注册合并页。
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final TextEditingController _phoneCtrl = TextEditingController();
  final TextEditingController _codeCtrl = TextEditingController();

  /// 协议勾选态。初值 false 且没有任何代码路径会把它改成 true（§3.4.1）。
  bool _agreed = false;

  /// 是否已请求过验证码 —— 决定验证码输入框与主按钮是否可用。
  bool _codeSent = false;

  bool _sending = false;
  bool _submitting = false;

  /// 当前错误提示。null 表示无错误。
  ///
  /// 存字符串而非 [AuthFailure]：风控锁定的文案需要拼上剩余分钟数，
  /// 剩余次数提示也要拼数字，枚举本身给不出这些。
  String? _error;

  /// 60s 重发倒计时剩余秒数，0 表示可发送。
  int _cooldown = 0;
  Timer? _timer;

  @override
  void dispose() {
    // 页面销毁仍在跑的 Timer 会在 setState 时报「已 dispose」，
    // 而这个错只在「点了发送后立刻返回」这条路径出现，手测极易漏过。
    _timer?.cancel();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  /// 发送短信验证码（§12.2 `/auth/sms/send`）。
  ///
  /// 成功后启动 60s 倒计时（§3.5 步骤 2）。倒计时的真源在仓库侧，
  /// 这里每秒向它取剩余值而非自己减 —— 自己减的话，返回重进本页即可清零。
  Future<void> _sendCode() async {
    final phone = _phoneCtrl.text.trim();
    setState(() {
      _sending = true;
      _error = null;
    });

    final repo = ref.read(authRepositoryProvider);
    final failure = await repo.sendCode(phone);
    if (!mounted) return;

    setState(() {
      _sending = false;
      if (failure != null) {
        _error = failure.message;
        return;
      }
      _codeSent = true;
      _cooldown = repo.resendCooldownLeft(phone).inSeconds;
    });
    if (failure == null) _startCountdown(phone);
  }

  /// 启动每秒回读仓库冷却值的定时器。
  ///
  /// 参数 [phone] 用于向仓库查询该号码的剩余冷却。
  void _startCountdown(String phone) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = ref.read(authRepositoryProvider).resendCooldownLeft(phone);
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _cooldown = left.inSeconds);
      if (left == Duration.zero) timer.cancel();
    });
  }

  /// 提交验证码登录（§12.2 `/auth/sms/login`，注册合并）。
  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });

    final result = await ref.read(authRepositoryProvider).loginWithSms(
      phone: _phoneCtrl.text.trim(),
      code: _codeCtrl.text.trim(),
      agreementAccepted: _agreed,
    );
    if (!mounted) return;

    if (result.isSuccess) {
      ref.read(authSessionProvider.notifier).signIn(result.session!);
      setState(() => _submitting = false);
      // 用 pop 而非 go(home)：登录多半是从收藏/联系按钮弹上来的，
      // 跳首页会让用户丢失原本正在看的那条信息，还得自己找回去。
      final router = GoRouter.of(context);
      if (router.canPop()) {
        router.pop(true);
      } else {
        router.go(AppRoutes.home);
      }
      return;
    }

    setState(() {
      _submitting = false;
      _error = _errorTextOf(result);
    });
  }

  /// 把失败结果转成给用户看的一句话。
  ///
  /// 锁定态拼上剩余分钟数、可重试态拼上剩余次数 —— 只说「操作过于频繁」
  /// 会让用户不停重试（每次都撞在同一堵墙上），只说「验证码不正确」
  /// 则会让人在第 5 次时毫无预警地被锁。
  String _errorTextOf(AuthResult result) {
    final failure = result.failure!;
    if (failure == AuthFailure.lockedOut) {
      final until = result.lockedUntil;
      if (until == null) return failure.message;
      final minutes = until.difference(DateTime.now()).inMinutes + 1;
      return '${failure.message}，请在 $minutes 分钟后重试';
    }
    if (failure == AuthFailure.wrongCode && result.remainingAttempts <= 2) {
      return '${failure.message}（还剩 ${result.remainingAttempts} 次机会）';
    }
    return failure.message;
  }

  /// 主按钮是否可点（§3.8「协议未勾选 → 登录按钮 Disabled」）。
  bool get _canSubmit =>
      _agreed &&
      _codeSent &&
      !_submitting &&
      AuthRepository.isValidPhone(_phoneCtrl.text.trim()) &&
      _codeCtrl.text.trim().length >= 4;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(AppColors.background),
      appBar: AppBar(
        backgroundColor: const Color(AppColors.background),
        elevation: 0,
        // 登录页可关闭（与隐私门相反）：§3.8 明确未登录可只读浏览，
        // 把登录做成不可退出的门等于把「先注册后登录」换了个位置又装回来。
        leading: IconButton(
          icon: const Icon(Icons.close, color: Color(AppColors.textSecondary)),
          tooltip: '关闭',
          onPressed: () {
            final router = GoRouter.of(context);
            router.canPop() ? router.pop() : router.go(AppRoutes.home);
          },
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppSpacing.lg),
              const _BrandHeader(),
              const SizedBox(height: AppSpacing.xxl),
              _PhoneField(
                controller: _phoneCtrl,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              _CodeField(
                controller: _codeCtrl,
                enabled: _codeSent,
                sending: _sending,
                cooldown: _cooldown,
                canSend:
                    !_sending &&
                    _cooldown == 0 &&
                    AuthRepository.isValidPhone(_phoneCtrl.text.trim()),
                onSend: _sendCode,
                onChanged: (_) => setState(() {}),
              ),
              // kDebugMode 编译期包裹（规范 §5.9 第①层）：release 下整块
              // 死代码消除，提示条与 debugCode 引用均不进产物（L3 双零兜底）。
              if (kDebugMode && _codeSent) ...[
                const SizedBox(height: AppSpacing.sm),
                // 联调提示条：没有短信通道时，不给出这条提示就无法自测登录。
                // 文案里写明「联调」，避免被误认为正式功能。
                Text(
                  '联调阶段验证码固定为 ${AuthRepository.debugCode}（接短信服务后移除）',
                  style: TextStyle(
                    fontSize: AppTypeScale.caption.size,
                    height: AppTypeScale.caption.lineHeight,
                    color: const Color(AppColors.textPlaceholder),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: AppSpacing.md),
                _ErrorBanner(message: _error!),
              ],
              const SizedBox(height: AppSpacing.lg),
              _AgreementRow(
                agreed: _agreed,
                onChanged: (v) => setState(() => _agreed = v),
              ),
              const SizedBox(height: AppSpacing.lg),
              _SubmitButton(
                enabled: _canSubmit,
                busy: _submitting,
                onPressed: _submit,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                // §3.4.1 底部文案，逐字照抄。
                '未注册手机号验证后自动注册',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  height: AppTypeScale.small.lineHeight,
                  color: const Color(AppColors.textSecondary),
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              const _ThirdPartyRow(),
              const SizedBox(height: AppSpacing.xl),
            ],
          ),
        ),
      ),
    );
  }
}

/// 品牌区：Logo + 品牌名 + slogan（§3.4.1 顶部）。
///
/// **Logo 为几何占位而非 SVG**：鸭子 IP 的 12 个 SVG 落在
/// `prototype-figma/assets/`（§1.7），但工程尚未配置 `flutter/assets`，
/// 也未引入 `flutter_svg`。为了一个装饰位引入渲染依赖属超出本轮范围；
/// 占位保留了尺寸与位置，接入资产时只换这一个组件。
/// TODO(M4-4)：配置 assets 并替换为 `duck-logo.svg`。
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            color: Color(AppColors.primaryLight),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: const Icon(
            // 用「就近搜寻」语义的图标而非鸭子表情符：§1 要求 emoji 一律
            // 换矢量或纯文字，emoji 在不同系统上字形与基线都不一致。
            Icons.travel_explore,
            size: 36,
            color: Color(AppColors.primary),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '找鸭找',
          style: TextStyle(
            fontSize: AppTypeScale.h1.size,
            height: AppTypeScale.h1.lineHeight,
            fontWeight: FontWeight.w700,
            color: const Color(AppColors.textPrimary),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          // §3.4.1 slogan，逐字照抄。
          '用就近的资源解决本地的需求',
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            height: AppTypeScale.body.lineHeight,
            color: const Color(AppColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// 手机号输入框（§3.4.1「手机号（唯一主标识）」）。
class _PhoneField extends StatelessWidget {
  const _PhoneField({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      keyboardType: TextInputType.phone,
      // 限长 11 位并只收数字：从输入侧挡住非法值，比事后报错少一次往返。
      // 但仓库侧仍然校验（见 AuthRepository.isValidPhone）—— UI 约束不是安全边界。
      maxLength: 11,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: _inputDecoration(
        hint: '请输入手机号',
        icon: Icons.phone_iphone,
      ).copyWith(counterText: ''),
    );
  }
}

/// 验证码输入框 + 获取按钮（§3.5 步骤 2 的 60s 倒计时）。
class _CodeField extends StatelessWidget {
  const _CodeField({
    required this.controller,
    required this.enabled,
    required this.sending,
    required this.cooldown,
    required this.canSend,
    required this.onSend,
    required this.onChanged,
  });

  final TextEditingController controller;
  final bool enabled;
  final bool sending;
  final int cooldown;
  final bool canSend;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            onChanged: onChanged,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: _inputDecoration(
              // 未发送时提示语说明「为什么不能填」，而不是只把框灰掉 ——
              // 灰掉的框不解释原因，用户会以为是故障。
              hint: enabled ? '请输入验证码' : '请先获取验证码',
              icon: Icons.sms_outlined,
            ).copyWith(counterText: ''),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        SizedBox(
          // 固定宽度：倒计时文字长度在「获取验证码」与「59s」之间跳变，
          // 不定宽会让输入框宽度随秒数抖动。
          width: 108,
          height: 48,
          child: OutlinedButton(
            onPressed: canSend ? onSend : null,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(AppColors.primary),
              side: const BorderSide(color: Color(AppColors.primary)),
              padding: EdgeInsets.zero,
            ),
            child: Text(
              sending
                  ? '发送中'
                  : cooldown > 0
                  ? '${cooldown}s 后重发'
                  : '获取验证码',
              style: TextStyle(fontSize: AppTypeScale.small.size),
            ),
          ),
        ),
      ],
    );
  }
}

/// 错误提示条。
///
/// 用常驻横条而非 Toast/SnackBar：验证码类错误需要用户对照着改输入，
/// 而 Toast 会在他抬头看输入框时消失。
class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: const Color(AppColors.error).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline,
            size: 18,
            // 用 errorText 而非 error：后者压在浅底上仅约 3.7:1，不过 AA。
            color: Color(AppColors.errorText),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                height: AppTypeScale.small.lineHeight,
                color: const Color(AppColors.errorText),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 协议勾选行（§3.4.1「默认不勾，必须手动勾」）。
class _AgreementRow extends StatelessWidget {
  const _AgreementRow({required this.agreed, required this.onChanged});

  final bool agreed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: Checkbox(
            value: agreed,
            onChanged: (v) => onChanged(v ?? false),
            activeColor: const Color(AppColors.primary),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          // 整行文字可点切换：24px 的勾选框低于 44px 触达下限，
          // 只让方框可点会让手指偏一点就点不中。
          child: GestureDetector(
            onTap: () => onChanged(!agreed),
            child: Text(
              // §3.4.1 文案，逐字照抄。
              '我同意用户协议与隐私政策',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                height: AppTypeScale.small.lineHeight,
                color: const Color(AppColors.textSecondary),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 主按钮：主色胶囊 80% 宽（§3.4.1 末条）。
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({
    required this.enabled,
    required this.busy,
    required this.onPressed,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FractionallySizedBox(
        // §3.4.1 明写 80% 宽。写成 0.8 而非某个像素值：这是相对宽度，
        // 折算成固定值会在不同屏宽下偏离设计意图。
        widthFactor: 0.8,
        child: ElevatedButton(
          onPressed: enabled && !busy ? onPressed : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(AppColors.primary),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(AppColors.border),
            disabledForegroundColor: const Color(AppColors.textPlaceholder),
            minimumSize: const Size.fromHeight(48),
            shape: const StadiumBorder(),
          ),
          child: busy
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              // §3.4.1 按钮文案「登录 / 注册」—— 两者合并正是这一页的产品意图。
              : const Text('登录 / 注册'),
        ),
      ),
    );
  }
}

/// 第三方入口（§3.4.1「本期不实现，灰禁用」）。
///
/// 灰禁用而非隐藏：§3.4.1 明确要求呈现出来。隐藏掉会让「本期不实现」
/// 这个决定在验收时无从确认 —— 看不见的东西无法判断是漏做还是刻意不做。
class _ThirdPartyRow extends StatelessWidget {
  const _ThirdPartyRow();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '其他登录方式（本期未开放）',
          style: TextStyle(
            fontSize: AppTypeScale.caption.size,
            color: const Color(AppColors.textPlaceholder),
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final label in ['微信', 'QQ', 'Apple'])
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                ),
                child: OutlinedButton(
                  // onPressed: null 即禁用态，由框架给出灰化与不可点。
                  onPressed: null,
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(AppColors.border)),
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(fontSize: AppTypeScale.small.size),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// 输入框统一装饰（§1 设计系统：R-md 圆角 + md 间距）。
///
/// 参数 [hint] 占位文案；[icon] 前缀图标。
/// 返回统一风格的 [InputDecoration]，避免各输入框各写一套边框。
InputDecoration _inputDecoration({required String hint, required IconData icon}) {
  const border = OutlineInputBorder(
    borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
    borderSide: BorderSide(color: Color(AppColors.border)),
  );
  return InputDecoration(
    hintText: hint,
    hintStyle: const TextStyle(color: Color(AppColors.textPlaceholder)),
    prefixIcon: Icon(icon, size: 20, color: const Color(AppColors.textSecondary)),
    filled: true,
    fillColor: const Color(AppColors.surface),
    contentPadding: const EdgeInsets.symmetric(
      horizontal: AppSpacing.md,
      vertical: AppSpacing.md,
    ),
    border: border,
    enabledBorder: border,
    disabledBorder: border,
    focusedBorder: const OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppRadius.md)),
      borderSide: BorderSide(color: Color(AppColors.primary), width: 1.5),
    ),
  );
}
