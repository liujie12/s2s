/// 地址展示压缩：去掉开头的省/市/区/县/镇等行政前缀。
///
/// 用户在本地场景下知道自己所在的城市，省市区前缀只会挤占位置头与筛选 chip
/// 有限的横向空间，把真正有用的地名（小区/商圈/道路）挤到省略号后面。
/// 只做**展示**压缩，不改写入的锚点名 —— 位置面板与最近使用仍保留完整地址。
library;

/// 最多连续剥掉的行政层级数（省→市→区/县→镇/乡/街道）。
///
/// 4 层覆盖「省+市+区+街道」与「自治区+州+县+镇」；再多就不是行政前缀了。
const int _kMaxAdminPrefixLevels = 4;

/// 一个行政层级的前缀形态（锚定开头，非贪婪取最短）。
///
/// 覆盖：省 / 自治区 / 特别行政区 / 市 / 自治州 / 地区 / 盟 / 县 / 区 / 旗 /
/// 镇 / 乡 / 街道。前面的 `{2,8}?` 是地名本身（如「安徽」「内蒙古」「双墩」）。
final RegExp _adminPrefix = RegExp(
  r'^[\u4e00-\u9fa5]{2,8}?(?:省|自治区|特别行政区|市|自治州|地区|盟|县|区|旗|镇|乡|街道)',
);

/// 把地址压缩成便于展示的短名。
///
/// 参数：[raw] 逆地理地址或 POI 名称（可空）。
/// 返回：去掉连续行政前缀后的文案；输入为空或剥到只剩 1 个字时原样返回。
String shortLocationLabel(String? raw) {
  final String text = raw?.trim() ?? '';
  if (text.isEmpty) return '';
  String rest = text;
  for (int i = 0; i < _kMaxAdminPrefixLevels; i++) {
    final RegExpMatch? match = _adminPrefix.firstMatch(rest);
    if (match == null) break;
    final String tail = rest.substring(match.end).trim();
    // 至少留 2 个字，避免只剩「镇」「区」这类残词（如「人民路市场」误剥）。
    if (tail.length < 2) break;
    rest = tail;
  }
  return rest;
}
