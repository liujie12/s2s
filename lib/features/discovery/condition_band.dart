/// 地图与列表共用的两行条件带。
///
/// 第一行是搜索输入（文字 / 语音 / 提交 / 叉号），第二行是当前生效条件的
/// chip 行。两页渲染的是**同一份投影**，不各自维护「当前筛的是什么」。
///
/// 为什么两行常驻而不折叠：条件默认可见比省那点高度重要 —— 折叠后用户
/// 又要靠记忆判断「现在到底筛了什么」，正是本轮要修的缺陷。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import 'effective_filter.dart';
import 'effective_filter_provider.dart';
import 'search_conditions.dart';

/// 两行条件带。
class ConditionBand extends ConsumerStatefulWidget {
  /// 构造条件带。
  ///
  /// 参数：[countLabel] 命中数文案（`3 条` / `0 条`），加载中传 null；
  /// [onVoice] 语音入口；[onSubmit] 文本提交（不传则用门面 submit）；
  /// [onEditChip] 点开改值；[onAddCondition] 追加条件；[onRetry] 没听懂后的重试。
  const ConditionBand({
    super.key,
    required this.countLabel,
    this.onVoice,
    this.onSubmit,
    this.onEditChip,
    this.onAddCondition,
    this.onRetry,
  });

  /// 命中数文案；null 表示取数未完成。
  final String? countLabel;

  /// 语音入口回调。
  final VoidCallback? onVoice;

  /// 文本提交回调；null 时直接走门面 `submit`。
  final ValueChanged<String>? onSubmit;

  /// chip 改值回调。
  final ValueChanged<ConditionChip>? onEditChip;

  /// 追加条件回调。
  final VoidCallback? onAddCondition;

  /// 「没听懂」后的重试回调。
  final VoidCallback? onRetry;

  @override
  ConsumerState<ConditionBand> createState() => _ConditionBandState();
}

class _ConditionBandState extends ConsumerState<ConditionBand> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(searchConditionsProvider).queryText,
    );
    _focus = FocusNode();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 提交当前文本。
  ///
  /// 回填与提交分离：程序化改写 controller 不触发解析，只有这里显式提交。
  void _submit() {
    final String text = _controller.text.trim();
    if (text.isEmpty) return;
    _focus.unfocus();
    if (widget.onSubmit != null) {
      widget.onSubmit!(text);
    } else {
      ref.read(searchConditionsProvider.notifier).submit(text: text);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 文本可能被外部改写（清除、语音回填），这里只做受控同步。
    ref.listen(searchConditionsProvider.select((s) => s.queryText), (_, next) {
      if (_controller.text != next) {
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });

    final SearchConditionsState conditions = ref.watch(searchConditionsProvider);
    final EffectiveFilter effective = ref.watch(effectiveFilterProvider);
    final SearchStatus status = ref.watch(searchStatusProvider);
    final bool busy = status.busy;
    final bool noUnderstand = status.noUnderstand;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        boxShadow: const [
          BoxShadow(color: Color(0x1F000000), blurRadius: 12, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _searchRow(conditions, busy),
          const SizedBox(height: AppSpacing.xs),
          _chipRow(effective, conditions, noUnderstand, busy),
        ],
      ),
    );
  }

  /// 第一行：输入框 + 提交 + 叉号 + 语音。
  Widget _searchRow(SearchConditionsState conditions, bool busy) {
    final bool hasText = _controller.text.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onChanged: (value) {
                ref.read(searchConditionsProvider.notifier).setQueryText(value);
                setState(() {}); // 提交/叉号的显隐跟随文本
              },
              onSubmitted: (_) => _submit(),
              onTapOutside: (_) => _focus.unfocus(),
              style: TextStyle(fontSize: AppTypeScale.body.size),
              decoration: InputDecoration(
                hintText: '搜索保洁/拼车/租房',
                hintStyle: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textPlaceholder),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.sm,
                ),
                filled: true,
                fillColor: Color(AppColors.background),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: hasText
                    ? IconButton(
                        tooltip: '清除文字',
                        icon: Icon(Icons.close, size: 16, color: Color(AppColors.textSecondary)),
                        onPressed: () {
                          _controller.clear();
                          ref.read(searchConditionsProvider.notifier).clearText();
                          setState(() {});
                        },
                      )
                    : null,
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        if (hasText)
          _BandAction(
            label: '搜索',
            filled: true,
            enabled: !busy,
            onTap: busy ? null : _submit,
          )
        else if (widget.onVoice != null)
          _BandAction(label: '语音', onTap: widget.onVoice),
      ],
    );
  }

  /// 第二行：chip 横滑 + 追加 + 命中数 + 撤销 / 清除。
  Widget _chipRow(
    EffectiveFilter effective,
    SearchConditionsState conditions,
    bool noUnderstand,
    bool busy,
  ) {
    final List<Widget> chips = [
      for (final ConditionChip chip in effective.chips)
        _ConditionChipView(
          chip: chip,
          onTap: chip.editable && widget.onEditChip != null
              ? () => widget.onEditChip!(chip)
              : null,
          onDelete: chip.deletable
              ? () => ref.read(searchConditionsProvider.notifier).removeSlot(chip)
              : null,
        ),
      // 未敢用字段：灰态、无删除、不参与计数（R16）。
      for (final String label in effective.unresolvedLabels)
        _UnresolvedChip(label: label),
    ];

    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                ...chips,
                Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.xs),
                  child: _BandAction(
                    label: '＋ 条件',
                    dashed: true,
                    onTap: widget.onAddCondition,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        if (noUnderstand)
          _BandAction(label: '没听懂', onTap: widget.onRetry)
        else
          Padding(
            padding: const EdgeInsets.only(right: AppSpacing.xs),
            child: Text(
              busy ? '—' : (widget.countLabel ?? '—'),
              semanticsLabel: busy ? '正在取数' : '命中 ${widget.countLabel ?? '未知'}',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                fontWeight: FontWeight.w600,
                color: Color(AppColors.textPrimary),
              ),
            ),
          ),
        if (conditions.canUndo)
          _BandAction(
            label: '撤销',
            onTap: () => ref.read(searchConditionsProvider.notifier).undo(),
          ),
        // 清除只在搜索态出现：无搜索态时它等于「重置持久筛选」，语义不同。
        if (effective.active)
          _BandAction(
            label: '清除',
            onTap: () => ref.read(searchConditionsProvider.notifier).clearAll(),
          ),
      ],
    );
  }
}

