/// 拼车「出发时间」的内联选择控件（R1 / R2 / R3 / R4，KTD5）。
///
/// **为什么内联而不新开页面**：出发时间只有一个值，全屏进出两次只为滚两下
/// 滚轮，成本远高于收益。控件在表单里展开，高度可控，滚轮一收起就回到
/// 与其余字段一致的版面。
///
/// **为什么值进出都是字符串**：控件的输入是 `templateValues['depart_time']`
/// 原值（可能是 ISO 时刻串、历史自由文本或空串），输出是 RFC3339 UTC 串。
/// 历史文本解析不了就不改动它（R7）—— 控件只负责「选一个新时刻」，
/// 不负责清洗旧数据。
///
/// **为什么 chip 值与滚轮步长可以不一致**：chip 是「点一下就完事」的粗粒度
/// 入口（现在 / 1 小时后 / 明早 8:00），本来就该精确到分钟；滚轮是精调入口，
/// 5 分钟步长足够。两者共用同一个字段值，互不覆盖语义。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../design_tokens.dart';
import '../../domain/departure_time.dart';
import '../../nfr_constants.dart';

/// 出发时间的内联控件：值行 + 三枚快捷 chip + 可展开的三列时间滚轮。
class DepartTimeField extends StatefulWidget {
  /// 构造出发时间控件。
  ///
  /// 参数：[value] 当前字段字符串值（ISO 时刻串 / 历史自由文本 / 空串）；
  ///   [onChanged] 选定新时刻后的写回回调，参数为 RFC3339 UTC 时刻串；
  ///   [now] 当前时刻注入点（默认取真实时钟），仅测试用于固定时间基准。
  const DepartTimeField({
    super.key,
    required this.value,
    required this.onChanged,
    this.now,
  });

  /// 当前字段字符串值（原样来自 `templateValues`）。
  final String value;

  /// 选定时刻的写回回调（参数为 `departTimeToWire` 产出的 UTC 串）。
  final ValueChanged<String> onChanged;

  /// 当前时刻注入点；null 表示用真实时钟。
  final DateTime? now;

  @override
  State<DepartTimeField> createState() => _DepartTimeFieldState();
}

class _DepartTimeFieldState extends State<DepartTimeField> {
  /// 当前已选时刻；null 表示未选（含历史文本不可解析的情形，R7）。
  DateTime? _selected;

