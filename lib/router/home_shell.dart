/// 底部三 Tab 导航壳（PRD §10.2）。
///
/// 结构依据 prototype-figma/code.js 的 `FLOW_LINKS` 与 `bottomTabRaw`：
/// - `bottomTab('鸭圈')` 只出现在 home/list、`bottomTab('我的')` 只出现在 profile，
///   **全文件没有任何 `bottomTab('发布')`** —— 发布页没有底部 Tab 栏；
/// - `FLOW_LINKS` 里 `_tab-发布 → publish-screen`、`_tab-我的 → profile-screen`，
///   「发布」是点击后 push 全屏发布页的键，不是持久分支。
///
/// 故本壳只承载两个持久分支（鸭圈 = 地图/列表、我的 = profile），
/// 中间的「发布」键复用同一排 44px 命中区，但 onTap 是 `push('/publish')`
/// 而非 `goBranch` —— 发布页是顶层路由，push 后底部导航随壳一起被覆盖。
///
/// 三键图标一律矢量（PRD §10.2「不得用 emoji」）：`map` / 鸭子微缩 / `person`。
/// 鸭子微缩几何真源是 prototype-figma/assets/duck-symbol-mini.svg，见
/// [_DuckMiniPainter] 文件头说明。
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../design_tokens.dart';
import 'app_router.dart';

/// 应用底部导航壳。
///
/// 由 [StatefulShellRoute] 的 builder 调用：`body` 承载当前分支的 Navigator，
/// `bottomNavigationBar` 承载三键栏。分支页面（MapScreen/ListScreen/profile
/// 占位屏）各自持自己的 Scaffold + AppBar，此处不再叠一层 AppBar。
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  /// go_router 的分支 Navigator 壳，`body` 直接渲染它。
  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: _BottomNavBar(navigationShell: navigationShell),
    );
  }
}

/// 底部三键栏（PRD §10.2）。
///
/// 栏高 64px（PRD §6.4.1 ASCII 图「底部三 Tab（实体，64px）」），三键等分，
/// 每键命中区 44px（code.js 里 `_tab-*` 单元格 `h:44`，靠栏高 64 余量补齐
/// 触控区下限而不抬高栏高）。
class _BottomNavBar extends StatelessWidget {
  const _BottomNavBar({required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    final int index = navigationShell.currentIndex;
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
                label: '鸭圈',
                selected: index == 0,
                onTap: () => navigationShell.goBranch(0),
              ),
              _PublishTab(onTap: () => context.push(AppRoutes.publish)),
              _TabItem(
                icon: Icons.person,
                label: '我的',
                selected: index == 1,
                onTap: () => navigationShell.goBranch(1),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 普通 Tab 键（鸭圈 / 我的）。
///
/// 选中态主色、未选中态次要文字色：只改色不改形（PRD §1.4.1.1 叠加铁律），
/// 且两态同时改图标与文字颜色，避免 emoji 那种「文字变色图标不变」的断裂。
class _TabItem extends StatelessWidget {
  const _TabItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color color = selected
        ? const Color(AppColors.primary)
        : const Color(AppColors.textSecondary);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: color),
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

/// 「发布」中键。
///
/// 品牌主色 + 鸭子微缩图标（PRD §10.2「胶囊大按钮 + 品牌主色 + 鸭子微缩图标」）。
/// 图标本身即「主色圆盘 + 白色实体鸭头 + 主色眼点」的胶囊形，故不另套圆角容器。
class _PublishTab extends StatelessWidget {
  const _PublishTab({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const _DuckMiniIcon(size: 24),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '发布',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: const Color(AppColors.primary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 鸭子微缩图标（PRD §1.4.1.2 mini 档，24px）。
///
/// 渲染成「主色圆盘铺满画板 + 白色实体鸭头 + 主色眼点」的反相结构 ——
/// 24px 下白盘直径仅约 10px，镂空鸭头会先丢喙尖，故 mini 档把鸭头反相为
/// 白色实体（prototype-figma/code.js `DUCK_HEAD_MINI` 上方的说明）。
class _DuckMiniIcon extends StatelessWidget {
  const _DuckMiniIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.square(size),
      painter: _DuckMiniPainter(
        block: const Color(AppColors.primary),
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

  /// 色块色（圆盘 + 眼点），此处恒主色。
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
