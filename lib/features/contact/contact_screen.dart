/// 联系中转页（PRD §7.4.2 S7 永久单轨中转页 / §7.7 反爬 / §7.8 边界）。
///
/// **为什么要有这一页，而不是详情页直接拨号**：§7.4.2 的核心是「号码中间 4 位
/// 脱敏，拨出/复制时才显示完整」。若详情页直拨，完整号码就必须提前下发到客户端，
/// §7.7「完整号码不写入前端初始状态」当场失效 —— 这一页存在的理由不是多一步
/// 确认，而是让「拉取完整值」成为一个可限频、可埋点、可熔断的独立动作。
///
/// **S7 单轨的三个「不做」（§7.4.2，是产品定论不是本期取舍）**：
/// ① 不分层：所有用户无门槛、无 DAU 触发，统一走这一页；
/// ② 不做 IM SDK、不做站内文本聊天、不做付费中转通道；
/// ③ 不做双卡片并列 —— 发布时只填一种联系方式，这里只显示那一种。
///
/// **[128] 接线后的三项已接真实服务端**（原先的「本期不做」已兑现）：
/// ① 三维限频与熔断（§7.7 账号 30 / 设备 30 / IP 100 每日 + 1min≥10 熔断）在服务端；
/// ② 联系事件落库（§7.7 北极星指标唯一统计点）随成功响应一并完成；
/// ③ 举报提交走 `POST /posts/{id}/report`。
///
/// **数据源（[128] 代码评审 #2 修复）**：详情取自 [postDetailProvider]（真接口
/// `GET /posts/{id}`），不再读 mock 的 `listingDetailProvider`——后者与真接口是两套
/// id 体系，命中 mock 的 id 会渲染 mock 派生的号码并对真实数据里不存在的 id 发请求，
/// 未命中的真实 id 则只渲染「找不到」，页面在真实数据上根本走不通。
///
/// **渠道与脱敏号码在拉取前不可知（契约所限，登记见说明文档 §2.9 DEC-13）**：
/// 契约 `PostDetail` 不返回 `contact_channel`，且 `contact_mask` 恒 null
/// （详情不解密是红线，2026-09-26 用户确认）。故未拉取态**不显示任何渠道名与号码字形**，
/// 按钮文案保持中性；渠道、完整值、剩余次数一律由 `/contact` 的成功结果驱动。
/// 写死一个渠道或照稿画一串 `138 **** 8888`，等于替服务端许诺它没给过的值。
///
/// **剩余次数文案纪律（契约 `ContactInfo.remaining_today` 原文）**：服务端限频有四个
/// 维度，该字段只反映账号维一个，故文案写「今日剩余 N 次（以实际请求结果为准）」，
/// 禁用「还可查看 N 次」式的承诺写法；且收到 `42902` 后**立即把本地剩余刷 0** ——
/// 否则「还剩 3 次」与「已达上限」会同时出现在屏幕上。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/network/api_error_code.dart';
import '../../core/network/api_exception.dart';
import '../../design_tokens.dart';
import '../../domain/listing_detail.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import '../detail/post_detail_provider.dart';
import 'contact_repository.dart';
import 'report_reason.dart';

class ContactScreen extends ConsumerStatefulWidget {
  const ContactScreen({super.key, required this.listingId});

  /// 帖子 ID（`int`，契约 `PostIdPath` 为 `int64`，详细设计 §10.4.3）。
  final int listingId;

  @override
  ConsumerState<ContactScreen> createState() => _ContactScreenState();
}

class _ContactScreenState extends ConsumerState<ContactScreen> {
  /// 已拉取到的完整联系方式。null 表示尚未拉取或拉取失败。
  ///
  /// **只放在 State 里，不进 Provider**：Provider 会被缓存并跨页面存活，
  /// 那会让「点击时才拉取」退化为「拉过一次就一直持有」（见 [FullContact.value]）。
  /// 放 State 意味着退出本页即释放。
  FullContact? _full;

  bool _loading = false;

