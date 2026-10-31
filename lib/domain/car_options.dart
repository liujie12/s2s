/// 车辆类目（拼车 301）的选单常量与车牌值工具。
///
/// **为什么品牌/颜色放本地常量而不是模板 options**：它们是长尾数据（品牌
/// 四十余个、颜色还有「香槟金」这类口语写法），塞进 `template.fields` 会让
/// 每行模板背着几十条值；而「车型」是可穷举的七类，且参与服务端
/// `required_full` 判定，必须由服务端模板下发。故本文件只承载「输入辅助」，
/// 不参与任何必填判定。
///
/// **为什么车牌是单键而不是三键**：三段（省 / 字母 / 号码）只是输入方式，
/// 产品语义是「一个车牌号」。拆成三个键会让 `template_values` 出现半截值
/// （选了省没填号码），也会让详情页多出三行；拼成 `皖A12345` 一个字符串，
/// 空段即整体未填（见 [composePlate]）。
///
/// **与模板的同步纪律**：品牌与颜色的候选值同时出现在本文件与
/// `V28__template_car_fields.sql` 的 301 模板里（服务端下发同一份），
/// 改动须两处同时改，否则「服务端模板到达后」与「本地降级」会显示不同选单。
library;

/// 品牌字段键（服务端模板与本地模板共用）。
const String kCarBrandFieldKey = 'car_brand';

/// 车型字段键。沿用 V4 老键，类型由 text 改为 select，历史值不清洗。
const String kCarModelFieldKey = 'car_model';

/// 颜色字段键。
const String kCarColorFieldKey = 'car_color';

/// 车牌字段键。值形态为 `皖A12345`（单字符串）。
const String kPlateFieldKey = 'plate_no';

/// 车型候选值：车身形式七类（§5.4.3 拼车附加字段）。
///
/// 只做下拉不开放手填：车身形式本身可穷举，开放手填只会重新引入
/// 「轿车 / 小轿车 / 三厢轿车」这类发散写法。
const List<String> kCarModelOptions = <String>[
  '轿车',
  'SUV',
  'MPV',
  '跑车',
  '微面',
  '皮卡',
  '其他',
];

/// 品牌候选值：前 6 个为面板首屏热门，其余按常见度排列。
///
/// 不在表内的品牌走「手动输入」兜底（[allowsCustomOption]），手填值原样入库，
/// 不回写本表。
const List<String> kCarBrandOptions = <String>[
  '比亚迪',
  '大众',
  '丰田',
  '本田',
  '日产',
  '吉利',
  '长安',
  '特斯拉',
  '宝马',
  '奔驰',
  '奥迪',
  '别克',
  '雪佛兰',
  '福特',
  '现代',
  '起亚',
  '马自达',
  '斯柯达',
  '标致',
  '雪铁龙',
  '雷克萨斯',
  '凯迪拉克',
  '沃尔沃',
  '林肯',
  '捷豹',
  '保时捷',
  '长城',
  '奇瑞',
  '荣威',
  '名爵',
  '五菱',
  '红旗',
  '哈弗',
  '传祺',
  '领克',
  '蔚来',
  '小鹏',
  '理想',
  '哪吒',
  '零跑',
  '埃安',
  '极氪',
  '腾势',
];

/// 颜色候选值：五个常用色，其余口令写法走手填。
const List<String> kCarColorOptions = <String>[
  '白色',
  '黑色',
  '银色',
  '灰色',
  '蓝色',
];

/// 车牌省份简称（31 个省级行政区，不含港澳台）。
const List<String> kPlateProvinces = <String>[
  '京', '津', '冀', '晋', '蒙', '辽', '吉', '黑',
  '沪', '苏', '浙', '皖', '闽', '赣', '鲁', '豫',
  '鄂', '湘', '粤', '桂', '琼', '渝', '川', '贵',
  '云', '藏', '陕', '甘', '青', '宁', '新',
];

