/// 地图与列表共用的固定搜索栏 + 动态筛选栏。
///
/// 设计口径（2026-10-26 用户确认的 V1.5）：
/// - 搜索栏常驻，左上角不再有「丫圈」标题；
/// - 默认不显示任何筛选项，只有搜索/面板真正设置了条件才长出 chip；
/// - 点搜索栏的漏斗或任意 chip 主体，打开底部筛选面板；
/// - 「没听懂」不再占 chip 行，改为搜索栏下方的深色提示，8 秒自动消失。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../design_tokens.dart';
import 'effective_filter.dart';
import 'effective_filter_provider.dart';
import 'search_conditions.dart';

/// 「没听懂」提示的自动消失时长。
///
/// 取值与设计稿一致（8s）；放成命名常量，避免在 widget 里散落魔法数字。
const Duration _noUnderstandToastDuration = Duration(seconds: 8);

/// 固定搜索栏 + 动态 chip 栏。
class ConditionBand extends ConsumerStatefulWidget {
  /// 构造条件带。
  ///
  /// 参数：
  /// - [onFilter]：点漏斗或 chip 主体时打开筛选面板；
  /// - [onVoice]：语音入口（无语音能力时不传）；
  /// - [onSubmit]：文本提交；不传则直接走门面 `submit`；
  /// - [onRetry]：「没听懂」提示上的重试；
  /// - [trailingInset]：chip 行右侧预留宽度（地图页给右侧浮钮让位）。
  const ConditionBand({
    super.key,
    this.onFilter,
    this.onVoice,
    this.onSubmit,
    this.onRetry,
    this.trailingInset = 0,
  });

  /// 打开筛选面板。
  final VoidCallback? onFilter;

  /// 语音入口。
  final VoidCallback? onVoice;

  /// 文本提交回调；null 时直接走门面 `submit`。
  final ValueChanged<String>? onSubmit;

  /// 「没听懂」后的重试回调。
  final VoidCallback? onRetry;

  /// chip 行右侧预留宽度（逻辑像素）——从**可视区域**里扣掉，不给滚动内容。
  final double trailingInset;

  @override
  ConsumerState<ConditionBand> createState() => _ConditionBandState();
}

class _ConditionBandState extends ConsumerState<ConditionBand> {
  late final TextEditingController _controller;
  late final FocusNode _focus;

  /// 「没听懂」提示是否已被用户关掉/超时关掉。
  bool _noUnderstandDismissed = false;