/// 一枚条件 chip。
class _ConditionChipView extends StatelessWidget {
  const _ConditionChipView({
    required this.chip,
    required this.onTap,
    required this.onDelete,
  });

  final ConditionChip chip;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final bool fromIntent = chip.source == ConditionSource.intent;
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: InputChip(
        label: Text(chip.label),
        onPressed: onTap,
        onDeleted: onDelete,
        // × 的触控区单独撑到 32：图标只有 14，直接拿图标当热区时
        // 真机上一次点中率极低，误触反而落到 chip 主体打开改值面板。
        deleteIcon: onDelete == null
            ? null
            : const SizedBox(
                width: 32,
                height: 32,
                child: Icon(Icons.close, size: 14),
              ),
        visualDensity: VisualDensity.compact,
        // 来源可辨：本次搜索用品牌色描边，持久筛选用中性描边。
        side: BorderSide(
          color: fromIntent ? Color(AppColors.primary) : Color(AppColors.border),
        ),
        backgroundColor: Color(AppColors.surface),
        labelStyle: TextStyle(
          fontSize: AppTypeScale.small.size,
          color: Color(AppColors.textPrimary),
        ),
        tooltip: fromIntent ? '${chip.label}（本次搜索）' : '${chip.label}（筛选）',
      ),
    );
  }
}

/// 灰态「没敢用」chip。
class _UnresolvedChip extends StatelessWidget {
  const _UnresolvedChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.xs),
      child: Chip(
        label: Text('$label · 没敢用'),
        visualDensity: VisualDensity.compact,
        backgroundColor: Color(AppColors.background),
        labelStyle: TextStyle(
          fontSize: AppTypeScale.small.size,
          color: Color(AppColors.textPlaceholder),
        ),
        side: BorderSide(color: Color(AppColors.border)),
      ),
    );
  }
}

/// 条件带内的小动作（提交 / 语音 / 追加 / 没听懂）。
class _BandAction extends StatelessWidget {
  const _BandAction({
    required this.label,
    this.onTap,
    this.filled = false,
    this.dashed = false,
    this.enabled = true,
  });

  final String label;
  final VoidCallback? onTap;
  final bool filled;
  final bool dashed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final Color fg = filled ? Color(AppColors.surface) : Color(AppColors.textPrimary);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      // 命中区补到 44：胶囊视觉高 28，直接用视觉高度当热区会频繁点空。
      child: Container(
        height: 44,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: Container(
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            color: filled ? Color(AppColors.primary) : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: dashed
                ? Border.all(color: Color(AppColors.border))
                : null,
          ),
          child: Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: enabled ? fg : Color(AppColors.textPlaceholder),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
