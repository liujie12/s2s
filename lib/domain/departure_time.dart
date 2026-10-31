/// 出发时刻工具（拼车 `depart_time` 字段的解析、序列化与展示，KTD2 / KTD5）。
///
/// **为什么单独一个文件而不是塞进控件**：同一份格式化要同时被发布表单、
/// AI 确认页、发布成功页、详情页与我的发布使用（R8）。各写一份意味着
/// 「今天 / 明天 / M月d日」的判定会在五处各漂移一次。
///
/// **为什么解析失败返回 null 而不抛错**：库里同时存在 ISO 时刻串与历史自由
/// 文本（「工作日 8:00」），后者在任何界面都必须原样展示而不是打崩页面
/// （R7 / R8）。与 `route_pair.dart` 的「失败即空」同口径。
library;

import '../nfr_constants.dart';

/// 拼车「出发时间」的模板字段键（发布控件、详情展示与 AI 确认页共用）。
///
/// 单点定义而非各端手写字面量：展示端要靠它识别「这个键的值是时刻」，
/// 键名一旦改口径，漏改一处就会让 ISO 串在某个界面裸奔（R8）。
const String kDepartTimeFieldKey = 'depart_time';

/// 解析出发时刻。
///
/// 参数：[raw] 字段原始值（可为 null、空串、历史自由文本或 ISO-8601 串）。
/// 返回：可解析时为**设备本地时区**的 DateTime（展示端不再各自换算时区）；
///   不可解析（历史文本、空串、null）一律 null，不抛异常。
DateTime? tryParseDepartTime(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  return DateTime.tryParse(trimmed)?.toLocal();
}

/// 出发时刻序列化为上送值。
///
/// 参数：[value] 已选时刻（本地或任意时区）。
/// 返回：RFC3339 UTC 秒精度串，形如 `2026-10-30T10:30:00Z`；该串原样落
///   `template_values['depart_time']` 字符串键（KTD2，契约全局纪律第 5 条）。
String departTimeToWire(DateTime value) {
  final utc = value.toUtc();
  final year = utc.year.toString().padLeft(4, '0');
  final month = utc.month.toString().padLeft(2, '0');
  final day = utc.day.toString().padLeft(2, '0');
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  final second = utc.second.toString().padLeft(2, '0');
  return '$year-$month-${day}T$hour:$minute:${second}Z';
}

/// 把出发时刻格式化为用户可读文案（R4 / R8 的唯一实现）。
///
/// 参数：[value] 待展示时刻；[now] 判定「今天 / 明天」的参照时刻（注入而非
///   内部取 `DateTime.now()`，保证纯函数可测）。
/// 返回：同日「今天 HH:mm」、次日「明天 HH:mm」、其余「M月d日 HH:mm」，
///   24 小时制、分钟补零。
String formatDepartTime(DateTime value, {required DateTime now}) {
  final local = value.toLocal();
  final base = now.toLocal();
  final today = DateTime(base.year, base.month, base.day);
  final target = DateTime(local.year, local.month, local.day);
  final diffDays = target.difference(today).inDays;
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final clock = '$hour:$minute';
  if (diffDays == 0) return '今天 $clock';
  if (diffDays == 1) return '明天 $clock';
  return '${local.month}月${local.day}日 $clock';
}

/// 计算三枚快捷 chip 的文案与目标时刻（R2）。
///
/// 参数：[now] 点击时刻（注入保证可测）。
/// 返回：按展示顺序排列的三枚 chip——「现在出发」= 点击时刻归整到分钟、
///   「1 小时后」= 其 + [NfrPublish.departTimeChipHourOffset] 小时、
///   「明早 H:00」= 次日 [NfrPublish.departTimeMorningHour] 点整。
///   chip 值精确到分钟，不受滚轮步长约束。
List<({String label, DateTime value})> departTimeQuickChips(DateTime now) {
  final base = now.toLocal();
  final floored = DateTime(
    base.year,
    base.month,
    base.day,
    base.hour,
    base.minute,
  );
  final morningHour = NfrPublish.departTimeMorningHour.toString();
  final chipHours = NfrPublish.departTimeChipHourOffset;
  return [
    (label: '现在出发', value: floored),
    (
      label: '$chipHours 小时后',
      value: floored.add(const Duration(hours: NfrPublish.departTimeChipHourOffset)),
    ),
    (
      label: '明早 $morningHour:00',
      value: DateTime(
        base.year,
        base.month,
        base.day + 1,
        NfrPublish.departTimeMorningHour,
      ),
    ),
  ];
}
