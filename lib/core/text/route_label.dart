/// 起终点的展示文案（选择页与详情页共用，编码规范 §1.1「第二处即上浮」）。
///
/// **为什么收在一处**：距离与时长在两个页面出现（选择页的卡片摘要、详情页的
/// 属性行），取整规则各写一份时，同一条路线会在选点时写「约 19 km」、在详情页
/// 写「约 18.5 km」—— 用户会以为两次看到的是两条不同的路线。
library;

import '../../domain/route_pair.dart';

/// 起终点的一行摘要：`起点名 → 终点名`。
///
/// 参数：[pair] 起终点值。
/// 返回：摘要文案；名称缺失的一端退回「起点」/「终点」，不输出空串。
String routePairLabel(RoutePair pair) =>
    '${_placeName(pair.origin, '起点')} → ${_placeName(pair.destination, '终点')}';

/// 距离与时长的一行摘要：`约 19 km · 约 35 分钟`。
///
/// 参数：[pair] 起终点值（需已带距离与时长）。
/// 返回：摘要文案；任一项缺失时返回 null，由调用方隐藏整段（R13）。
String? routeDistanceLabel(RoutePair pair) {
  final distance = pair.distanceM;
  final duration = pair.durationS;
  if (distance == null || duration == null) return null;
  return '${routeMetersLabel(distance)} · ${routeDurationText(duration)}';
}

/// 驾车里程文案：`约 850 m` / `约 19 km`。
///
/// 参数：[meters] 里程（米）。
/// 返回：展示文案；1km 以内取整到 10m，1km 以上保留一位小数、10km 以上取整。
String routeMetersLabel(int meters) {
  if (meters < 1000) return '约 ${(meters / 10).round() * 10} m';
  final km = meters / 1000;
  final text = km >= 10 ? km.round().toString() : km.toStringAsFixed(1);
  return '约 $text km';
}

/// 驾车时长文案：`约 35 分钟` / `约 1 小时 10 分钟`。
///
/// 参数：[seconds] 时长（秒）。
/// 返回：展示文案；不足一分钟按一分钟计（「约 0 分钟」读起来像故障）。
String routeDurationText(int seconds) {
  final rawMinutes = (seconds / 60).round();
  final minutes = rawMinutes < 1 ? 1 : rawMinutes;
  if (minutes < 60) return '约 $minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '约 $hours 小时' : '约 $hours 小时 $rest 分钟';
}

/// 取地点主值名称，空则退回位置标签。
///
/// 参数：[place] 地点；[fallback] 名称缺失时的占位词。
/// 返回：非空名称。
String _placeName(RoutePlace place, String fallback) {
  final name = place.name.trim();
  return name.isEmpty ? fallback : name;
}
