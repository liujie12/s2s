/// 底部四 Tab 导航壳（PRD §10.2）。
///
/// 结构依据设计稿 `docs/design/ui/message-center.html` §01（2026-11-01 按真机
/// 走查裁定回国稿顺序）：
/// `[丫圈] [发布] [消息] [我的]`，四项等分，「发布」固定在第 2 格；
/// - 持久分支三个：丫圈（地图/列表）、消息（会话列表/会话详情）、我的（profile）；
/// - 「发布」仍是**点击后 push 全屏发布页**的键，不占分支（点完回到原 Tab，
///   R12 / R34）。历史上 code.js 全文件没有 `bottomTab('发布')`，本次沿用
///   「复用同一排 44px 命中区、onTap 走 push」的既有做法；
/// - 四个键的图标同尺寸（24dp）、未选中同色（`textSecondary`）：发布键不再
///   放大或单独着主色，否则在四项等分的排布下会被读成「常驻选中」。
///
/// 四键图标一律矢量（PRD §10.2「不得用 emoji」）：`map` / 鸭子微缩 /
/// 线性对话气泡 / `person`。鸭子几何真源是
/// prototype-figma/assets/duck-symbol-mini.svg，见 [_DuckMiniPainter] 文件头说明；
/// 气泡几何取自设计稿 §01 的原始 path，见 [_BubblePainter]。
///
/// **未读唯一来源**（KTD14）：Tab 数字角标读 [unreadSummaryProvider]，不在本壳
/// 或任何页面做二次求和；0 时不渲染角标，超过 [NfrChat.unreadBadgeMax] 显示
/// 「99+」（R9 / R11）。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/badge/app_badge.dart';
import '../design_tokens.dart';
import '../features/message/conversation_entry.dart';
import '../features/message/message_list_provider.dart';
import '../features/message/widgets/message_icon.dart';
import '../features/notify/push_service.dart';
import '../nfr_constants.dart';
import 'app_router.dart';

/// 底部持久分支下标（与 `_routes` 中 `StatefulShellRoute` 的 branches 顺序一致）。
///
/// 用命名常量而非裸下标：分支顺序是路由表与导航栏之间的隐式契约，写错只会在
/// 运行时跳错页；两边引用同一组常量则改序时一处生效。
class HomeBranch {
  const HomeBranch._();

  /// 丫圈（地图 / 列表）。
  static const int discovery = 0;

  /// 消息（会话列表）。
  static const int messages = 1;

  /// 我的。
  static const int profile = 2;
}

/// 应用底部导航壳。
///
/// 由 [StatefulShellRoute] 的 builder 调用：`body` 承载当前分支的 Navigator，
/// `bottomNavigationBar` 承载四键栏。分支页面（MapScreen/ListScreen/
/// MessageListScreen/ProfileScreen）各自持自己的 Scaffold + AppBar，
/// 此处不再叠一层 AppBar。
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// go_router 的分支 Navigator 壳，`body` 直接渲染它。
  final StatefulNavigationShell navigationShell;

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

/// 导航壳状态：持推送点击订阅（R16a）。
class _HomeShellState extends ConsumerState<HomeShell> {
  /// 推送点击事件订阅（App 存活时；冷启动的那一次由
  /// [PushService.readInitialClick] 补上）。
  StreamSubscription<Map<String, Object?>>? _clickSubscription;

  @override
  void initState() {
    super.initState();
    final push = ref.read(pushServiceProvider);
    _clickSubscription = push.clicks.listen(_onPushClick);
    unawaited(_consumeInitialClick(push));
  }

  @override
  void dispose() {
    _clickSubscription?.cancel();
    super.dispose();
  }

  /// 处理冷启动点击（一次性，原生侧读取即清除）。
  ///
  /// 参数：[push] 推送服务。
  /// 返回：[Future<void>]。
  Future<void> _consumeInitialClick(PushService push) async {
    final click = await push.readInitialClick();
    if (click != null && mounted) await _onPushClick(click);
  }