/// 发牌机关代号：A–Z 去掉 I 与 O（与 1 / 0 易混，实际号牌不使用）。
const List<String> kPlateLetters = <String>[
  'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'J', 'K', 'L', 'M',
  'N', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
];

/// 该字段是否允许「下拉之外再手填」。
///
/// 参数 [fieldKey] 模板字段键。
/// 返回：品牌与颜色为 true（长尾值必须能录进来），其余为 false。
bool allowsCustomOption(String fieldKey) =>
    fieldKey == kCarBrandFieldKey || fieldKey == kCarColorFieldKey;

/// 手填入口的字数上限（null 表示不限制）。
///
/// 参数 [fieldKey] 模板字段键。
/// 返回：品牌 12 字、颜色 8 字；其它字段返回 null（走模板自带 maxLength）。
int? customOptionMaxLength(String fieldKey) => switch (fieldKey) {
  kCarBrandFieldKey => NfrPublishCarLimits.brandMaxLength,
  kCarColorFieldKey => NfrPublishCarLimits.colorMaxLength,
  _ => null,
};

/// 车辆字段的字数上限（与 `NfrPublish` 同源，集中一处避免散落字面量）。
///
/// 之所以不直接放进 `NfrPublish`：那组常量是「拼车出发时间控件」的，
/// 这组是「车辆信息字段」的，混在一起会让后续按域查常量时找不到边界。
class NfrPublishCarLimits {
  const NfrPublishCarLimits._();

  /// 品牌名手填上限（字）。
  static const int brandMaxLength = 12;

  /// 颜色手填上限（字）。
  static const int colorMaxLength = 8;

  /// 车牌号码段最少位数（位）。
  static const int plateCodeMinLength = 5;

  /// 车牌号码段最多位数（位）：新能源号牌为 6 位。
  static const int plateCodeMaxLength = 6;
}

/// 车牌三段拼成存储值。
///
/// 参数 [province] 省份简称；[letter] 发牌机关字母；[code] 号码段。
/// 返回：三段齐全时为 `皖A12345` 形态；任一段为空返回空串
///   （半截车牌没有意义，且会让必填判定与展示都变脏）。
String composePlate({
  required String province,
  required String letter,
  required String code,
}) {
  final cleanedCode = _cleanPlateCode(code);
  if (province.isEmpty || letter.isEmpty || cleanedCode.isEmpty) return '';
  return '$province$letter$cleanedCode';
}

/// 把存储值拆回三段，供控件回显与旧值兼容。
///
/// 参数 [raw] `template_values['plate_no']` 原值（可能是完整车牌、缺段值
///   或历史自由文本）。
/// 返回：三段；识别不出省份或字母时对应段为空串，剩余部分当号码段。
({String province, String letter, String code}) splitPlate(String raw) {
  final text = raw.trim().toUpperCase();
  if (text.isEmpty) {
    return (province: '', letter: '', code: '');
  }
  final first = text.substring(0, 1);
  final province = kPlateProvinces.contains(first) ? first : '';
  var rest = province.isEmpty ? text : text.substring(1);
  var letter = '';
  if (rest.isNotEmpty) {
    final head = rest.substring(0, 1);
    if (kPlateLetters.contains(head)) {
      letter = head;
      rest = rest.substring(1);
    }
  }
  return (province: province, letter: letter, code: _cleanPlateCode(rest));
}

/// 车牌的展示文案：`皖A12345` → `皖A·12345`。
///
/// 参数 [raw] 存储值。
/// 返回：三段齐全时带间隔点；缺段或历史自由文本原样返回（不清洗旧值，
///   与出发时间同一条纪律）。
String formatPlate(String raw) {
  final parts = splitPlate(raw);
  if (parts.province.isEmpty || parts.letter.isEmpty || parts.code.isEmpty) {
    return raw;
  }
  return '${parts.province}${parts.letter}·${parts.code}';
}

/// 号码段字符清洗：只留字母数字并转大写。
///
/// 参数 [code] 用户输入的号码段。
/// 返回：清洗后的字符串（可能为空）。
String _cleanPlateCode(String code) =>
    code.trim().toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
