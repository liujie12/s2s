/// 筛选面板（PRD §6.4.1 展开态：范围条 + 供需胶囊 + 五大类栏）。
///
/// **为什么放在 `features/discovery/` 而不是 `features/map/`**：PRD §10.1 要求
/// 列表页复用同一套控件本体（列表页只是外层套白底容器、不做收起）。它先在地图页
/// 用上，但「谁先用」不是归属依据 —— 放在 map 下会逼着列表页 import 地图模块，
/// 那是反向依赖；而复制一份则会让两页筛选样式各自漂移。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import '../../domain/listing_category.dart';
import 'discovery_filter.dart';

/// 筛选面板本体。
class FilterPanel extends ConsumerWidget {
  const FilterPanel({super.key, this.elevated = true});

  /// 是否自带白底与阴影。
  ///
  /// 地图页把它浮在底图上，须有底与影才看得清；列表页把它嵌在已是白底的
  /// 顶部区域内，再叠一层白底加阴影会出现「卡中卡」的视觉断层。
  final bool elevated;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: elevated
            ? BorderRadius.circular(AppRadius.lg)
            : BorderRadius.zero,
        boxShadow: elevated
            ? const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 12,
                  offset: Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _RadiusRow(),
          SizedBox(height: AppSpacing.md),
          _SupplyDemandRow(),
          SizedBox(height: AppSpacing.md),
          _CategoryRow(),
          SizedBox(height: AppSpacing.md),
          _LegendRow(),
        ],
      ),
    );
  }
}

/// 范围档位行（PRD §6.4.1：范围 1 3 [5] 10 全城）。
class _RadiusRow extends ConsumerWidget {
  const _RadiusRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = ref.watch(discoveryFilterProvider).radius;
    return Row(
      children: [
        _RowLabel('范围'),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: SearchRadius.values.map((r) {
              return _PillButton(
                label: r.label,
                selected: r == current,
                onTap: () =>
                    ref.read(discoveryFilterProvider.notifier).setRadius(r),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }
}

/// 供需行（PRD §6.4.1：⦿ 资源 ○ 需求，可都选）。
class _SupplyDemandRow extends ConsumerWidget {
  const _SupplyDemandRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(discoveryFilterProvider).supplyDemand;
    return Row(
      children: [
        _RowLabel('供需'),
        ...SupplyDemand.values.map((sd) {
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: _PillButton(
              label: sd.label,
              selected: selected.contains(sd),
              onTap: () => ref
                  .read(discoveryFilterProvider.notifier)
                  .toggleSupplyDemand(sd),
            ),
          );
        }),
      ],
    );
  }
}

/// 分类行（PRD §6.4.1：全部 工作 房屋 车辆 生活 服务）。
class _CategoryRow extends ConsumerWidget {
  const _CategoryRow();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(discoveryFilterProvider);
    final notifier = ref.read(discoveryFilterProvider.notifier);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _RowLabel('分类'),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _PillButton(
                  label: '全部',
                  selected: filter.isAllCategories,
                  onTap: notifier.clearCategories,
                ),
                ...ListingCategory.values.map((c) {
                  final on = filter.categories.contains(c);
                  return Padding(
                    padding: const EdgeInsets.only(left: AppSpacing.sm),
                    child: _PillButton(
                      label: c.label,
                      selected: on,
                      // 选中态用 deepColor 作底：分类原色配白字不过 AA
                      // （design_tokens.dart:74）。
                      selectedColor: c.deepColor,
                      icon: c.icon,
                      onTap: () => notifier.toggleCategory(c),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 图例（PRD §6.4.1：实心＝资源，空心+?＝需求）。
///
/// 面板内常驻而非独立浮层：PRD 要求图例「不再常驻在地图上」，但它在面板展开时
/// 出现是合理的 —— 用户正在筛供需，此刻恰是最需要知道两者视觉差别的时候。
class _LegendRow extends StatelessWidget {
  const _LegendRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _RowLabel('图例'),
        _LegendItem(isSupply: true, text: '实心 = 资源'),
        const SizedBox(width: AppSpacing.md),
        _LegendItem(isSupply: false, text: '空心+? = 需求'),
      ],
    );
  }
}

class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.isSupply, required this.text});

  final bool isSupply;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = Color(AppColors.textSecondary);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isSupply ? color : Colors.transparent,
            border: Border.all(color: color, width: 1.5),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          text,
          style: TextStyle(fontSize: AppTypeScale.caption.size, color: color),
        ),
      ],
    );
  }
}

/// 行首标签。固定宽度让四行的控件左边缘对齐。
class _RowLabel extends StatelessWidget {
  const _RowLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: Text(
        text,
        style: TextStyle(
          fontSize: AppTypeScale.small.size,
          color: Color(AppColors.textSecondary),
        ),
      ),
    );
  }
}

/// 胶囊按钮。
class _PillButton extends StatelessWidget {
  const _PillButton({
    required this.label,
    required this.selected,
    required this.onTap,
    this.selectedColor,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 选中态底色。为 null 时用品牌主色。
  final Color? selectedColor;

  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final bg = selected
        ? (selectedColor ?? Color(AppColors.primary))
        : Color(AppColors.background);
    final fg = selected
        ? Color(AppColors.surface)
        : Color(AppColors.textPrimary);

    return GestureDetector(
      onTap: onTap,
      // 胶囊视觉高 32，但命中区须达 44（iOS HIG 下限）。用透明 padding 撑开，
      // 而不是把胶囊本身画到 44 高 —— 那会让面板整体变高、吃掉地图空间。
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AppRadius.full),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: fg),
                const SizedBox(width: AppSpacing.xs),
              ],
              Text(
                label,
                style: TextStyle(fontSize: AppTypeScale.small.size, color: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