  /// 推送点击 → 直达对应会话；会话已隐藏则落到消息列表并提示（R16a）。
  ///
  /// 先查已加载的会话行；查不到就刷新一次列表 —— 会触发推送的一定是「有新消息
  /// 的会话」，它必然排在列表首位，刷新后仍找不到只可能是已隐藏。
  ///
  /// 参数：[click] 原生点击载荷。
  /// 返回：[Future<void>]。
  Future<void> _onPushClick(Map<String, Object?> click) async {
    final target = pushClickTargetOf(click);
    if (target == null || !target.opensConversation) return;
    final conversationId = target.targetId!;

    var items = ref.read(conversationsProvider).asData?.value.items;
    var conversation =
        items == null ? null : conversationById(items, conversationId);
    if (conversation == null) {
      await ref.read(conversationsProvider.notifier).refresh();
      items = ref.read(conversationsProvider).asData?.value.items;
      conversation =
          items == null ? null : conversationById(items, conversationId);
    }
    if (!mounted) return;

    if (conversation != null) {
      context.push(
        '/messages/${conversation.conversationId}',
        extra: conversation,
      );
      return;
    }
    context.go(AppRoutes.messages);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('该会话已隐藏，可在消息列表查看')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unread = ref.watch(
      unreadSummaryProvider.select((value) => value.asData?.value.total ?? 0),
    );
    // 桌面角标与 Tab 数字同源（KTD14 / R11）：总数一变就下发，0 清除。
    // 只在变化时调用；iOS 由 [AppBadge.apply] 自行短路，不发通道调用。
    ref.listen<int>(
      unreadSummaryProvider.select((value) => value.asData?.value.total ?? 0),
      (previous, next) => unawaited(ref.read(appBadgeProvider).apply(next)),
    );
    return Scaffold(
      body: widget.navigationShell,
      bottomNavigationBar: HomeNavBar(
        selectedIndex: widget.navigationShell.currentIndex,
        unreadTotal: unread,
        onSelectBranch: widget.navigationShell.goBranch,
        onPublish: () => context.push(AppRoutes.publish),
      ),
    );
  }
}

/// 底部四键栏（PRD §10.2）。
///
/// 栏高 64px（PRD §6.4.1 ASCII 图「底部四 Tab（实体，64px）」），四键等分，
/// 每键命中区 44px（code.js 里 `_tab-*` 单元格 `h:44`，靠栏高 64 余量补齐
/// 触控区下限而不抬高栏高）。
///
/// 做成纯展示组件（未读总数由调用方传入）而非自己 watch Provider：导航栏的
/// 测试不该依赖网络装配，唯一读取点留在 [HomeShell]，KTD14 的「唯一 Provider
/// 挂载点」才不会被拆成两处。
class HomeNavBar extends StatelessWidget {
  /// 构造底部导航栏。
  ///
  /// 参数：[selectedIndex] 当前分支下标（见 [HomeBranch]）；
  ///   [unreadTotal] 未读总数；[onSelectBranch] 分支切换回调；
  ///   [onPublish] 发布键回调。
  const HomeNavBar({
    super.key,
    required this.selectedIndex,
    required this.unreadTotal,
    required this.onSelectBranch,
    required this.onPublish,
  });

  /// 当前分支下标。
  final int selectedIndex;

  /// 未读总数（唯一来源是 [unreadSummaryProvider]）。
  final int unreadTotal;

  /// 分支切换回调。
  final ValueChanged<int> onSelectBranch;

