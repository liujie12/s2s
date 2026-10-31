/// 拼车「车牌」控件：省份 + 发牌机关字母走下拉，号码段手填。
///
/// **为什么前两位必须下拉**：车牌写错的高发点就是省份简称与字母段（皖/院、
/// A/4），这两段取值可穷举（31 个简称、24 个字母），做下拉等于把错误堵在
/// 源头；号码段是自由组合，只能手填。
///
/// **为什么存一个字符串**：见 `domain/car_options.dart` 的库注释 —— 三段只是
/// 输入方式，产品语义是一个车牌号；任一段为空即整体未填，避免 `template_values`
/// 出现「皖A」这种半截值。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design_tokens.dart';
import '../../domain/car_options.dart';

/// 车牌号控件（省份下拉 + 字母下拉 + 号码输入）。
class PlateField extends StatefulWidget {
  /// 构造车牌控件。
  ///
  /// 参数：[value] 当前字段值（`皖A12345` 形态，可能是空串或历史自由文本）；
  ///   [onChanged] 值变化回调，参数为拼好的车牌或空串（未填全）。
  const PlateField({
    super.key,
    required this.value,
    required this.onChanged,
  });

  /// 当前字段值。
  final String value;

  /// 值变化回调。
  final ValueChanged<String> onChanged;

  @override
  State<PlateField> createState() => _PlateFieldState();
}

/// 当前展开的面板（省份 / 字母 / 无）。
enum _PlatePanel { none, province, letter }

class _PlateFieldState extends State<PlateField> {
  /// 已选省份简称。
  String _province = '';

  /// 已选发牌机关字母。
  String _letter = '';

  /// 号码段输入控制器。
  late final TextEditingController _codeCtrl;

  /// 当前展开的面板。
  _PlatePanel _panel = _PlatePanel.none;

  @override
  void initState() {
    super.initState();
    final parts = splitPlate(widget.value);
    _province = parts.province;
    _letter = parts.letter;
    _codeCtrl = TextEditingController(text: parts.code);
  }

  @override
  void didUpdateWidget(PlateField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变化（草稿载入、清空）时回填三段；与本地拼出的值一致时不动，
    // 免得把用户正在输入的号码覆盖掉。
    if (widget.value == _composed) return;
    final parts = splitPlate(widget.value);
    _province = parts.province;
    _letter = parts.letter;
    if (_codeCtrl.text != parts.code) _codeCtrl.text = parts.code;
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  /// 三段拼成的存储值（任一段为空即空串）。
  String get _composed => composePlate(
    province: _province,
    letter: _letter,
    code: _codeCtrl.text,
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _buildSegment(
              text: _province.isEmpty ? '省份' : _province,
              active: _province.isNotEmpty,
              onTap: () => _togglePanel(_PlatePanel.province),
            ),
            const SizedBox(width: AppSpacing.xs),
            _buildSegment(
              text: _letter.isEmpty ? '字母' : _letter,
              active: _letter.isNotEmpty,
              onTap: () => _togglePanel(_PlatePanel.letter),
            ),
            const SizedBox(width: AppSpacing.xs),
            Expanded(child: _buildCodeInput()),
          ],
        ),
        if (_panel != _PlatePanel.none) ...[
          const SizedBox(height: AppSpacing.xs),
          _buildPanel(),
        ],
      ],
    );
  }

  /// 省份 / 字母段的值块（点开对应面板）。
  ///
  /// 参数 [text] 段内文案；[active] 是否已选；[onTap] 点击切换面板。
  /// 返回：值块控件。
  Widget _buildSegment({
    required String text,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Semantics(
      button: true,
      value: active ? text : '未选择',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Container(
            height: 44,
            constraints: const BoxConstraints(minWidth: 56),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            decoration: BoxDecoration(
              color: active
                  ? const Color(AppColors.primaryLight)
                  : const Color(AppColors.background),
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: active
                    ? const Color(AppColors.primary)
                    : const Color(AppColors.border),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: AppTypeScale.body.size,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: active
                        ? const Color(AppColors.primaryDark)
                        : const Color(AppColors.textPlaceholder),
                  ),
                ),
                const Icon(
                  Icons.arrow_drop_down,
                  size: 18,
                  color: Color(AppColors.textPlaceholder),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 号码段输入框（字母数字、自动大写、限 5–6 位）。
  ///
  /// 返回：输入框控件。
  Widget _buildCodeInput() {
    return TextField(
      controller: _codeCtrl,
      maxLength: NfrPublishCarLimits.plateCodeMaxLength,
      textCapitalization: TextCapitalization.characters,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9]')),
        const _UpperCaseFormatter(),
      ],
      style: TextStyle(
        fontSize: AppTypeScale.body.size,
        letterSpacing: 1.5,
        color: const Color(AppColors.textPrimary),
      ),
      decoration: InputDecoration(
        isDense: true,
        hintText: '如 12345',
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
      onChanged: (_) => _emit(),
    );
  }

  /// 候选面板：省份 31 项 / 字母 24 项，点选即收起。
  ///
  /// 返回：面板控件。
  Widget _buildPanel() {
    final isProvince = _panel == _PlatePanel.province;
    final options = isProvince ? kPlateProvinces : kPlateLetters;
    final current = isProvince ? _province : _letter;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: const Color(AppColors.surface),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: const Color(AppColors.border)),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final option in options)
            _buildChoice(
              option: option,
              selected: option == current,
              onTap: () => _applySegment(option, isProvince: isProvince),
            ),
        ],
      ),
    );
  }

  /// 单个候选块（省份 / 字母共用）。
  ///
  /// 参数 [option] 候选值；[selected] 是否已选；[onTap] 点选回调。
  /// 返回：候选块控件。
  Widget _buildChoice({
    required String option,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? const Color(AppColors.primaryLight)
              : const Color(AppColors.background),
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(
            color: selected
                ? const Color(AppColors.primary)
                : const Color(AppColors.border),
          ),
        ),
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
    );
  }

  /// 切换面板（再点同一段即收起）。
  ///
  /// 参数 [panel] 目标面板。
  /// 返回：无。
  void _togglePanel(_PlatePanel panel) {
    setState(() => _panel = _panel == panel ? _PlatePanel.none : panel);
  }

  /// 应用省份或字母段并收起面板。
  ///
  /// 参数 [value] 选中值；[isProvince] 是否为省份段。
  /// 返回：无；通过 [PlateField.onChanged] 写回拼好的车牌。
  void _applySegment(String value, {required bool isProvince}) {
    setState(() {
      if (isProvince) {
        _province = value;
      } else {
        _letter = value;
      }
      _panel = _PlatePanel.none;
    });
    _emit();
  }

  /// 把当前三段拼成存储值写回父级（未拼全写空串）。
  ///
  /// 返回：无。
  void _emit() => widget.onChanged(_composed);
}

/// 把输入内容转成大写（车牌字母按国标为大写）。
class _UpperCaseFormatter extends TextInputFormatter {
  /// 构造大写格式化器。
  const _UpperCaseFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final upper = newValue.text.toUpperCase();
    if (upper == newValue.text) return newValue;
    return newValue.copyWith(
      text: upper,
      selection: TextSelection.collapsed(offset: upper.length),
    );
  }
}
