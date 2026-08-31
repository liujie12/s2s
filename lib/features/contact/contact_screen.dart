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
/// **本期不做的三项（依赖服务端，做了必返工）**：
/// ① **真实三维限频**（§7.7 账号 30 / 设备 30 / IP 100 每日）：计数必须在
///    服务端，客户端计数可被清数据绕过。这里只把超限与熔断建成可展示的错误态
///    （见 [ContactFailure]），让文案与排版能被验收；
/// ② **联系事件落库**（§7.7 北极星指标唯一统计点）：需 `contact_event` 表；
/// ③ **举报提交**（§9.10.3 风险分累计）：原因选择面板做出来，提交动作留 TODO。
///    面板必须做 —— §7.8「对方联系方式未填」的提示文案是「尝试举报让其补充」，
///    不做面板，那条提示就指向一个不存在的入口。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../design_tokens.dart';
import '../../domain/listing_detail.dart';
import '../../router/app_router.dart';
import '../auth/auth_repository.dart';
import '../detail/listing_detail_repository.dart';
import 'contact_repository.dart';

class ContactScreen extends ConsumerStatefulWidget {
  const ContactScreen({super.key, required this.listingId});

  final String listingId;

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

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(listingDetailProvider(widget.listingId));

    if (detail == null) {
      return const _ContactNotFoundScreen();
    }

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
            detail: detail,
            full: _full,
            loading: _loading,
            failure: _failure,
            onReveal: () => _reveal(detail),
            onUse: () => _useContact(detail),
            // 登录成功后自动重试拉取：让用户回到中转页还要再点一次按钮，
            // 等于把「他刚才已经表达过的意图」丢掉了。
            onLogin: () => _goLoginThenReveal(detail),
          ),
          const _SafetyTip(),
          _ReportEntry(onTap: () => _openReportSheet(detail)),
        ],
      ),
    );
  }

  /// 拉取完整联系方式（§12.3 `POST /posts/{id}/contact`）。
  ///
  /// 失败不抛给上层：这一页的失败都是可预期的业务状态（超限、未登录、
  /// 对方未填），全部转成页面内提示。让它冒泡成崩溃是把业务规则当成故障。
  Future<void> _reveal(ListingDetail detail) async {
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
          .fetchFullContact(postId: widget.listingId, detail: detail);
      if (!mounted) return;
      setState(() {
        _full = full;
        _loading = false;
      });
    } on ContactException catch (e) {
      if (!mounted) return;
      setState(() {
        _failure = e.failure;
        _loading = false;
      });
    }
  }

  /// 跳登录页，登录成功后自动重试拉取。
  ///
  /// 参数 [detail] 用于登录回来后继续拉这一条的联系方式。
  /// 登录页返回 true 表示登录成功（见 `login_screen.dart` 的 `pop(true)`）；
  /// 用户直接关掉登录页时返回 null，此时不重试 —— 他刚刚放弃了这个动作。
  Future<void> _goLoginThenReveal(ListingDetail detail) async {
    final ok = await GoRouter.of(context).push<bool>(AppRoutes.login);
    if (!mounted || ok != true) return;
    await _reveal(detail);
  }

  /// 使用已拉取到的联系方式：手机号外呼，微信号复制。
  ///
  /// §7.8：「点外呼失败（模拟器/Pad 无拨号能力）自动降级为复制手机号到剪贴板」。
  /// **降级必须是自动的而不是弹个错误**：用户的目标是联系上对方，
  /// 报错等于把「换个办法」的责任推回给用户，而他手上已经没有别的办法了。
  Future<void> _useContact(ListingDetail detail) async {
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
  void _openReportSheet(ListingDetail detail) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Color(AppColors.surface),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (sheetContext) => _ReportSheet(
        onSubmit: (reason) {
          Navigator.of(sheetContext).pop();
          // TODO(接后端): 调 §12.3 `POST /posts/{id}/report` 提交举报，
          // 进入 §9.10.3 风险分累计。当前仅回显受理提示以验证交互闭环。
          ScaffoldMessenger.of(context).showSnackBar(
            // 文案照 §7.8：「已受理，24h 内处理」。
            const SnackBar(content: Text('已受理，24h 内处理')),
          );
        },
      ),
    );
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
class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.detail,
    required this.full,
    required this.loading,
    required this.failure,
    required this.onReveal,
    required this.onUse,
    required this.onLogin,
  });

  final ListingDetail detail;
  final FullContact? full;
  final bool loading;
  final ContactFailure? failure;
  final VoidCallback onReveal;
  final VoidCallback onUse;
  final VoidCallback onLogin;

  @override
  Widget build(BuildContext context) {
    final isPhone = detail.contactChannel == ContactChannel.phone;
    final revealed = full != null;

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
                isPhone ? Icons.phone_outlined : Icons.chat_bubble_outline,
                size: 20,
                color: Color(AppColors.primary),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${detail.contactChannel.label}：',
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
              Expanded(
                child: Text(
                  // 未填 → 明确说「未留」，不要显示空白（空白与加载失败无从区分）。
                  full?.value ?? detail.contactMasked ?? '未留联系方式',
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
          if (!revealed && detail.hasContact) ...[
            const SizedBox(height: AppSpacing.xs),
            Text(
              isPhone ? '（点击下方按钮，查看完整号码并拨打）' : '（点击下方按钮，查看完整微信号）',
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
            detail: detail,
            revealed: revealed,
            loading: loading,
            isPhone: isPhone,
            onReveal: onReveal,
            onUse: onUse,
          ),
        ],
      ),
    );
  }
}

/// 主行动按钮：未拉取 → 查看完整值；已拉取 → 拨打 / 复制。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.detail,
    required this.revealed,
    required this.loading,
    required this.isPhone,
    required this.onReveal,
    required this.onUse,
  });

  final ListingDetail detail;
  final bool revealed;
  final bool loading;
  final bool isPhone;
  final VoidCallback onReveal;
  final VoidCallback onUse;

  @override
  Widget build(BuildContext context) {
    // §7.8：对方联系方式未填 → 主按钮禁用。
    // 禁用而非隐藏：按钮消失会让用户以为页面没加载完，禁用态配合下方
    // 举报入口才能表达「这条信息缺东西，你可以让他补」。
    final enabled = detail.hasContact && !loading;

    final label = switch ((detail.hasContact, revealed, isPhone)) {
      (false, _, _) => '对方未留联系方式',
      (true, false, true) => '查看完整号码并外呼',
      (true, false, false) => '查看完整微信号',
      (true, true, true) => '拨打电话',
      (true, true, false) => '复制微信号',
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
class _ReportSheet extends StatefulWidget {
  const _ReportSheet({required this.onSubmit});

  final ValueChanged<String> onSubmit;

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  /// §7.7 原文五项，顺序与措辞照抄，不自行增删或改写 ——
  /// 举报原因会进 §9.10.3 风险分权重表，改一个词就对不上运营配置。
  static const _reasons = ['不实信息', '诈骗', '违规类目', '骚扰', '其他'];

  String? _selected;

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
            ..._reasons.map(
              (r) => RadioListTile<String>(
                value: r,
                // ignore: deprecated_member_use
                groupValue: _selected,
                // ignore: deprecated_member_use
                onChanged: (v) => setState(() => _selected = v),
                title: Text(
                  r,
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