  /// 发布键回调（push 全屏发布页）。
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(AppColors.surface),
        border: Border(top: BorderSide(color: Color(AppColors.border))),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              _TabItem(
                icon: Icons.map,
                label: '丫圈',
                selected: selectedIndex == HomeBranch.discovery,
                onTap: () => onSelectBranch(HomeBranch.discovery),
              ),
              _PublishTab(onTap: onPublish),
              _TabItem(
                label: '消息',
                iconBuilder: (color) => MessageBubbleIcon(color: color),
                selected: selectedIndex == HomeBranch.messages,
                badgeLabel: unreadBadgeLabel(unreadTotal),
                onTap: () => onSelectBranch(HomeBranch.messages),
              ),
              _TabItem(
                icon: Icons.person,
                label: '我的',
                selected: selectedIndex == HomeBranch.profile,
                onTap: () => onSelectBranch(HomeBranch.profile),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 普通 Tab 键（丫圈 / 消息 / 我的）。
///
/// 选中态主色、未选中态次要文字色：只改色不改形（PRD §1.4.1.1 叠加铁律），
/// 且两态同时改图标与文字颜色，避免 emoji 那种「文字变色图标不变」的断裂。
/// [badgeLabel] 非空时在图标右上角渲染数字角标（R9）。
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
    this.iconBuilder,
    this.badgeLabel,
  }) : assert(icon != null || iconBuilder != null, '图标二选一：icon 或 iconBuilder');

  /// Material 矢量图标（丫圈 / 我的）。
  final IconData? icon;

  /// 自绘图标构造器（消息气泡）：入参为当前态颜色（选中主色 / 未选中次要文字色）。
  final Widget Function(Color color)? iconBuilder;

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 数字角标文案；null / 空串不渲染。
  final String? badgeLabel;

  @override
  Widget build(BuildContext context) {
    final Color color = selected
        ? const Color(AppColors.primary)
        : const Color(AppColors.textSecondary);
    final String? badge = badgeLabel;
    final Widget glyph =
        iconBuilder?.call(color) ?? Icon(icon, size: 24, color: color);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 24,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  glyph,
                  if (badge != null && badge.isNotEmpty)
                    Positioned(top: -6, left: 14, child: _TabBadge(label: badge)),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Tab 数字角标（设计稿：16 高、圆角 full、底 error、字 surface 10/16）。
class _TabBadge extends StatelessWidget {
  const _TabBadge({required this.label});

  /// 角标文案（已按 [NfrChat.unreadBadgeMax] 折算为「99+」）。
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(AppColors.error),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        style: const TextStyle(
          fontSize: 10,
          height: 1.6,
          fontWeight: FontWeight.w600,
          color: Color(AppColors.surface),
        ),
      ),
    );
  }
}


/// 「发布」中键。
///
/// 鸭子微缩图标 + 文字（PRD §10.2）。**尺寸与配色与其它 Tab 完全一致**
/// （2026-11-01 真机走查裁定）：四项等分后排布更紧，32dp 主色鸭子盘会被读成
/// 「常驻选中」，与「发布不是分支、点完即离开」的语义冲突。故回归 24dp +
/// 未选中色 `textSecondary`，靠位置（第 2 格）与文案承担识别，不再靠放大。
class _PublishTab extends StatelessWidget {
  const _PublishTab({required this.onTap});

  /// 鸭子盘尺寸：与其它 Tab 图标同一档，不再放大。
  static const double _duckSize = 24;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    const Color color = Color(AppColors.textSecondary);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _DuckMiniIcon(size: _duckSize, block: color),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '发布',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 鸭子微缩图标（PRD §1.4.1.2 mini 档，矢量）。
///
/// 渲染成「色块圆盘铺满画板 + 白色实体鸭头 + 色块眼点」的反相结构 ——
/// 24px 下白盘直径仅约 10px，镂空鸭头会先丢喙尖，故 mini 档把鸭头反相为
/// 白色实体（prototype-figma/code.js `DUCK_HEAD_MINI` 上方的说明）。
/// 圆盘/眼点颜色由 [block] 传入，尺寸由 [size] 决定（发布入口用 32dp）。
class _DuckMiniIcon extends StatelessWidget {
  const _DuckMiniIcon({required this.size, required this.block});

  final double size;
  final Color block;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _DuckMiniPainter(
        block: block,
        negative: const Color(AppColors.surface),
      ),
    );
  }
}

/// 鸭子微缩档绘制器。
///
/// 几何逐字取自 prototype-figma/assets/duck-symbol-mini.svg（viewBox
/// `0 0 1024 1024`）：圆盘半径 504.01、鸭头 path `DUCK_HEAD_MINI`、眼点
/// (501.03, 341.89, r=45.37)。绘制前把画布缩放到 `size/1024`，坐标直接
/// 沿用 SVG 原文，避免逐坐标缩放引入笔误。
///
/// 本类与 assets/duck-symbol-mini.svg 构成双份副本：改动 SVG 时须同步此处
/// （与 code.js 内联同一份几何同性质的活文件）。
class _DuckMiniPainter extends CustomPainter {
  const _DuckMiniPainter({required this.block, required this.negative});

  /// 色块色（圆盘 + 眼点），由 [_DuckMiniIcon.block] 传入。
  final Color block;