  /// 拉取失败原因。与 [_full] 互斥，但不合并成一个联合类型 ——
  /// 加载中时两者都为 null，是第三种状态。
  ContactFailure? _failure;

  /// 今日剩余可查看次数（仅账号维度，服务端 `remaining_today`）。
  ///
  /// null 表示「本次会话尚未成功拉取过」，此时不显示该行 —— 显示一个
  /// 凭空猜的次数等于向用户承诺一个服务端没给过的值。
  int? _remainingToday;

  @override
  Widget build(BuildContext context) {
    // 详情走真接口（[128] 代码评审 #2），三态与详情页同一分流口径。
    return ref
        .watch(postDetailProvider(widget.listingId))
        .when(
          loading: () => const _LoadingScreen(),
          error: (error, _) => _buildErrorScreen(error),
          data: (detail) => _buildPage(detail),
        );
  }

  /// 组装正文（三态中的 data 态）。
  ///
  /// 参数：[detail] 真接口映射后的详情域模型。本页只用它的发布者昵称 ——
  /// 渠道与联系方式一律以 `/contact` 结果为准（见文件头「渠道与脱敏号码」一节）。
  Widget _buildPage(ListingDetail detail) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: Text(
          // §7.4.2 标题栏是「联系 王师傅」而非「联系中转」：
          // 用户此刻关心的是在联系谁，不是这个页面叫什么。
          '联系 ${detail.publisher.nickname}',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.xl),
        children: [
          const _PrivacyNotice(),
          _ContactCard(
            full: _full,
            loading: _loading,
            failure: _failure,
            remainingToday: _remainingToday,
            onReveal: _reveal,
            onUse: _useContact,
            // 登录成功后自动重试拉取：让用户回到中转页还要再点一次按钮，
            // 等于把「他刚才已经表达过的意图」丢掉了。
            onLogin: _goLoginThenReveal,
          ),
          const _SafetyTip(),
          _ReportEntry(onTap: _openReportSheet),
        ],
      ),
    );
  }

  /// 错误态分流：`41001` → 「该信息已下架或不存在」，其余 → 可重试的加载失败。
  ///
  /// 必须先经 [asApiException] 归一（与 `detail_screen._buildErrorScreen` 同因）：
  /// 信封业务错误在链上以 `DioException(error: ApiException)` 形态到达，
  /// 直接判 `error is ApiException` 恒为 false，41001 会落到通用错误屏。
  Widget _buildErrorScreen(Object error) {
    final apiError = asApiException(error);
    if (apiError.code == ApiErrorCode.postGone) {
      return const _ContactNotFoundScreen();
    }
    return const _LoadFailedScreen();
  }

  /// 拉取完整联系方式（§12.3 `GET /posts/{id}/contact`）。
  ///
  /// 失败不抛给上层：这一页的失败都是可预期的业务状态（超限、未登录、
  /// 帖子已下架），全部转成页面内提示。让它冒泡成崩溃是把业务规则当成故障。
  ///
  /// **已移除「对方未留联系方式」的本地短路**（[128] 代码评审 #2）：它原先读的是
  /// mock 派生的 `contactMasked`，既与真接口是两套数据，也会把「真帖但 mock 里没有」
  /// 一律判成「未留」。且 Batch1 该边界本就不可达 —— 发布时 `contact_type` /
  /// `contact_value` 必填、`post` 三个联系方式列 NOT NULL，不存在没留联系方式的帖子。
  /// 若日后服务端补出该情形的错误码，应由 `/contact` 的结果驱动并在
  /// [contactFailureOf] 里接上 `ContactFailure.noContact`（§2.9 DEC-14）。
  ///
  /// **收到 `42902` 时把本地剩余刷 0**（契约 `remaining_today` 的硬要求）：
  /// 该字段只反映账号维，用户完全可能显示「还剩 3 次」而因设备维被拒；
  /// 不刷 0 就会出现「还剩 3 次」与「已达上限」同屏自相矛盾。
  Future<void> _reveal() async {
    // §7.7「仅登录用户可拉取完整号码」的前置判定。
    // 放在页面而非仓库：仓库扮演的是服务端，服务端只会返回 401，
    // 而「弹登录页」是客户端的职责。真实实现中两侧都要判 ——
    // 客户端判是为了少一次注定失败的请求，服务端判才是那道真正的门。
    if (!ref.read(isLoggedInProvider)) {
      setState(() {
        _failure = ContactFailure.notLoggedIn;
        _loading = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _failure = null;
    });

    try {
      final full = await ref
          .read(contactRepositoryProvider)
          .fetchFullContact(postId: widget.listingId);
      if (!mounted) return;
      setState(() {
        _full = full;
        // 剩余次数以服务端返回值为准（在日限计数之后读取，已含本次消耗）
        _remainingToday = full.remainingToday;
        _loading = false;
      });
    } on ContactException catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = e.failure;
        if (e.failure == ContactFailure.rateLimited) {
          // 契约硬要求：42902 一律把本地剩余刷 0（且不解释是哪个维度超限）
          _remainingToday = 0;
        }
        _loading = false;
      });
    }
  }

  /// 跳登录页，登录成功后自动重试拉取。
  ///
  /// 登录页返回 true 表示登录成功（见 `login_screen.dart` 的 `pop(true)`）；
  /// 用户直接关掉登录页时返回 null，此时不重试 —— 他刚刚放弃了这个动作。
  Future<void> _goLoginThenReveal() async {
    final ok = await GoRouter.of(context).push<bool>(AppRoutes.login);
    if (!mounted || ok != true) return;
    await _reveal();
  }

  /// 使用已拉取到的联系方式：手机号外呼，微信号复制。
  ///
  /// §7.8：「点外呼失败（模拟器/Pad 无拨号能力）自动降级为复制手机号到剪贴板」。
  /// **降级必须是自动的而不是弹个错误**：用户的目标是联系上对方，
  /// 报错等于把「换个办法」的责任推回给用户，而他手上已经没有别的办法了。
  Future<void> _useContact() async {
    final full = _full;
    if (full == null) return;

    if (full.callable) {
      final uri = Uri(scheme: 'tel', path: full.value);
      // canLaunchUrl 先探测：模拟器与平板无拨号能力，直接 launch 会抛异常，
      // 而异常发生在跳转过程中，此时已无法安静地降级。
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
        return;
      }
      await _copy(full.value, hint: '本机不支持拨号，号码已复制');
      return;
    }

    // 微信号：复制后由用户自行粘贴搜索（§7.5 旅程第 5 步）。
    // **不做「直接跳微信搜索」**：微信不提供带参搜索的 scheme，
    // 能跳的只是打开微信首页，用户还得自己找搜索框再粘贴 —— 多一次跳转、
    // 少一次可见的复制反馈，反而更难用。
    await _copy(full.value, hint: '微信号已复制，去微信搜索添加');
  }

  Future<void> _copy(String value, {required String hint}) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(hint)));
  }

  /// 举报原因面板（§7.7 五个原因 / §9.10.3 风险分累计）。
  ///
  /// 提交走 `POST /posts/{id}/report`。**面板里的原因文案与契约值都取自
  /// [ReportReason]**（唯一落点）：面板显示中文、提交发契约值，
  /// 两处若各存一份，改一个词就会让提交的原因与运营配置的权重表对不上。
  void _openReportSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Color(AppColors.surface),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheetContext) => _ReportSheet(
        onSubmit: (reason) async {
          Navigator.of(sheetContext).pop();
          await _submitReport(reason);
        },
      ),
    );
  }

  /// 提交举报并按结果提示（§7.8「提交后 24 小时内处理」）。
  ///
  /// 失败不静默：举报是用户主动发起的维权动作，悄悄失败等于让他以为
  /// 已经举报成功、坐等处理。每种失败都按服务端语义给对应文案
  /// （熔断 42903 / 已下架 41001 与网络异常三者对用户的意义不同）。
  ///
  /// @param reason 用户选择的原因（枚举值同时携带中文文案与契约值）
  Future<void> _submitReport(ReportReason reason) async {
    try {
      await ref
          .read(contactRepositoryProvider)
          .submitReport(widget.listingId, reason: reason);
      if (!mounted) return;
      // 文案照 §7.8：「已受理，24h 内处理」。
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已受理，24h 内处理')),
      );
    } on ContactException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.failure.message)),
      );
    }
  }
}