  /// 自动消失定时器。
  Timer? _noUnderstandTimer;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(searchConditionsProvider).queryText,
    );
    _focus = FocusNode();
    if (ref.read(searchStatusProvider).noUnderstand) {
      _scheduleNoUnderstandDismiss();
    }
  }

  @override
  void dispose() {
    _noUnderstandTimer?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 安排「没听懂」提示自动消失。
  ///
  /// 参数：无；返回：无。
  void _scheduleNoUnderstandDismiss() {
    _noUnderstandTimer?.cancel();
    _noUnderstandTimer = Timer(_noUnderstandToastDuration, () {
      if (!mounted) return;
      setState(() => _noUnderstandDismissed = true);
    });
  }

  /// 提交当前文本。
  ///
  /// 参数：无；返回：无。
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

    // 新一次「没听懂」重新计时；恢复正常态时清掉计时器。
    ref.listen(searchStatusProvider, (previous, next) {
      if (next.noUnderstand && !(previous?.noUnderstand ?? false)) {
        setState(() => _noUnderstandDismissed = false);
        _scheduleNoUnderstandDismiss();
      } else if (!next.noUnderstand) {
        _noUnderstandTimer?.cancel();
        if (_noUnderstandDismissed) {
          setState(() => _noUnderstandDismissed = false);
        }
      }
    });

    final SearchConditionsState conditions = ref.watch(
      searchConditionsProvider,
    );
    final EffectiveFilter effective = ref.watch(effectiveFilterProvider);
    final SearchStatus status = ref.watch(searchStatusProvider);
    final bool hasChips =
        effective.chips.isNotEmpty || effective.unresolvedLabels.isNotEmpty;
    final bool showNoUnderstand =
        status.noUnderstand &&
        !_noUnderstandDismissed &&
        widget.onRetry != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSearchBar(conditions, status.busy),
        if (hasChips) ...[
          const SizedBox(height: AppSpacing.sm),
          _buildChipRow(effective),
        ],
        if (showNoUnderstand) ...[
          const SizedBox(height: AppSpacing.sm),
          _NoUnderstandToast(
            onTap: () {
              _noUnderstandTimer?.cancel();
              setState(() => _noUnderstandDismissed = true);
              widget.onRetry?.call();
            },
          ),
        ],
      ],
    );
  }

  /// 固定搜索栏：放大镜 + 输入 + 漏斗 + 语音/发送。
  ///
  /// 参数：[conditions] 当前门面状态（取文本判断发送键）；[busy] 是否正在解析。
  /// 返回：搜索栏控件。
  Widget _buildSearchBar(SearchConditionsState conditions, bool busy) {
    final bool hasText = conditions.queryText.trim().isNotEmpty;
    return Container(
      height: 48,
      padding: const EdgeInsets.only(left: AppSpacing.md, right: 6),
      decoration: BoxDecoration(
        color: Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: const Color(0xFFE2E5DE)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1A000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: Color(AppColors.textSecondary)),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focus,
              textInputAction: TextInputAction.search,
              onChanged: (value) {
                ref.read(searchConditionsProvider.notifier).setQueryText(value);
              },
              onSubmitted: (_) => _submit(),
              onTapOutside: (_) => _focus.unfocus(),
              style: TextStyle(
                fontSize: AppTypeScale.body.size,
                color: Color(AppColors.textPrimary),
              ),
              decoration: InputDecoration(
                hintText: '试试：附近 2 公里 二手冰箱',
                hintStyle: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  color: Color(AppColors.textPlaceholder),
                ),
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          _RoundIconButton(
            icon: Icons.filter_alt_outlined,
            tooltip: '筛选',
            onTap: widget.onFilter,
            size: 32,
            iconSize: 18,
          ),
          const SizedBox(width: 4),
          if (busy)
            const SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (hasText)
            _RoundIconButton(
              icon: Icons.arrow_upward_rounded,
              tooltip: '搜索',
              onTap: _submit,
              size: 36,
              iconSize: 18,
              filled: true,
            )
          else if (widget.onVoice != null)
            _RoundIconButton(
              icon: Icons.mic_none,
              tooltip: '语音搜索',
              onTap: widget.onVoice,
              size: 36,
              iconSize: 19,
              tinted: true,
            ),
          const SizedBox(width: 2),
        ],
      ),
    );
  }

  /// 动态 chip 栏：没有条件时整行不渲染。
  ///
  /// 参数：[effective] 当前生效条件；返回：chip 行控件。
  Widget _buildChipRow(EffectiveFilter effective) {
    final List<Widget> chips = [
      for (final ConditionChip chip in effective.chips)
        _FilterChip(
          chip: chip,
          onTap: widget.onFilter,
          onDelete: chip.deletable
              ? () =>
                    ref.read(searchConditionsProvider.notifier).removeSlot(chip)
              : null,
        ),
      // 未敢用字段：灰态、无删除、不参与计数。
      for (final String label in effective.unresolvedLabels)
        _UnresolvedChip(label: label),
    ];

    return GestureDetector(
      onTap: widget.onFilter,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 36,
        // 预留宽度必须落在**视口外**：写在滚动内容里时，chip 仍会先画到浮钮底下，
        // 只有滚到末尾才让位；放在视口上才能保证任何滚动位置都不被浮钮遮住。
        child: Padding(
          padding: EdgeInsets.only(right: widget.trailingInset),
          child: ShaderMask(
            // 右侧渐隐：让用户知道这行可以横滑，而不是「chip 被裁掉了」。
            shaderCallback: (Rect rect) => const LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [Colors.black, Colors.black, Colors.transparent],
              stops: [0, 0.92, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: chips),
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索栏里的圆形图标键。
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    required this.size,
    required this.iconSize,
    this.filled = false,
    this.tinted = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;

  /// 主色实心（发送键）。
  final bool filled;

  /// 主色浅底（语音键）。
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    final Color foreground = filled
        ? Color(AppColors.surface)
        : (tinted ? Color(AppColors.primary) : Color(AppColors.textSecondary));
    final Color? background = filled
        ? Color(AppColors.primary)
        : (tinted ? Color(AppColors.primaryLight) : null);
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: Icon(icon, size: iconSize, color: foreground),
        ),
      ),
    );
  }
}

/// 一枚动态筛选 chip。
class _FilterChip extends StatelessWidget {
  const _FilterChip({
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
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Tooltip(
        message: fromIntent ? '${chip.label}（本次搜索）' : '${chip.label}（筛选）',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: 32,
            padding: EdgeInsets.only(
              left: 10,
              right: onDelete == null ? 12 : 2,
            ),
            decoration: BoxDecoration(
              color: Color(AppColors.surface),
              borderRadius: BorderRadius.circular(AppRadius.full),
              border: Border.all(
                color: fromIntent
                    ? Color(AppColors.primary)
                    : Color(AppColors.border),
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 6,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fromIntent
                        ? Color(AppColors.primary)
                        : Color(AppColors.textPlaceholder),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  chip.label,
                  style: TextStyle(
                    fontSize: AppTypeScale.small.size,
                    color: Color(AppColors.textPrimary),
                  ),
                ),
                if (onDelete != null)
                  GestureDetector(
                    onTap: onDelete,
                    behavior: HitTestBehavior.opaque,
                    child: SizedBox(
                      width: 28,
                      height: 32,
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: Color(AppColors.textPlaceholder),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
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
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: Color(AppColors.background),
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: Color(AppColors.border)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(AppColors.textPlaceholder),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '$label · 没敢用',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Color(AppColors.textPlaceholder),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 搜索栏下方的「没听懂」提示。
class _NoUnderstandToast extends StatelessWidget {
  const _NoUnderstandToast({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF16232E),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.refresh, size: 15, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              '没听懂 · 重试',
              style: TextStyle(
                fontSize: AppTypeScale.small.size,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