  /// 负形色（鸭头本体），恒 surface（白）。
  final Color negative;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024);

    final Paint blockPaint = Paint()..color = block;
    final Paint negativePaint = Paint()..color = negative;

    // 主色圆盘铺满画板（留 0.78% 余量，见 SVG 半径 504.01 的注释）。
    canvas.drawCircle(const Offset(512, 512), 504.01, blockPaint);
    // 白色实体鸭头。
    canvas.drawPath(_duckHeadPath(), negativePaint);
    // 主色眼点（反相后眼点改主色，白色眼点会与鸭头融为一体）。
    canvas.drawCircle(const Offset(501.03, 341.89), 45.37, blockPaint);

    canvas.restore();
  }

  /// 白色实体鸭头路径，坐标逐字对应 `DUCK_HEAD_MINI`。
  Path _duckHeadPath() {
    return Path()
      ..moveTo(303.84, 184.1)
      ..cubicTo(276.6, 194.17, 257.96, 206.86, 238.93, 219.91)
      ..cubicTo(219.91, 232.96, 204.98, 246.03, 189.69, 262.43)
      ..cubicTo(174.4, 278.84, 158.74, 299.75, 147.17, 318.39)
      ..cubicTo(135.59, 337.04, 127.76, 344.51, 120.31, 374.35)
      ..cubicTo(112.85, 404.18, 100.54, 456.42, 102.4, 497.45)
      ..cubicTo(104.26, 538.48, 115.09, 582.12, 131.5, 620.56)
      ..cubicTo(147.9, 658.99, 172.52, 696.66, 200.88, 727.99)
      ..cubicTo(229.24, 759.33, 262.82, 786.92, 301.6, 808.57)
      ..cubicTo(340.39, 830.21, 392.25, 848.48, 433.66, 857.81)
      ..cubicTo(475.07, 867.14, 522.45, 864.91, 550.05, 864.52)
      ..cubicTo(577.65, 864.14, 588.48, 859.67, 599.29, 855.57)
      ..cubicTo(610.1, 851.48, 609.74, 845.12, 614.96, 839.9)
      ..cubicTo(614.22, 834.69, 622.41, 841.02, 612.72, 824.24)
      ..cubicTo(603.03, 807.45, 568.69, 761.18, 556.77, 739.18)
      ..cubicTo(544.84, 717.18, 543.34, 706.73, 541.1, 692.18)
      ..cubicTo(538.86, 677.63, 539.6, 665.7, 543.34, 651.89)
      ..cubicTo(547.07, 638.08, 551.55, 622.79, 563.48, 609.36)
      ..cubicTo(575.41, 595.93, 584, 581.77, 614.96, 571.31)
      ..cubicTo(645.91, 560.86, 712.32, 556.77, 749.25, 546.69)
      ..cubicTo(786.19, 536.62, 812.66, 524.69, 836.55, 510.88)
      ..cubicTo(860.43, 497.07, 879.45, 477.31, 892.5, 463.88)
      ..cubicTo(905.55, 450.45, 910.41, 440.38, 914.89, 430.3)
      ..cubicTo(919.36, 420.23, 917.86, 412.4, 919.36, 403.44)
      ..cubicTo(911.91, 398.23, 916, 390.4, 896.98, 387.78)
      ..cubicTo(877.95, 385.16, 833.19, 391.51, 805.21, 387.78)
      ..cubicTo(777.23, 384.04, 748.52, 374.73, 729.11, 365.39)
      ..cubicTo(709.7, 356.06, 701.51, 348.61, 688.82, 331.82)
      ..cubicTo(676.13, 315.03, 664.94, 282.96, 653.01, 264.67)
      ..cubicTo(641.08, 246.39, 636.6, 237.08, 617.2, 222.15)
      ..cubicTo(597.79, 207.22, 561.62, 185.6, 536.62, 175.14)
      ..cubicTo(511.62, 164.69, 489.62, 162.09, 467.23, 159.48)
      ..cubicTo(444.85, 156.86, 429.57, 155.38, 402.33, 159.48)
      ..cubicTo(375.09, 163.57, 331.08, 174.02, 303.84, 184.1)
      ..close();
  }

  @override
  bool shouldRepaint(covariant _DuckMiniPainter oldDelegate) {
    return oldDelegate.block != block || oldDelegate.negative != negative;
  }
}
