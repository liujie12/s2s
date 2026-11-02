/// 底部四 Tab 导航壳（PRD §10.2）。
///
/// 结构依据设计稿 `docs/design/ui/message-center.html` §01（2026-11-01 按真机
/// 走查裁定回国稿顺序）：
/// `[丫圈] [发布] [消息] [我的]`，四项等分，「发布」固定在第 2 格；
/// - 持久分支三个：丫圈（地图/列表）、消息（会话列表/会话详情）、我的（profile）；
/// - 「发布」仍是**点击后 push 全屏发布页**的键，不占分支（点完回到原 Tab，
///   R12 / R34）。历史上 code.js 全文件没有 `bottomTab('发布')`，本次沿用
///   「复用同一排 44px 命中区、onTap 走 push」的既有做法；
/// - 四键未选中同色（`textSecondary`），不着主色避免被读成「常驻选中」；
///   发布键 32dp、其余 24dp（2026-11-02 用户裁定，详见 [_PublishTab]）。
///
/// 四键图标一律矢量（PRD §10.2「不得用 emoji」）：`map` / 脚印 inverse /
/// 线性对话气泡 / `person`。脚印几何真源是
/// prototype-figma/assets/duck-symbol-inverse.svg，见 [_FootprintPainter] 文件头说明；
/// 气泡几何取自设计稿 §01 的原始 path，见 [_BubblePainter]。
///
/// **未读唯一来源**（KTD14）：Tab 数字角标读 [unreadSummaryProvider]，不在本壳
/// 或任何页面做二次求和；0 时不渲染角标，超过 [NfrChat.unreadBadgeMax] 显示
/// 「99+」（R9 / R11）。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/badge/app_badge.dart';
import '../core/ui/footprint_geometry.dart';
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
/// 脚印 inverse 图标 + 文字（PRD §10.2）。尺寸 32dp（2026-11-02 用户裁定，
/// 推翻 11-01「四键同 24dp」结论）：inverse 结构在 24dp 下波纹圈线宽仅约
/// 0.8dp 近乎消失，视觉重心只剩中央约 10.6dp 圆盘，比三个 Material 图标明显
/// 小一圈；放大到 32dp 补回视觉重心。配色仍为未选中色 `textSecondary` 不着
/// 主色 —— 放大补的是「显小」，不是要做成「常驻选中」。
class _PublishTab extends StatelessWidget {
  const _PublishTab({required this.onTap});

  /// 脚印盘尺寸：32dp（其余三键 24dp；放大原因见类注释）。
  static const double _duckSize = 32;

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
            const _FootprintIcon(size: _duckSize, fill: color),
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

/// 脚印发布图标（inverse 变体结构：外围双波纹圈 + 中央圆盘 + 白色脚印）。
///
/// 几何真源 duck-symbol-inverse.svg viewBox `0 0 1024 1024`：
/// - 波纹圈 1：外 r=395.84 / 内 r=361.87（环带）
/// - 波纹圈 2：外 r=305.84 / 内 r=273.54（环带）
/// - 中央圆盘：r=227.08 实心
/// - 脚印 fp0（三趾 ellipse + 掌形贝塞尔）白色反相，
///   translate(506.1, 458.5) rotate(14°) scale(4.20) translate(-54,-45)
///
/// 未选中态全部用 [fill]（textSecondary），脚印用白色反相，与原鸭头
/// 「圆盘+反相」结构一致。当前唯一使用处是发布键 32dp（[_PublishTab]）。
class _FootprintIcon extends StatelessWidget {
  const _FootprintIcon({required this.size, required this.fill});

  final double size;
  final Color fill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _FootprintPainter(fill: fill),
    );
  }
}

/// 脚印绘制器（inverse 变体：双波纹圈 + 中央圆盘 + 白色脚印）。
///
/// 坐标系：画布缩放到 `size / 1024`，坐标直接沿用 duck-symbol-inverse.svg
/// 原文；脚印部分复用共享真源 [FootprintGeometry]（与 SVG / Android
/// build_android_foonote.py 同一份 fp0 坐标）。
class _FootprintPainter extends CustomPainter {
  const _FootprintPainter({required this.fill});

  final Color fill;

  /// 波纹圈 / 圆盘公共圆心（inverse SVG：cx=511.3, cy=506）。
  static const Offset _center = Offset(511.3, 506);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 1024);

    final Paint bandPaint = Paint()
      ..color = fill
      ..style = PaintingStyle.stroke;

    // 波纹圈 1：外 395.84 / 内 361.87 → 环带半径取中、描边取差
    canvas.drawCircle(
      _center,
      (395.84 + 361.87) / 2,
      bandPaint..strokeWidth = 395.84 - 361.87,
    );
    // 波纹圈 2：外 305.84 / 内 273.54
    canvas.drawCircle(
      _center,
      (305.84 + 273.54) / 2,
      bandPaint..strokeWidth = 305.84 - 273.54,
    );

    // 中央实心圆盘 r=227.08
    canvas.drawCircle(
      _center,
      227.08,
      Paint()
        ..color = fill
        ..style = PaintingStyle.fill,
    );

    // 白色脚印：translate(506.1,458.5) rotate(14°) scale(4.20) translate(-54,-45)
    final Paint fpPaint = Paint()
      ..color = const Color(0xFFFFFFFF)
      ..style = PaintingStyle.fill;
    canvas.save();
    canvas
      ..translate(506.1, 458.5)
      ..rotate(14 * math.pi / 180)
      ..scale(4.20)
      ..translate(-54, -45);

    // 三趾 + 掌形：几何复用共享真源，禁在此复制坐标字面量（规范 §1.1）。
    FootprintGeometry.paint(canvas, fpPaint);
    canvas.restore();
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _FootprintPainter oldDelegate) {
    return oldDelegate.fill != fill;
  }
}