/// 隐私保护说明区（PRD §7.4.2 顶部）。
///
/// **放在最上面而不是折叠起来**：这一页要求用户交出「我联系了谁」这个行为记录，
/// 说明放在号码下方或折叠态，等于在用户已经做完动作之后才告知。
class _PrivacyNotice extends StatelessWidget {
  const _PrivacyNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Color(AppColors.primaryLight),
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 18,
                color: Color(AppColors.primaryDark),
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '隐私保护说明',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  fontWeight: FontWeight.w600,
                  color: Color(AppColors.primaryDark),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            '为保护双方隐私，平台提供联系方式中转：',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              height: 1.5,
              color: Color(AppColors.textSecondary),
            ),
          ),
          const _NoticeItem('本次联系会记录在双方「联系记录」中'),
          const _NoticeItem('对方回复后可互加联系方式'),
        ],
      ),
    );
  }
}

class _NoticeItem extends StatelessWidget {
  const _NoticeItem(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '· ',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                height: 1.5,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 联系方式卡片（PRD §7.4.2 中部，仅展示发布时填写的那一种）。
///
/// **渠道与号码字形只在 [full] 非空后出现**：契约 `PostDetail` 不返回
/// `contact_channel`、`contact_mask` 恒 null，故未拉取态显示中性渠道名与占位文案
/// （§2.9 DEC-13）。这不影响 §7.4.2「不做双卡片并列」——发布时只填一种，
/// 拉取后这里也只呈现那一种。
class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.full,
    required this.loading,
    required this.failure,
    required this.remainingToday,
    required this.onReveal,
    required this.onUse,
    required this.onLogin,
  });

  final FullContact? full;
  final bool loading;
  final ContactFailure? failure;

  /// 今日剩余次数（仅账号维度）；null = 本次会话还没拿到服务端值。
  final int? remainingToday;

  final VoidCallback onReveal;
  final VoidCallback onUse;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final revealed = full != null;
    // 渠道未知时为 null —— 用它驱动图标与渠道名，而不是猜一个默认值。
    final channel = full?.channel;
    final isPhone = channel == ContactChannel.phone;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                // 未拉取 → 中性「查看」图标；拉取后按服务端渠道切换。
                // 猜一个默认渠道会让微信号帖子显示电话图标（用户按拨号去理解）。
                switch (channel) {
                  ContactChannel.phone => Icons.phone_outlined,
                  ContactChannel.wechat => Icons.chat_bubble_outline,
                  null => Icons.visibility_outlined,
                },
                size: 20,
                color: Color(AppColors.primary),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${channel?.label ?? '联系方式'}：',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
              Expanded(
                child: Text(
                  // 未拉取 → 占位文案，不显示任何号码字形：脱敏值在 Batch1 无契约来源
                  // （详情不解密是红线），画一串 `138 **** 8888` 会与真实号码对不上；
                  // 留空则与「加载失败」无从区分（§7.4.2 稿面对此有明确取舍：宁可说清
                  // 「要点一下才给」，也不给假字形）。
                  full?.value ?? '点击下方按钮查看',
                  style: TextStyle(
                    fontSize: AppTypeScale.h3.size,
                    fontWeight: FontWeight.w700,
                    // 完整号码用主色强调：它是这一页唯一的目标产物。
                    color: Color(
                      revealed ? AppColors.primary : AppColors.textPrimary,
                    ),
                    // 等宽数字：脱敏与完整两态切换时数字不会左右跳动。
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
          if (!revealed) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              '（点击下方按钮，查看完整联系方式）',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: Color(AppColors.textPlaceholder),
              ),
            ),
          ],
          if (failure != null) ...[
            const SizedBox(height: AppSpacing.md),
            _FailureBanner(failure: failure!, onLogin: onLogin),
          ],
          const SizedBox(height: AppSpacing.lg),
          _ActionButton(
            revealed: revealed,
            loading: loading,
            isPhone: isPhone,
            onReveal: onReveal,
            onUse: onUse,
          ),
          if (remainingToday != null) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              // 文案纪律（契约 `remaining_today` 原文）：只反映账号维一个维度，
              // 故必须带「以实际请求结果为准」，不用承诺式写法——
              // 后者在设备维/熔断维度先超限时会当场自我否定。
              '今日剩余 $remainingToday 次（以实际请求结果为准）',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: Color(AppColors.textPlaceholder),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 主行动按钮：未拉取 → 查看完整值；已拉取 → 拨打 / 复制。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.revealed,
    required this.loading,
    required this.isPhone,
    required this.onReveal,
    required this.onUse,
  });

  final bool revealed;
  final bool loading;

  /// 渠道是否手机号。**只在 [revealed] 为真时有意义** —— 未拉取时渠道未知
  /// （契约不返回 `contact_channel`），调用方传 false，且不参与未拉取态文案。
  final bool isPhone;

  final VoidCallback onReveal;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    // §7.8「对方联系方式未填 → 主按钮禁用」在 Batch1 不可达（发布必填、DDL NOT NULL），
    // 故不设该前置禁用；真正的门在服务端（未登录 40101 / 限频 429 / 下架 41001），
    // 由 `_reveal` 把它们翻成页面内提示。禁用而非隐藏的老做法（怕用户以为没加载完）
    // 在「禁用条件已不存在」后只剩副作用：正常帖子会显示成一个点不动的按钮。
    final enabled = !loading;

    final label = switch ((revealed, isPhone)) {
      // 未拉取 → 中性文案：此时不知道是手机号还是微信号，写「号码」对微信号帖是错的。
      (false, _) => '查看完整联系方式',
      (true, true) => '拨打电话',
      (true, false) => '复制微信号',
    };

    return SizedBox(
      width: double.infinity,
      height: 48,
      child: FilledButton.icon(
        onPressed: enabled ? (revealed ? onUse : onReveal) : null,
        style: FilledButton.styleFrom(
          backgroundColor: Color(AppColors.primary),
          disabledBackgroundColor: Color(AppColors.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
        ),
        icon: loading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Icon(_iconFor(revealed: revealed, isPhone: isPhone), size: 18),
        label: Text(
          loading ? '获取中…' : label,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  IconData _iconFor({required bool revealed, required bool isPhone}) {
    if (!revealed) return Icons.visibility_outlined;
    return isPhone ? Icons.phone : Icons.copy_outlined;
  }
}

/// 失败提示条（§7.8 / §12.3 错误码文案）。
class _FailureBanner extends StatelessWidget {
  const _FailureBanner({required this.failure, required this.onLogin});

  final ContactFailure failure;

  /// 跳登录页。仅未登录态用得到。
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Color(AppColors.error).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                size: 16,
                color: Color(AppColors.errorText),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  failure.message,
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    height: 1.45,
                    color: Color(AppColors.errorText),
                  ),
                ),
              ),
            ],
          ),
          // 未登录是唯一「用户当场就能解决」的失败态，必须给出去处。
          // 超限与熔断给按钮反而有害 —— 点了也没用，只会让人反复点。
          if (failure == ContactFailure.notLoggedIn)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onLogin,
                style: TextButton.styleFrom(
                  foregroundColor: Color(AppColors.primary),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                  ),
                ),
                child: Text(
                  '去登录',
                  style: TextStyle(fontSize: AppTypeScale.small.size),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 温馨提示（PRD §7.4.2 底部）。
///
/// 用 warning 而非 error 配色：这是善意提醒，不是错误。
/// 用 error 色会让用户以为这条信息本身有问题。
class _SafetyTip extends StatelessWidget {
  const _SafetyTip();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Color(AppColors.warning).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 16,
            color: Color(AppColors.warningText),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '温馨提示：建议白天联系，交易请走线下当面确认。',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                height: 1.45,
                color: Color(AppColors.warningText),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 举报入口（PRD §7.4.2 底部「举报本次发布」）。
class _ReportEntry extends StatelessWidget {
  const _ReportEntry({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: TextButton.icon(
        onPressed: onTap,
        // 不用 Danger 按钮（§2.6 规定 Danger 用于删除/退出登录）：
        // 举报是低频的辅助动作，做成醒目红按钮会与主行动按钮抢注意力，
        // 也会暗示「这条信息可疑」。
        style: TextButton.styleFrom(
          foregroundColor: Color(AppColors.textSecondary),
        ),
        icon: const Icon(Icons.flag_outlined, size: 16),
        label: Text(
          '举报本次发布',
          style: TextStyle(fontSize: AppTypeScale.small.size),
        ),
      ),
    );
  }
}

/// 举报原因选择面板（§7.7 五个原因）。
///
/// 原因清单直接由 [ReportReason] 驱动（`values` 遍历）：面板上的中文与提交用的
/// 契约值同源，不存在「面板加了第六项但提交映射没跟」的错位。
class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.onSubmit});

  /// 提交回调：参数为用户选中的原因（枚举值，同时携带中文文案与契约值）。
  final ValueChanged<ReportReason> onSubmit;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  ReportReason? _selected;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '举报原因',
              style: TextStyle(
                fontSize: AppTypeScale.h3.size,
                fontWeight: FontWeight.w600,
                color: Color(AppColors.textPrimary),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ...ReportReason.values.map(
              (r) => RadioListTile<ReportReason>(
                value: r,
                // ignore: deprecated_member_use
                groupValue: _selected,
                // ignore: deprecated_member_use
                onChanged: (v) => setState(() => _selected = v),
                title: Text(
                  r.label,
                  style: TextStyle(fontSize: AppTypeScale.body.size),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: Color(AppColors.primary),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: FilledButton(
                // 未选原因不可提交：无原因的举报无法进入 §9.10.3 的权重计算。
                onPressed: _selected == null
                    ? null
                    : () => widget.onSubmit(_selected!),
                style: FilledButton.styleFrom(
                  backgroundColor: Color(AppColors.primary),
                  disabledBackgroundColor: Color(AppColors.border),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.full),
                  ),
                ),
                child: const Text('提交举报'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 加载态（详情接口首次拉取中）。
///
/// 联系中转页也必须先经详情接口：标题栏要显示「联系 王师傅」，
/// 而昵称只有详情返回（§7.4.2 稿图），不能先渲染一个占位标题再改。
class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: const Text('联系'),
      ),
      body: const Center(child: CircularProgressIndicator()),
    );
  }
}

/// 加载失败（非 `41001`：网络失败 / 游客详情限频 `42907` / 服务端错误）。
///
/// 与「已下架/不存在」分开：前者是「等一下再来」，后者是「这条信息没了」——
/// 给用户同一个屏会让他在已经不存在的信息上反复重试。
class _LoadFailedScreen extends StatelessWidget {
  const _LoadFailedScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: const Text('联系'),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 48,
              color: Color(AppColors.textPlaceholder),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              '加载失败，请稍后重试',
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 信息不存在（已下架或 id 无效）。
class _ContactNotFoundScreen extends StatelessWidget {
  const _ContactNotFoundScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(AppColors.background),
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: Color(AppColors.surface),
        elevation: 0,
        title: Text(
          '联系',
          style: TextStyle(
            fontSize: AppTypeScale.h3.size,
            fontWeight: FontWeight.w600,
            color: Color(AppColors.textPrimary),
          ),
        ),
      ),
      body: Center(
        child: Text(
          '该信息已下架或不存在',
          style: TextStyle(
            fontSize: AppTypeScale.body.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
      ),
    );
  }
}
