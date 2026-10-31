/// 选单字段的下拉控件：值行 + 就地展开面板（+ 可选「手动输入」兜底）。
///
/// **为什么不用 ChoiceChip**：类目字段多时 chip 会把表单撑得很长（品牌四十余条
/// 直接铺开就是一屏），而值行 + 面板的高度是恒定的，且与「出发时间」控件同一
/// 套版面规律（值行 → 点开 → 收起），用户不必学两种交互。
///
/// **为什么「手动输入」是兜底而不是并列入口**：品牌与颜色的长尾值必须能录进来
/// （否则小众车发不出去），但主路径仍是点两下选完。故手填入口固定在面板底部，
/// 点了之后值行原地变输入框，语义上仍是「这个字段」，不新开页面。
library;

import 'package:flutter/material.dart';

import '../../design_tokens.dart';

/// 下拉选单控件。
class OptionField extends StatefulWidget {
  /// 构造下拉控件。
  ///
  /// 参数：[value] 当前字段值（空串表示未选）；[options] 候选值；
  ///   [onChanged] 值变化回调；[placeholder] 未选时的占位文案；
  ///   [allowCustom] 是否在面板底部提供「手动输入」（品牌/颜色为 true）；
  ///   [maxLength] 手填时的字数上限（下拉选择不受此限）。
  const OptionField({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.placeholder = '请选择',
    this.allowCustom = false,
    this.maxLength,
  });

  /// 当前字段值。
  final String value;

  /// 候选值列表（顺序即展示顺序）。
  final List<String> options;

  /// 值变化回调。
  final ValueChanged<String> onChanged;

  /// 未选时的占位文案。
  final String placeholder;

  /// 是否允许手填（面板底部出现「手动输入」）。
  final bool allowCustom;

  /// 手填字数上限；null 表示不限。
  final int? maxLength;

  @override
  State<OptionField> createState() => _OptionFieldState();
}

class _OptionFieldState extends State<OptionField> {
  /// 面板是否展开。
  bool _expanded = false;

  /// 是否处于手填模式（值行已变成输入框）。
  bool _manual = false;

  /// 手填输入控制器。
  late final TextEditingController _manualCtrl;

  @override
  void initState() {
    super.initState();
    _manualCtrl = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(OptionField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变化（草稿载入、AI 回填、清空）时同步手填框；
    // 手填过程中的回写与输入框内容一致，不会打断输入。
    if (_manualCtrl.text != widget.value) {
      _manualCtrl.text = widget.value;
    }
  }

  @override
  void dispose() {
    _manualCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_manual) return _buildManualInput();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildValueRow(),
        if (_expanded) ...[
          const SizedBox(height: AppSpacing.xs),
          _buildPanel(),
        ],
      ],
    );
  }

  /// 值行：未选显占位、已选显实值，整行可点切换面板。
  ///
  /// 返回：值行控件。
  Widget _buildValueRow() {
    final hasValue = widget.value.isNotEmpty;
    return Semantics(
      button: true,
      value: hasValue ? widget.value : '未选择',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: const Color(AppColors.background),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(color: const Color(AppColors.border)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    hasValue ? widget.value : widget.placeholder,
                    style: TextStyle(
                      fontSize: AppTypeScale.body.size,
                      color: hasValue
                          ? const Color(AppColors.textPrimary)
                          : const Color(AppColors.textPlaceholder),
                    ),
                  ),
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: const Color(AppColors.textPlaceholder),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 展开面板：候选列表（超高可滚）+ 可选的手填入口。
  ///
  /// 返回：面板控件。
  Widget _buildPanel() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ConstrainedBox(
            // 面板最多占一屏的一小半：再多就盖住下方字段，用户失去上下文。
            constraints: const BoxConstraints(maxHeight: 240),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final option in widget.options)
                    _buildOptionItem(option),
                ],
              ),
            ),
          ),
          if (widget.allowCustom) ...[
            const Divider(height: 1),
            InkWell(
              onTap: _enterManual,
              child: Container(
                height: 44,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                child: Row(
                  children: [
                    const Icon(
                      Icons.edit_outlined,
                      size: 15,
                      color: Color(AppColors.primary),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      '没找到？手动输入',
                      style: TextStyle(
                        fontSize: AppTypeScale.small.size,
                        fontWeight: FontWeight.w600,
                        color: const Color(AppColors.primary),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 单个候选项：选中项打勾并高亮，再点一次清空。
  ///
  /// 参数 [option] 候选值。
  /// 返回：候选项控件。
  Widget _buildOptionItem(String option) {
    final selected = option == widget.value;
    return InkWell(
      onTap: () => _selectOption(option),
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        color: selected
            ? const Color(AppColors.primaryLight)
            : Colors.transparent,
        child: Row(
          children: [
            Expanded(
              child: Text(
                option,
                style: TextStyle(
                  fontSize: AppTypeScale.body.size,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected
                      ? const Color(AppColors.primaryDark)
                      : const Color(AppColors.textPrimary),
                ),
              ),
            ),
            if (selected)
              const Icon(
                Icons.check,
                size: 16,
                color: Color(AppColors.primary),
              ),
          ],
        ),
      ),
    );
  }

  /// 手填模式：值行原地变成输入框。
  ///
  /// 返回：手填输入框（含「返回列表」出口）。
  Widget _buildManualInput() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _manualCtrl,
          autofocus: true,
          maxLength: widget.maxLength,
          decoration: InputDecoration(
            isDense: true,
            hintText: widget.placeholder,
            hintStyle: TextStyle(
              fontSize: AppTypeScale.body.size,
              color: const Color(AppColors.textPlaceholder),
            ),
            counterText: '',
            filled: true,
            fillColor: const Color(AppColors.background),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: const BorderSide(color: Color(AppColors.border)),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: const BorderSide(color: Color(AppColors.border)),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: const BorderSide(color: Color(AppColors.primary)),
            ),
          ),
          onChanged: (v) => widget.onChanged(v.trim()),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => setState(() {
              _manual = false;
              _expanded = true;
            }),
            child: const Text('返回列表'),
          ),
        ),
      ],
    );
  }

  /// 选中/取消一个候选值并收起面板。
  ///
  /// 参数 [option] 候选值。
  /// 返回：无；通过 [OptionField.onChanged] 写回父级。
  void _selectOption(String option) {
    final next = option == widget.value ? '' : option;
    setState(() => _expanded = false);
    widget.onChanged(next);
  }

  /// 进入手填模式（面板收起、输入框聚焦）。
  ///
  /// 返回：无。
  void _enterManual() {
    setState(() {
      _expanded = false;
      _manual = true;
    });
    _manualCtrl.text = widget.value;
  }
}
