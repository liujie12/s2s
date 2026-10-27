/// 筛选面板（PRD §6.4.1 展开态 + 2026-10-26 V1.5 三级分类重设计）。
///
/// 面板同时被地图页（底部浮层）与列表页（底部弹层）复用，因此放在
/// `features/discovery/` 而不是 `features/map/`。两页只共用这一份控件，
/// 避免「地图一套筛选、列表另一套」的观感分裂。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import '../../domain/category_tree.dart';
import '../../domain/listing_category.dart';
// 色与图标已迁至 style 扩展（详细设计 §10.4.1）。
import '../../domain/listing_category_style.dart';
import '../perf/layer_switch_recorder.dart';
import 'condition_slots.dart';
import 'discovery_filter.dart';
import 'discovery_query.dart';
import 'effective_filter.dart';
import 'effective_filter_provider.dart';
import 'search_conditions.dart';
import 'search_intent.dart';

/// 面板最大高度（逻辑像素）。
///
/// 设计稿在 390×844 上是 500；小屏用屏高 72% 兜底，避免底部按钮被顶出屏幕。
const double _kPanelMaxHeight = 500;

/// 筛选面板本体。
class FilterPanel extends ConsumerStatefulWidget {
  const FilterPanel({
    super.key,
    this.elevated = true,
    this.measureLayerSwitch = false,
  });

  /// 是否自带阴影。
  ///
  /// 地图页浮在底图上需要阴影；列表页放在弹层里，阴影由弹层环境承担。
  final bool elevated;

  /// 是否把分类切换计为一次「图层切换」耗时（[140]）。
  ///
  /// **只有地图页为 true**：轴② 量的是分类 Pin 在地图上完成首屏绘制的
  /// 端到端耗时；列表页没有 Pin 渲染终点，计时会永远收不了尾。
  final bool measureLayerSwitch;

  @override
  ConsumerState<FilterPanel> createState() => _FilterPanelState();
}

class _FilterPanelState extends ConsumerState<FilterPanel> {
  /// 重置计数：变化时用新 Key 重建分类区，把三级下钻退回一级。
  int _resetEpoch = 0;

  /// 重置筛选条件并把分类区退回一级。
  ///
  /// 参数：无；返回：无。
  void _reset() {
    FocusScope.of(context).unfocus();
    ref.read(searchConditionsProvider.notifier).resetFilters();
    setState(() => _resetEpoch++);
  }