  /// 滚轮是否展开。
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    _selected = tryParseDepartTime(widget.value);
  }

  @override
  void didUpdateWidget(DepartTimeField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部值变化（如编辑态载入、清空）时同步控件显示。写完值后的重组里
    // 解析结果与 `_selected` 相等，不会来回触发，也不会重复回调 onChanged。
    final parsed = tryParseDepartTime(widget.value);
    if (parsed == null) {
      if (_selected != null) setState(() => _selected = null);
    } else if (_selected == null || !parsed.isAtSameMomentAs(_selected!)) {
      setState(() => _selected = parsed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final now = widget.now ?? DateTime.now();
    final selected = _selected;
    final display = selected != null
        ? formatDepartTime(selected, now: now)
        : '选择出发时间';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          button: true,
          label: '出发时间',
          value: selected != null ? display : '未选择',
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
                    const Icon(
                      Icons.schedule,
                      size: 18,
                      color: Color(AppColors.primary),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        display,
                        style: TextStyle(
                          fontSize: AppTypeScale.body.size,
                          color: selected != null
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
        ),
        if (_expanded) ...[
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            height: 180,
            child: CupertinoDatePicker(
              mode: CupertinoDatePickerMode.dateAndTime,
              use24hFormat: true,
              minuteInterval: NfrPublish.departTimeWheelMinuteStep,
              minimumDate: _wheelMin(now),
              maximumDate: _wheelMax(now),
              initialDateTime: _wheelInitial(now),
              onDateTimeChanged: _onWheelChanged,
            ),
          ),
        ],
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final chip in departTimeQuickChips(now))
              ChoiceChip(
                label: Text(
                  chip.label,
                  style: TextStyle(fontSize: AppTypeScale.small.size),
                ),
                selected:
                    selected != null && _isSameMinute(selected, chip.value),
                selectedColor: const Color(AppColors.primaryLight),
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (_) => _applyChip(chip.value),
              ),
          ],
        ),
      ],
    );
  }

  /// 滚轮可选范围下限：当前时刻之后最近的一个步长整点（含）。
  ///
  /// 参数 [now] 当前时刻。
  /// 返回：向上对齐到 [NfrPublish.departTimeWheelMinuteStep] 分钟的时刻
  ///   （17:32 → 17:35），保证「不可选到早于当前时刻的值」（AE3），
  ///   同时初始定位一定落在分钟列的合法项上。
  DateTime _wheelMin(DateTime now) {
    final step = NfrPublish.departTimeWheelMinuteStep;
    final base = DateTime(now.year, now.month, now.day, now.hour, now.minute);
    final remainder = base.minute % step;
    return remainder == 0
        ? base
        : base.add(Duration(minutes: step - remainder));
  }

  /// 滚轮可选范围上限：当前时刻起 [NfrPublish.departTimeWheelMaxDays] 天。
  ///
  /// 参数 [now] 当前时刻。
  /// 返回：上限时刻（向下对齐到步长，落在分钟列的合法项上）。
  DateTime _wheelMax(DateTime now) {
    final step = NfrPublish.departTimeWheelMinuteStep;
    final base = DateTime(
      now.year,
      now.month,
      now.day + NfrPublish.departTimeWheelMaxDays,
      now.hour,
      now.minute,
    );
    return base.subtract(Duration(minutes: base.minute % step));
  }

  /// 滚轮展开时的初始定位。
  ///
  /// 参数 [now] 当前时刻。
  /// 返回：已选值（对齐步长）夹在 [下限, 上限] 内；未选时取下限。
  ///   历史 ISO 值可能早于此刻，必须夹紧，否则 CupertinoDatePicker 的
  ///   `initialDateTime` 越界断言会直接抛异常。
  DateTime _wheelInitial(DateTime now) {
    final step = NfrPublish.departTimeWheelMinuteStep;
    final min = _wheelMin(now);
    final max = _wheelMax(now);
    final base = _selected ?? min;
    final clamped = base.isBefore(min)
        ? min
        : (base.isAfter(max) ? max : base);
    var snapped = DateTime(
      clamped.year,
      clamped.month,
      clamped.day,
      clamped.hour,
      clamped.minute - clamped.minute % step,
    );
    if (snapped.isBefore(min)) {
      snapped = snapped.add(Duration(minutes: step));
    }
    return snapped.isAfter(max) ? max : snapped;
  }

  /// 滚轮停定即写回（不设确认按钮，省一次点按）。
  ///
  /// 参数 [value] 滚轮选定的时刻。
  /// 返回：无；通过 [DepartTimeField.onChanged] 写回父级。
  void _onWheelChanged(DateTime value) {
    setState(() => _selected = value);
    widget.onChanged(departTimeToWire(value));
  }

  /// 应用一枚快捷 chip：写值并收起滚轮。
  ///
  /// 参数 [value] chip 对应的目标时刻。
  /// 返回：无。
  void _applyChip(DateTime value) {
    setState(() {
      _selected = value;
      _expanded = false;
    });
    widget.onChanged(departTimeToWire(value));
  }

  /// 两个时刻是否落在同一分钟（chip 选中态的判据）。
  ///
  /// 参数 [a]、[b] 待比较时刻。
  /// 返回：年月日时分完全一致时为 true（秒与毫秒不参与）。
  bool _isSameMinute(DateTime a, DateTime b) =>
      a.year == b.year &&
      a.month == b.month &&
      a.day == b.day &&
      a.hour == b.hour &&
      a.minute == b.minute;
}
