/// 时间的展示文案助手（跨页面唯一实现处）。
///
/// **为什么成公共件**：列表页（[list_screen] 的卡片时间）与「我的发布」卡片
/// 副标题（[127] 前端段）两处都要把时间戳说成人话，按编码规范 §1.1「第二处即
/// 上浮」从 `features/discovery/list_screen.dart` 的私有实现迁至此。
library;

/// 发布时间的相对文案（如「刚刚」「3 小时前」「2 天前」，超过 7 天回落日期）。
///
/// 用相对时间而非绝对时间戳：列表类页面要回答的是「这条还新不新」，
/// 「2 小时前」直接给出答案，而「08-28 10:15」还要用户自己算。超过 7 天
/// 回落到日期 —— 「23 天前」这种表述反而不如日期直观。
///
/// 参数：[time] 目标时间（与 [DateTime.now] 同口径，服务端下发 UTC 时间由
///   DTO 解析为 `DateTime`；本函数只做差值，不做时区换算）。
/// 返回：[String] 相对文案（「刚刚」/「N 分钟前」/「N 小时前」/「N 天前」/
///   「M-DD」）。
String formatRelativeAge(DateTime time) {
  final d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
  if (d.inHours < 24) return '${d.inHours} 小时前';
  if (d.inDays <= 7) return '${d.inDays} 天前';
  return '${time.month}-${time.day.toString().padLeft(2, '0')}';
}

/// 发布时间的「…发布」文案（「我的发布」卡片副标题）。
///
/// **「刚刚」的特判收在本文件内**：若交给调用方比较上一次的返回值
/// （`age == '刚刚'`），本文件的展示文案就成了跨文件判据 —— 文案一改（如改成
/// 「刚发布」），调用方会静默拼出「刚发布发布」，编译期与门禁都无感。
///
/// 参数：[time] 发布时间。
/// 返回：[String] 形如「刚刚发布」/「3 天前发布」/「08-28发布」。
String formatRelativePublishAge(DateTime time) {
  final age = formatRelativeAge(time);
  return age == '刚刚' ? '刚刚发布' : '$age发布';
}