  @override
  Widget build(BuildContext context) {
    final double height = math.min(
      _kPanelMaxHeight,
      MediaQuery.sizeOf(context).height * 0.72,
    );
    return SizedBox(
      height: height,
      child: Container(
        decoration: BoxDecoration(
          color: Color(AppColors.surface),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: widget.elevated
              ? const [
                  BoxShadow(
                    color: Color(0x2A000000),
                    blurRadius: 20,
                    offset: Offset(0, -4),
                  ),
                ]
              : null,
        ),
        child: Column(
          children: [
            const _SheetHandle(),
            _PanelHeader(onReset: _reset),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xs,
                  AppSpacing.lg,
                  AppSpacing.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _RadiusRow(),
                    const SizedBox(height: AppSpacing.md),
                    const _SupplyDemandRow(),
                    const SizedBox(height: AppSpacing.lg),
                    const _PriceSection(),
                    const SizedBox(height: AppSpacing.lg),
                    _CategorySection(
                      key: ValueKey<int>(_resetEpoch),
                      measureLayerSwitch: widget.measureLayerSwitch,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    const _LegendRow(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部拖拽条（视觉提示，不承载手势）。
class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 2),
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFD1D5DB),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

/// 面板标题行：标题 + 重置。
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.onReset});

  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.xs,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Row(
        children: [
          Text(
            '筛选条件',
            style: TextStyle(
              fontSize: AppTypeScale.h3.size,
              fontWeight: FontWeight.w600,
              color: Color(AppColors.textPrimary),
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: onReset,
            style: TextButton.styleFrom(
              foregroundColor: Color(AppColors.primaryDark),
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              minimumSize: const Size(44, 44),
            ),
            child: Text(
              '重置',
              style: TextStyle(fontSize: AppTypeScale.small.size),
            ),
          ),
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
    final SearchRadius current = ref.watch(effectiveFilterProvider).radius;
    return Row(
      children: [
        const _RowLabel('范围'),
        Expanded(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: SearchRadius.values.map((r) {
              return _PillButton(
                label: r.label,
                selected: r == current,
                onTap: () =>
                    ref.read(searchConditionsProvider.notifier).setRadius(r),
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
    final Set<SupplyDemand> selected = ref
        .watch(effectiveFilterProvider)
        .supplyDemand;
    return Row(
      children: [
        const _RowLabel('供需'),
        ...SupplyDemand.values.map((sd) {
          return Padding(
            padding: const EdgeInsets.only(right: AppSpacing.sm),
            child: _PillButton(
              label: sd.label,
              selected: selected.contains(sd),
              onTap: () => ref
                  .read(searchConditionsProvider.notifier)
                  .toggleSupplyDemand(sd),
            ),
          );
        }),
      ],
    );
  }
}

/// 价格区（R23：持久条件，默认不过滤；滑杆 + 可编辑数值框）。
class _PriceSection extends ConsumerStatefulWidget {
  const _PriceSection();

  @override
  ConsumerState<_PriceSection> createState() => _PriceSectionState();
}

class _PriceSectionState extends ConsumerState<_PriceSection> {
  /// 滑杆上限（元）。超过此值的输入仍可写入，滑杆只显示到上限。
  static const double _sliderMax = 3000;

  /// 滑杆步数：3000 / 100 = 30 档。
  static const int _sliderDivisions = 30;

  late final TextEditingController _min;
  late final TextEditingController _max;
  late final FocusNode _minFocus;
  late final FocusNode _maxFocus;

  @override
  void initState() {
    super.initState();
    final EffectiveFilter effective = ref.read(effectiveFilterProvider);
    _min = TextEditingController(text: effective.priceMin?.toString() ?? '');
    _max = TextEditingController(text: effective.priceMax?.toString() ?? '');
    _minFocus = FocusNode();
    _maxFocus = FocusNode();
  }

  @override
  void dispose() {
    _min.dispose();
    _max.dispose();
    _minFocus.dispose();
    _maxFocus.dispose();
    super.dispose();
  }

  /// 提交两侧输入。
  ///
  /// 每次输入即写入（不再等失焦）：面板没有「确定」按钮，用户改完价格直接点
  /// 面板外的地图收起，失焦时机不可靠，等失焦会丢掉刚输入的值。
  /// `digitsOnly` 已挡住非数字，故解析失败只可能是空串（= 不限该侧）；
  /// 区间倒置时不写入：静默交换会让用户输入的数字出现在错的一侧。
  ///
  /// 参数：无；返回：无。
  void _commit() {
    final int? min = int.tryParse(_min.text);
    final int? max = int.tryParse(_max.text);
    if (min != null && max != null && min > max) return;
    ref.read(searchConditionsProvider.notifier).setPrice(min: min, max: max);
  }

  /// 清空两侧，回到「不限」。
  ///
  /// 参数：无；返回：无。
  void _clear() {
    _min.clear();
    _max.clear();
    ref.read(searchConditionsProvider.notifier).setPrice();
  }

  /// 把持久价格换算成滑杆值。
  ///
  /// 参数：[effective] 当前生效条件；返回：滑杆的起止值（0 与 3000 表示不限）。
  RangeValues _sliderValues(EffectiveFilter effective) {
    double start = (effective.priceMin ?? 0)
        .toDouble()
        .clamp(0, _sliderMax)
        .toDouble();
    double end = (effective.priceMax ?? _sliderMax.toInt())
        .toDouble()
        .clamp(0, _sliderMax)
        .toDouble();
    if (start > end) {
      start = 0;
      end = _sliderMax;
    }
    return RangeValues(start, end);
  }

  @override
  Widget build(BuildContext context) {
    // 价格可能从别处改（chip 删除、撤销）：面板开着时也要跟上。
    ref.listen(
      effectiveFilterProvider.select((e) => (e.priceMin, e.priceMax)),
      (_, next) {
        if (_minFocus.hasFocus || _maxFocus.hasFocus) return;
        final String minText = next.$1?.toString() ?? '';
        final String maxText = next.$2?.toString() ?? '';
        if (_min.text != minText) _min.text = minText;
        if (_max.text != maxText) _max.text = maxText;
      },
    );
    final EffectiveFilter effective = ref.watch(effectiveFilterProvider);
    final bool hasPrice = effective.hasPrice;
    final RangeValues values = _sliderValues(effective);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _RowLabel('价格'),
            const Spacer(),
            GestureDetector(
              onTap: hasPrice ? _clear : null,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Text(
                  '不限',
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: hasPrice
                        ? Color(AppColors.primary)
                        : Color(AppColors.textPlaceholder),
                  ),
                ),
              ),
            ),
          ],
        ),
        SizedBox(
          height: 36,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              overlayShape: SliderComponentShape.noOverlay,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              rangeThumbShape: const RoundRangeSliderThumbShape(
                enabledThumbRadius: 8,
              ),
            ),
            child: RangeSlider(
              values: values,
              min: 0,
              max: _sliderMax,
              divisions: _sliderDivisions,
              labels: RangeLabels(
                values.start <= 0 ? '不限' : '¥${values.start.round()}',
                values.end >= _sliderMax ? '不限' : '¥${values.end.round()}',
              ),
              activeColor: hasPrice
                  ? Color(AppColors.primary)
                  : Color(AppColors.border),
              inactiveColor: Color(AppColors.border),
              onChanged: (next) {
                final int? min = next.start.round() <= 0
                    ? null
                    : next.start.round();
                final int? max = next.end.round() >= _sliderMax
                    ? null
                    : next.end.round();
                ref
                    .read(searchConditionsProvider.notifier)
                    .setPrice(min: min, max: max);
              },
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Text(
              '¥',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: _PriceField(
                controller: _min,
                focusNode: _minFocus,
                hint: '不限',
                onCommit: _commit,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              child: Text(
                '—',
                style: TextStyle(
                  fontSize: AppTypeScale.small.size,
                  color: Color(AppColors.textSecondary),
                ),
              ),
            ),
            Text(
              '¥',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: _PriceField(
                controller: _max,
                focusNode: _maxFocus,
                hint: '不限',
                onCommit: _commit,
              ),
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '元',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// 单侧价格输入框：视觉高度 32，命中区由外层 padding 补足。
class _PriceField extends StatelessWidget {
  const _PriceField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onCommit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        textAlign: TextAlign.center,
        textInputAction: TextInputAction.done,
        // 输入即提交：面板靠「点地图外部」收起，失焦提交会丢值。
        onChanged: (_) => onCommit(),
        onSubmitted: (_) => onCommit(),
        style: TextStyle(
          fontSize: AppTypeScale.small.size,
          color: Color(AppColors.textPrimary),
        ),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textPlaceholder),
          ),
          filled: true,
          fillColor: Color(AppColors.surface),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm,
            vertical: AppSpacing.sm,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: BorderSide(color: Color(AppColors.border)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: BorderSide(color: Color(AppColors.border)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            borderSide: BorderSide(color: Color(AppColors.primary)),
          ),
        ),
      ),
    );
  }
}

/// 分类区：一级大类 → 二级子类 → 三级叶子。
class _CategorySection extends ConsumerStatefulWidget {
  const _CategorySection({super.key, required this.measureLayerSwitch});

  /// 是否把本次分类切换计为一次图层切换（见 [FilterPanel.measureLayerSwitch]）。
  final bool measureLayerSwitch;

  @override
  ConsumerState<_CategorySection> createState() => _CategorySectionState();
}

class _CategorySectionState extends ConsumerState<_CategorySection> {
  /// 当前下钻的一级 ID；null 表示停在一级。
  int? _topId;

  /// 当前下钻的二级 ID；null 表示停在二级列表（或一级）。
  int? _midId;

  /// 当前一级节点。
  CategoryNode? get _top => _topId == null
      ? null
      : categoryTree.where((n) => n.id == _topId).firstOrNull;

  /// 当前二级节点。
  CategoryNode? get _mid => _midId == null
      ? null
      : _top?.children.where((n) => n.id == _midId).firstOrNull;

  /// 当前显式选中的叶子集合。
  ///
  /// **不能直接用 `EffectiveFilter.leafCategoryIds`**：投影在「全部分类」时会
  /// 把它展开成全部 48 个叶子供请求使用，直接拿来当选中态会让面板一打开就
  /// 显示所有分类选中。这里按来源还原：
  /// 意图类目（未显式清空）→ 持久叶子 → 持久一级展开 → 空集（全部分类）。
  ///
  /// 参数：[intent] 当前搜索槽位；[filter] 持久筛选。
  /// 返回：显式选中的叶子 ID 集合。
  Set<int> _explicitSelected(SearchIntent? intent, DiscoveryFilter filter) {
    if (intent != null &&
        !intent.isCleared(ConditionSlot.category) &&
        intent.leafCategoryIds.isNotEmpty) {
      return intent.leafCategoryIds.toSet();
    }
    if (filter.leafCategoryIds.isNotEmpty) {
      return filter.leafCategoryIds.toSet();
    }
    if (filter.categories.isNotEmpty) {
      return leafCategoryIdsFor(filter.categories).toSet();
    }
    return <int>{};
  }

  /// 读取当前显式选中集（动作回调用）。
  ///
  /// 参数：无；返回：显式选中的叶子 ID 集合。
  Set<int> _currentSelected() => _explicitSelected(
    ref.read(searchIntentProvider).intent,
    ref.read(discoveryFilterProvider),
  );

  /// 记一次图层切换的起点。
  ///
  /// 参数：无；返回：无。
  void _markSwitchStart() {
    if (widget.measureLayerSwitch) {
      ref.read(layerSwitchRecorderProvider).start();
    }
  }

  /// 一级大类点选（整类 / 取消整类）。
  ///
  /// 参数：[category] 目标一级大类；返回：无。
  void _selectTop(ListingCategory category) {
    _markSwitchStart();
    ref.read(searchConditionsProvider.notifier).toggleCategory(category);
  }

  /// 回到全部分类。
  ///
  /// 参数：无；返回：无。
  void _selectAll() {
    if (_currentSelected().isEmpty) return;
    _markSwitchStart();
    ref.read(searchConditionsProvider.notifier).clearCategories();
  }

  /// 选中某个一级下的全部叶子（二级的「全部服务」）。
  ///
  /// 参数：[top] 一级节点；返回：无。
  void _selectWholeTop(CategoryNode top) {
    final ListingCategory? category = top.topCategory;
    if (category == null) return;
    final DiscoveryFilter filter = ref.read(discoveryFilterProvider);
    final bool already =
        filter.categories.length == 1 &&
        filter.categories.contains(category) &&
        filter.leafCategoryIds.isEmpty;
    if (already) return;
    _markSwitchStart();
    ref.read(searchConditionsProvider.notifier).setCategories({category});
  }

  /// 切换一组叶子的选中状态（二级 chip / 三级「全部」）。
  ///
  /// 参数：[ids] 目标叶子 ID 集合；返回：无。
  void _toggleGroup(Iterable<int> ids) {
    final Set<int> target = ids.toSet();
    if (target.isEmpty) return;
    final Set<int> current = _currentSelected();
    final bool allSelected = target.every(current.contains);
    final Set<int> next = {...current};
    if (allSelected) {
      next.removeAll(target);
    } else {
      next.addAll(target);
    }
    if (_sameSet(next, current)) return;
    _markSwitchStart();
    ref.read(searchConditionsProvider.notifier).setLeafCategories(next);
  }

  /// 切换单个叶子的选中状态。
  ///
  /// 参数：[leafId] 叶子 ID；返回：无。
  void _toggleLeaf(int leafId) {
    final Set<int> current = _currentSelected();
    current.contains(leafId) ? current.remove(leafId) : current.add(leafId);
    _markSwitchStart();
    ref.read(searchConditionsProvider.notifier).setLeafCategories(current);
  }

  /// 进入某个一级的二级列表。
  ///
  /// 参数：[top] 一级节点；返回：无。
  void _drillTop(CategoryNode top) {
    setState(() {
      _topId = top.id;
      _midId = null;
    });
  }

  /// 进入某个二级的三级叶子列表。
  ///
  /// 参数：[mid] 二级节点；返回：无。
  void _drillMid(CategoryNode mid) {
    setState(() => _midId = mid.id);
  }

  /// 返回上一级。
  ///
  /// 参数：无；返回：无。
  void _back() {
    setState(() {
      if (_midId != null) {
        _midId = null;
      } else {
        _topId = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final SearchIntent? intent = ref.watch(searchIntentProvider).intent;
    final DiscoveryFilter filter = ref.watch(discoveryFilterProvider);
    final Set<int> selected = _explicitSelected(intent, filter);
    final CategoryNode? top = _top;
    final CategoryNode? mid = _mid;

    if (top == null) {
      return _buildLevelOne(selected);
    }
    if (mid == null) {
      return _buildLevelTwo(top, selected);
    }
    return _buildLevelThree(top, mid, selected);
  }

  /// 一级：全部 + 五大类。
  ///
  /// 参数：[selected] 显式选中的叶子集合；返回：一级分类区。
  Widget _buildLevelOne(Set<int> selected) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '分类',
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        _grid([
          _CategoryChip(
            label: '全部',
            selected: selected.isEmpty,
            color: Color(AppColors.primary),
            onTap: _selectAll,
          ),
          for (final ListingCategory category in ListingCategory.values)
            _buildTopChip(category, selected),
        ], columns: 3),
      ],
    );
  }

  /// 构建一级大类 chip（含下钻箭头）。
  ///
  /// 参数：[category] 一级大类；[selected] 显式选中的叶子集合。
  /// 返回：一级 chip。
  Widget _buildTopChip(ListingCategory category, Set<int> selected) {
    final CategoryNode? node = categoryTree
        .where((n) => n.topCategory == category)
        .firstOrNull;
    return _CategoryChip(
      label: category.label,
      selected: node != null && _anySelected(_leavesOf(node), selected),
      color: category.deepColor,
      dotColor: category.color,
      onTap: () => _selectTop(category),
      onDrill: node == null ? null : () => _drillTop(node),
    );
  }

  /// 二级：全部 + 该一级下的二级子类。
  ///
  /// 参数：[top] 一级节点；[selected] 当前叶子集合。
  /// 返回：二级分类区。
  Widget _buildLevelTwo(CategoryNode top, Set<int> selected) {
    final Color color = top.topCategory?.deepColor ?? Color(AppColors.primary);
    final Color dotColor = top.topCategory?.color ?? Color(AppColors.primary);
    final List<int> topLeaves = _leavesOf(top);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _breadcrumb(
          top: top.name,
          current: '选择子类',
          strongCurrent: false,
          onBack: _back,
        ),
        const SizedBox(height: AppSpacing.sm),
        _grid([
          _CategoryChip(
            label: '全部${top.name}',
            selected: _allSelected(topLeaves, selected),
            color: color,
            onTap: () => _selectWholeTop(top),
          ),
          for (final CategoryNode mid in top.children)
            _CategoryChip(
              label: mid.name,
              selected: _anySelected(_leavesOf(mid), selected),
              color: color,
              dotColor: dotColor,
              dense: true,
              onTap: () => _toggleGroup(_leavesOf(mid)),
              onDrill: () => _drillMid(mid),
            ),
        ], columns: 3),
      ],
    );
  }

  /// 三级：叶子多选。
  ///
  /// 参数：[top] 一级节点；[mid] 二级节点；[selected] 当前叶子集合。
  /// 返回：三级分类区。
  Widget _buildLevelThree(
    CategoryNode top,
    CategoryNode mid,
    Set<int> selected,
  ) {
    final Color color = top.topCategory?.deepColor ?? Color(AppColors.primary);
    final List<int> leaves = _leavesOf(mid);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _breadcrumb(
          top: top.name,
          current: mid.name,
          strongCurrent: true,
          onBack: _back,
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            _LeafChip(
              label: '全部',
              selected: _allSelected(leaves, selected),
              color: Color(AppColors.primary),
              onTap: () => _toggleGroup(leaves),
            ),
            for (final CategoryNode leaf in mid.children)
              _LeafChip(
                label: leaf.name,
                selected: selected.contains(leaf.id),
                color: color,
                onTap: () => _toggleLeaf(leaf.id),
              ),
          ],
        ),
      ],
    );
  }

  /// 分类面包屑（一级 › 当前级 + 返回）。
  ///
  /// 参数：[top] 一级名；[current] 当前级文案；[strongCurrent] 是否加粗当前级；
  /// [onBack] 返回回调。
  /// 返回：面包屑控件。
  Widget _breadcrumb({
    required String top,
    required String current,
    required bool strongCurrent,
    required VoidCallback onBack,
  }) {
    return Row(
      children: [
        Text(
          top,
          style: TextStyle(
            fontSize: AppTypeScale.small.size,
            color: Color(AppColors.textSecondary),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
          child: Text(
            '›',
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              color: Color(AppColors.textPlaceholder),
            ),
          ),
        ),
        Expanded(
          child: Text(
            current,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: AppTypeScale.small.size,
              fontWeight: strongCurrent ? FontWeight.w600 : FontWeight.w400,
              color: strongCurrent
                  ? Color(AppColors.textPrimary)
                  : Color(AppColors.textSecondary),
            ),
          ),
        ),
        GestureDetector(
          onTap: onBack,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
            child: Text(
              '‹ 返回',
              style: TextStyle(
                fontSize: AppTypeScale.caption.size,
                color: Color(AppColors.primary),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 等宽网格（用于一级/二级分类）。
  ///
  /// 参数：[items] 子项；[columns] 列数；返回：按行排好的网格。
  Widget _grid(List<Widget> items, {required int columns}) {
    final List<Widget> rows = [];
    for (int start = 0; start < items.length; start += columns) {
      final List<Widget> cells = [];
      for (int offset = 0; offset < columns; offset++) {
        final int index = start + offset;
        cells.add(
          Expanded(
            child: index < items.length ? items[index] : const SizedBox(),
          ),
        );
        if (offset < columns - 1) {
          cells.add(const SizedBox(width: 6));
        }
      }
      rows.add(Row(children: cells));
      if (start + columns < items.length) {
        rows.add(const SizedBox(height: 6));
      }
    }
    return Column(children: rows);
  }

  /// 某节点下的全部叶子 ID。
  ///
  /// 参数：[node] 一级或二级节点；返回：叶子 ID 列表。
  List<int> _leavesOf(CategoryNode node) => [
    for (final CategoryNode mid in node.children)
      for (final CategoryNode leaf in mid.children) leaf.id,
  ];

  /// 目标叶子是否全部选中。
  ///
  /// 参数：[ids] 目标集合；[selected] 当前集合；返回：是否全选。
  bool _allSelected(Iterable<int> ids, Set<int> selected) {
    final List<int> list = ids.toList();
    return list.isNotEmpty && list.every(selected.contains);
  }

  /// 目标叶子是否有任一选中。
  ///
  /// 参数：[ids] 目标集合；[selected] 当前集合；返回：是否任一选中。
  bool _anySelected(Iterable<int> ids, Set<int> selected) =>
      ids.any(selected.contains);

  /// 集合值相等。
  ///
  /// 参数：[a]/[b] 两个集合；返回：内容是否相同。
  bool _sameSet(Set<int> a, Set<int> b) =>
      a.length == b.length && a.containsAll(b);
}

/// 分类胶囊（可带分类色圆点与下钻箭头）。
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
    this.dotColor,
    this.onDrill,
    this.dense = false,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  final Color? dotColor;
  final VoidCallback? onDrill;

  /// 紧凑档：二级 6 项用三列时缩小字号与内边距。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final Color foreground = selected
        ? Color(AppColors.surface)
        : Color(AppColors.textPrimary);
    final double fontSize = dense ? 10.5 : 11.5;
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      decoration: BoxDecoration(
        color: selected ? color : const Color(0xFFF2F4F1),
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: EdgeInsets.only(left: dense ? 6 : 8, right: 2),
                child: dotColor == null
                    ? Center(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: fontSize,
                            fontWeight: selected
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: foreground,
                          ),
                        ),
                      )
                    : Row(
                        children: [
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selected
                                  ? Color(AppColors.surface)
                                  : dotColor,
                            ),
                          ),
                          SizedBox(width: dense ? 4 : 5),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: fontSize,
                                fontWeight: selected
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: foreground,
                              ),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
          if (onDrill != null)
            GestureDetector(
              onTap: onDrill,
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: dense ? 20 : 24,
                height: 36,
                child: Icon(
                  Icons.chevron_right,
                  size: dense ? 15 : 16,
                  color: selected
                      ? Color(AppColors.surface)
                      : Color(AppColors.textSecondary).withValues(alpha: .55),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 三级叶子胶囊（可多选）。
class _LeafChip extends StatelessWidget {
  const _LeafChip({
    required this.label,
    required this.selected,
    required this.color,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        // 不用固定高度 + alignment：Wrap 给的是有界宽/无界高，Container 带
        // alignment 会横向撑满整行。用上下等距 padding 让文字天然垂直居中，
        // 宽度仍由内容决定。
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: selected ? color : const Color(0xFFF2F4F1),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            height: 1.2,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected
                ? Color(AppColors.surface)
                : Color(AppColors.textPrimary),
          ),
        ),
      ),
    );
  }
}

/// 图例（PRD §6.4.1：实心＝资源，空心+?＝需求）。
class _LegendRow extends StatelessWidget {
  const _LegendRow();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const _RowLabel('图例'),
        _LegendItem(isSupply: true, text: '实心 = 资源'),
        const SizedBox(width: AppSpacing.md),
        _LegendItem(isSupply: false, text: '空心+? = 需求'),
      ],
    );
  }
}

/// 单条图例。
class _LegendItem extends StatelessWidget {
  const _LegendItem({required this.isSupply, required this.text});

  final bool isSupply;
  final String text;

  @override
  Widget build(BuildContext context) {
    final Color color = Color(AppColors.textSecondary);
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

/// 行首标签。固定宽度让各行的控件左边缘对齐。
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
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color bg = selected
        ? Color(AppColors.primary)
        : Color(AppColors.background);
    final Color fg = selected
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
          child: Center(
            child: Text(
              label,
              style: TextStyle(fontSize: AppTypeScale.small.size, color: fg),
            ),
          ),
        ),
      ),
    );
  }
}
