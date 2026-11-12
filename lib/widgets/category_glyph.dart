import 'package:flutter/material.dart';

/// 需要自绘的类目字形名（与 `pendingCustomIconNames` 对应）。
///
/// 为什么不用 Material 字形：宠物族的五个叶子都要求「出现动物形象」，
/// 内置库里只有笼统的 `pets` 爪印，五个叶子会撞成同一个图形。
/// 这里用「猫头 + 容器/动作」统一构造，保证 20px 下仍能靠外轮廓区分。
const Set<String> customGlyphNames = {
  // 宠物族（猫头主体 + 容器/动作）
  'PAW:house',
  'PAW:heart',
  'PAW:bag',
  'PAW:walk',
  'PAW:cross',
  // 车辆族：顺风车/拼车
  'CARPOOL',
  'COMMUTE',
  'CROSS_CITY',
  'WEEKEND',
  'FLIGHT',
  'LONGTERM',
  // 车辆族：租车/借车
  'CARKEY',
  'KEY',
  'TRUCK',
  'BUS',
  'CAR_BOW',
  'PAPER',
  // 车辆族：二手车转让（车商走 Material，其余四类自绘）
  'CAR_PERSON',
  'SEDAN',
  'SUV',
  'DUMP',
  // 车辆族：求搭车/求拼
  'HITCH',
  'HITCH_ROAD',
  'HITCH_CAL',
  'HITCH_ROUTE',
  // 服务/生活杂项
  'BRUSH',
  'SQUEEGEE',
  'MISC_WORK',
  'SOFA_TV',
  'FIX_APPLIANCE',
  'WATER_ELEC',
  'MOP',
  'ART_MUSIC',
  'MASSAGE',
  'TICKET',
  'JUNK',
};

/// 该字形名是否走自绘。
///
/// 参数：`name` 为类目树里的图标名，可能为空（服务端未下发）。
/// 返回：命中自绘集合时为 true，调用方应改用 [CategoryGlyph] 渲染。
bool hasCustomCategoryGlyph(String? name) => name != null && customGlyphNames.contains(name);

/// 类目图标统一入口：自绘优先，其余退回 Material 字形。
///
/// 参数：
/// - `name`：类目树里的图标名（如 `PAW:house`）；
/// - `icon`：已解析的 Material 字形，自绘未命中时使用；
/// - `size`：绘制边长（正方形）；
/// - `color`：填充色。
/// 返回：自绘命中时为 [CustomPaint]，否则为 [Icon]。
class CategoryGlyph extends StatelessWidget {
  /// 创建类目图标。
  const CategoryGlyph({
    super.key,
    required this.name,
    required this.icon,
    required this.color,
    this.size = 20,
  });

  /// 类目树里的图标名。
  final String? name;

  /// Material 兜底字形。
  final IconData? icon;

  /// 填充色。
  final Color color;

  /// 边长。
  final double size;

  @override
  Widget build(BuildContext context) {
    if (hasCustomCategoryGlyph(name)) {
      return CustomPaint(
        size: Size.square(size),
        painter: CategoryGlyphPainter(name: name!, color: color),
      );
    }
    return Icon(icon ?? Icons.category_outlined, size: size, color: color);
  }
}

/// 类目自绘笔：在 24×24 视口里画路径，再按目标边长整体缩放。
///
/// 所有图形共用一个「猫头」子路径：寄养/领养/医疗把它从容器里挖空，
/// 用品与代遛直接以猫头为主体，从而在同一族内保持「动物」识别。
class CategoryGlyphPainter extends CustomPainter {
  /// 创建画笔。
  ///
  /// 参数：`name` 为自绘字形名；`color` 为填充色。
  CategoryGlyphPainter({required this.name, required this.color});

  /// 自绘字形名。
  final String name;

  /// 填充色。
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 24.0;
    canvas.save();
    canvas.scale(scale);
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    switch (name) {
      case 'PAW:house':
        canvas.drawPath(_subtract(_house(), _catHead(const Offset(12, 14), 4.0)), fill);
        break;
      case 'PAW:heart':
        canvas.drawPath(_subtract(_heart(), _catHead(const Offset(12, 12.5), 4.0)), fill);
        break;
      case 'PAW:bag':
        canvas.drawPath(_bowl(), fill);
        canvas.drawPath(_bone(), fill);
        break;
      case 'PAW:walk':
        canvas.drawPath(_catHead(const Offset(10.5, 10.5), 4.2), fill);
        // 牵引绳：从猫头右下绕到右下方，末端一个环。
        final leash = Path()
          ..moveTo(13.5, 12.4)
          ..quadraticBezierTo(18.6, 14.4, 17.8, 19.2);
        canvas.drawPath(leash, stroke);
        canvas.drawCircle(const Offset(17.8, 20.4), 1.5, fill);
        break;
      case 'PAW:cross':
        // 猫头在上、医疗十字在下「分体并置」：18px 下挖空会把十字切成散点，
        // 并排又会互相挤压，只有上下分工能让两个记号各自完整可辨。
        final petCross = Path()
          ..addRect(const Rect.fromLTRB(9.8, 12.4, 14.2, 21.4))
          ..addRect(const Rect.fromLTRB(5.6, 15.4, 18.4, 18.4));
        canvas.drawPath(petCross, fill);
        canvas.drawPath(_catHead(const Offset(12, 7.4), 4.0), fill);
        break;
      // ---- 车辆族：车体固定在下半区，区分靠上半区的「时段/场景」元素 ----
      case 'CARPOOL':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_heads(const [Offset(9, 5.5), Offset(15, 5.5)]), fill);
        break;
      case 'COMMUTE':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_office(), fill);
        break;
      case 'CROSS_CITY':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_crossCityMark(), fill);
        break;
      case 'WEEKEND':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(
          _heads(const [Offset(8, 5), Offset(13, 4), Offset(18, 5)]),
          fill,
        );
        break;
      case 'FLIGHT':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_plane(), fill);
        break;
      case 'LONGTERM':
        canvas.drawPath(_car(), fill);
        // 环用描边（保证在 18px 下不被填实成一坨），箭头用填充。
        final ringPaint = Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..isAntiAlias = true;
        canvas.drawPath(_longTermRing(), ringPaint);
        canvas.drawPath(_longTermHead(), fill);
        break;
      case 'CARKEY':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_key(const Offset(17.5, 7), 2.4), fill);
        break;
      case 'KEY':
        canvas.drawPath(_key(const Offset(13, 12), 4.2), fill);
        break;
      case 'TRUCK':
        canvas.drawPath(_truck(), fill);
        break;
      case 'BUS':
        canvas.drawPath(_bus(), fill);
        break;
      case 'CAR_BOW':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_bow(), fill);
        break;
      case 'PAPER':
        canvas.drawPath(_paper(), fill);
        break;
      case 'HITCH':
        canvas.drawPath(_hitchhiker(), fill);
        canvas.drawPath(_roadDashes(2), fill);
        break;
      case 'HITCH_ROAD':
        canvas.drawPath(_hitchhiker(), fill);
        canvas.drawPath(_roadDashes(4), fill);
        break;
      case 'HITCH_CAL':
        canvas.drawPath(_hitchhiker(), fill);
        canvas.drawPath(_calendar(), fill);
        break;
      case 'HITCH_ROUTE':
        canvas.drawPath(_hitchhiker(), fill);
        canvas.drawPath(_pin(const Offset(18, 6)), fill);
        break;
      // ---- 二手车转让：靠车身形态区分，而不是靠「车主/车商」文字 ----
      case 'CAR_PERSON':
        canvas.drawPath(_car(), fill);
        canvas.drawPath(_headInWindow(), fill);
        break;
      case 'SEDAN':
        canvas.drawPath(_sedan(), fill);
        break;
      case 'SUV':
        canvas.drawPath(_suv(), fill);
        break;
      case 'DUMP':
        canvas.drawPath(_dumpTruck(), fill);
        break;
      // ---- 服务/生活杂项：一件实物 + 一个动作/场景，避免抽象符号 ----
      case 'BRUSH':
        canvas.drawPath(_brush(), fill);
        break;
      case 'SQUEEGEE':
        canvas.drawPath(_squeegee(), fill);
        break;
      case 'MISC_WORK':
        canvas.drawPath(_briefcase(), fill);
        break;
      case 'SOFA_TV':
        canvas.drawPath(_sofaTv(), fill);
        break;
      case 'FIX_APPLIANCE':
        canvas.drawPath(_fixAppliance(), fill);
        break;
      case 'WATER_ELEC':
        canvas.drawPath(_waterElec(), fill);
        break;
      case 'MOP':
        canvas.drawPath(_mop(), fill);
        break;
      case 'ART_MUSIC':
        canvas.drawPath(_artMusic(), fill);
        break;
      case 'MASSAGE':
        canvas.drawPath(_massage(), fill);
        break;
      case 'TICKET':
        canvas.drawPath(_ticket(), fill);
        break;
      case 'JUNK':
        canvas.drawPath(_junkBox(), fill);
        break;
      default:
        break;
    }
    canvas.restore();
  }

  /// 从容器里挖出猫头（差额填充，形成镂空）。
  ///
  /// 参数：`outer` 容器路径；`hole` 猫头路径。
  /// 返回：带镂空的路径。
  Path _subtract(Path outer, Path hole) =>
      Path.combine(PathOperation.difference, outer, hole);

  /// 猫头（圆头 + 两只三角耳），中心与半径可调。
  ///
  /// 参数：`center` 头心；`r` 头半径。
  /// 返回：猫头路径。
  Path _catHead(Offset center, double r) {
    final head = Path()..addOval(Rect.fromCircle(center: center, radius: r));
    final leftEar = Path()
      ..moveTo(center.dx - r * 0.95, center.dy - r * 0.45)
      ..lineTo(center.dx - r * 0.75, center.dy - r * 1.75)
      ..lineTo(center.dx - r * 0.05, center.dy - r * 0.95)
      ..close();
    final rightEar = Path()
      ..moveTo(center.dx + r * 0.95, center.dy - r * 0.45)
      ..lineTo(center.dx + r * 0.75, center.dy - r * 1.75)
      ..lineTo(center.dx + r * 0.05, center.dy - r * 0.95)
      ..close();
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, head, leftEar),
      rightEar,
    );
  }

  /// 狗屋（屋顶 + 屋身）。
  ///
  /// 返回：屋形路径。
  Path _house() {
    final p = Path()
      ..moveTo(3.5, 11.5)
      ..lineTo(12, 5)
      ..lineTo(20.5, 11.5)
      ..lineTo(20.5, 20)
      ..lineTo(3.5, 20)
      ..close();
    return p;
  }

  /// 爱心（用于「宠物领养」）。
  ///
  /// 返回：心形路径。
  Path _heart() {
    return Path()
      ..moveTo(12, 20.5)
      ..cubicTo(2.5, 13.5, 4.2, 5.2, 9.2, 5.2)
      ..cubicTo(10.9, 5.2, 12, 6.6, 12, 7.8)
      ..cubicTo(12, 6.6, 13.1, 5.2, 14.8, 5.2)
      ..cubicTo(19.8, 5.2, 21.5, 13.5, 12, 20.5)
      ..close();
  }

  /// 食盆（上宽下窄的碗）。
  ///
  /// 返回：碗形路径。
  Path _bowl() {
    return Path()
      ..moveTo(3.5, 15.5)
      ..lineTo(20.5, 15.5)
      ..lineTo(18, 20.5)
      ..lineTo(6, 20.5)
      ..close();
  }

  /// 骨头（横置：中段 + 四颗圆头）。
  ///
  /// 返回：骨头路径。
  Path _bone() {
    final p = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTRB(7.6, 8.6, 16.4, 11.4),
          const Radius.circular(1.2),
        ),
      );
    for (final x in [7.6, 16.4]) {
      p.addOval(Rect.fromCircle(center: Offset(x, 8.6), radius: 1.5));
      p.addOval(Rect.fromCircle(center: Offset(x, 11.4), radius: 1.5));
    }
    return p;
  }

  // ---------------------------------------------------------------------------
  // 车辆族构件（24×24 视口）
  // ---------------------------------------------------------------------------

  /// 圆角矩形路径。
  ///
  /// 参数：`rect` 外框；`radius` 圆角。
  /// 返回：路径。
  Path _rounded(Rect rect, double radius) => Path()
    ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

  /// 侧视轿车：车身 + 镂空车窗 + 两只轮子。
  ///
  /// 车体固定在下半区（y 12–21），上半区留给「时段/场景」元素叠加，
  /// 这样同一族的五个叶子共享车体轮廓，只在顶部产生差异。
  /// 返回：车形路径。
  Path _car() {
    final body = _rounded(const Rect.fromLTRB(2, 12, 22, 18.6), 2.2);
    final window = _rounded(const Rect.fromLTRB(6, 13.6, 16.6, 16.2), 1.2);
    final wheels = Path()
      ..addOval(Rect.fromCircle(center: const Offset(7, 19), radius: 2.1))
      ..addOval(Rect.fromCircle(center: const Offset(17, 19), radius: 2.1));
    return Path.combine(PathOperation.union, _subtract(body, window), wheels);
  }

  /// 若干个头（表达「多人同乘」）。
  ///
  /// 参数：`centers` 头心坐标；半径固定 2.0（20px 下仍可分辨个体）。
  /// 返回：合并后的路径。
  Path _heads(List<Offset> centers) {
    final p = Path();
    for (final c in centers) {
      p.addOval(Rect.fromCircle(center: c, radius: 2.0));
    }
    return p;
  }

  /// 办公楼：**竖长塔楼** + 三个镂空窗格，用于「上下班拼车」。
  ///
  /// 形状刻意做成「高瘦竖条」，与跨城的横向线、长期的环形形成轮廓级差异，
  /// 避免 18px 下三个叶子都读成「车上一个方块」。
  /// 返回：楼体路径。
  Path _office() {
    final body = _rounded(const Rect.fromLTRB(13.0, 1.4, 18.2, 10.6), 1.0);
    final windows = Path()
      ..addRect(const Rect.fromLTRB(14.2, 2.8, 17.0, 4.2))
      ..addRect(const Rect.fromLTRB(14.2, 5.2, 17.0, 6.6))
      ..addRect(const Rect.fromLTRB(14.2, 7.6, 17.0, 9.0));
    return _subtract(body, windows);
  }

  /// 跨城标记：**两端地点 + 中间虚线**，用于「跨城顺风车」。
  ///
  /// 用「两点一线」表达两地之间，横向铺满顶部；不放矩形牌，
  /// 避免与办公楼的竖块、长期环在同一尺寸下混淆。
  /// 返回：标记路径。
  Path _crossCityMark() {
    return Path()
      ..addOval(Rect.fromCircle(center: const Offset(4.2, 5.8), radius: 1.9))
      ..addOval(Rect.fromCircle(center: const Offset(19.8, 5.8), radius: 1.9))
      ..addRect(const Rect.fromLTRB(7.4, 5.0, 9.8, 6.6))
      ..addRect(const Rect.fromLTRB(11.0, 5.0, 13.4, 6.6))
      ..addRect(const Rect.fromLTRB(14.6, 5.0, 17.0, 6.6));
  }

  /// 长期标记的环身（开口圆弧），用于「长期拼车」。
  ///
  /// 环是唯一没有直边的形状，在 18px 下与竖楼、横线一望即分。
  /// 返回：圆弧路径（按描边绘制）。
  Path _longTermRing() => Path()
    ..addArc(
      Rect.fromCircle(center: const Offset(12, 6.2), radius: 4.3),
      0.55,
      4.55,
    );

  /// 长期标记的箭头（循环方向），用于「长期拼车」。
  ///
  /// 返回：三角箭头路径（按填充绘制）。
  Path _longTermHead() => Path()
    ..moveTo(14.9, 1.1)
    ..lineTo(19.5, 2.9)
    ..lineTo(15.3, 5.1)
    ..close();

  /// 飞机剪影，用于「机场/车站接送」。
  ///
  /// 返回：飞机路径。
  Path _plane() {
    return Path()
      ..moveTo(3, 13)
      ..lineTo(10.8, 12.2)
      ..lineTo(14.6, 5.8)
      ..lineTo(16.6, 6.2)
      ..lineTo(14.2, 12.4)
      ..lineTo(20, 14)
      ..lineTo(20, 15.6)
      ..lineTo(11, 14.6)
      ..lineTo(9.2, 18)
      ..lineTo(7.6, 17.4)
      ..lineTo(8.4, 14.2)
      ..lineTo(3, 14.4)
      ..close();
  }

  /// 钥匙：圆头 + 杆 + 两齿。
  ///
  /// 参数：`head` 圆头中心；`r` 圆头半径（其余尺寸按比例给出）。
  /// 返回：钥匙路径。
  Path _key(Offset head, double r) {
    final stem = Rect.fromLTRB(
      head.dx + r * 0.7,
      head.dy - r * 0.22,
      head.dx + r * 2.1,
      head.dy + r * 0.22,
    );
    final p = Path()
      ..addOval(Rect.fromCircle(center: head, radius: r))
      ..addRect(stem)
      ..addRect(Rect.fromLTRB(stem.right - r * 0.35, stem.bottom, stem.right, stem.bottom + r * 0.8))
      ..addRect(Rect.fromLTRB(stem.right - r * 0.95, stem.bottom, stem.right - r * 0.6, stem.bottom + r * 0.6));
    return p;
  }

  /// 厢式货车：货箱 + 驾驶室 + 镂空车窗 + 两轮。
  ///
  /// 返回：车形路径。
  Path _truck() {
    final cargo = _rounded(const Rect.fromLTRB(2.5, 8, 14, 16), 1.2);
    final cab = Path()
      ..moveTo(14, 11)
      ..lineTo(18.6, 11)
      ..lineTo(20.6, 13.8)
      ..lineTo(20.6, 16)
      ..lineTo(14, 16)
      ..close();
    final window = Path()..addRect(const Rect.fromLTRB(15.2, 12.2, 18.2, 14.2));
    final wheels = Path()
      ..addOval(Rect.fromCircle(center: const Offset(6.5, 17.4), radius: 2.0))
      ..addOval(Rect.fromCircle(center: const Offset(17, 17.4), radius: 2.0));
    final shell = Path.combine(PathOperation.union, cargo, cab);
    return Path.combine(
      PathOperation.union,
      _subtract(shell, window),
      wheels,
    );
  }

  /// 大巴：车厢 + 镂空窗带 + 两轮。
  ///
  /// 返回：车形路径。
  Path _bus() {
    final body = _rounded(const Rect.fromLTRB(3, 5, 21, 16.6), 2.2);
    final windows = _rounded(const Rect.fromLTRB(5, 7.2, 19, 10.8), 0.8);
    final wheels = Path()
      ..addOval(Rect.fromCircle(center: const Offset(7.5, 17.6), radius: 1.9))
      ..addOval(Rect.fromCircle(center: const Offset(16.5, 17.6), radius: 1.9));
    return Path.combine(PathOperation.union, _subtract(body, windows), wheels);
  }

  /// 车顶缎带（婚车）：左右两片 + 结。
  ///
  /// 返回：缎带路径。
  Path _bow() {
    final p = Path()
      ..moveTo(12, 5)
      ..lineTo(7.2, 2)
      ..lineTo(7.2, 7.4)
      ..close()
      ..moveTo(12, 5)
      ..lineTo(16.8, 2)
      ..lineTo(16.8, 7.4)
      ..close()
      ..addOval(Rect.fromCircle(center: const Offset(12, 5), radius: 1.5));
    return p;
  }

  /// 合同页（两条镂空文字行 + 印章），用于「以租代购」。
  ///
  /// 返回：文书路径。
  Path _paper() {
    final body = _rounded(const Rect.fromLTRB(7.5, 2.5, 17.5, 19.5), 1.4);
    final lines = Path()
      ..addRect(const Rect.fromLTRB(9.6, 6, 15.4, 7.2))
      ..addRect(const Rect.fromLTRB(9.6, 9, 15.4, 10.2))
      ..addRect(const Rect.fromLTRB(9.6, 12, 13.6, 13.2));
    final seal = Path()..addOval(Rect.fromCircle(center: const Offset(15, 16.4), radius: 2.2));
    return Path.combine(PathOperation.union, _subtract(body, lines), seal);
  }

  /// 搭车人：头 + 身 + 抬起的手臂 + 双腿。
  ///
  /// 返回：人形路径。
  Path _hitchhiker() {
    final head = Path()..addOval(Rect.fromCircle(center: const Offset(9.2, 5.4), radius: 2.2));
    final torso = _rounded(const Rect.fromLTRB(7.4, 7.6, 11.2, 15.2), 1.6);
    final arm = Path()
      ..moveTo(10.6, 9.2)
      ..lineTo(15.4, 5.4)
      ..lineTo(16.5, 6.8)
      ..lineTo(11.6, 10.8)
      ..close();
    final legs = Path()
      ..addRect(const Rect.fromLTRB(7.6, 14.4, 9.2, 19.4))
      ..addRect(const Rect.fromLTRB(9.6, 14.4, 11.2, 19.4));
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, head, torso),
      Path.combine(PathOperation.union, arm, legs),
    );
  }

  /// 路面虚线（个数可调，用于区分「求搭车」与「顺路捎带」）。
  ///
  /// 参数：`count` 虚线块数量。
  /// 返回：虚线路径。
  Path _roadDashes(int count) {
    final p = Path();
    for (var i = 0; i < count; i++) {
      final x = 3.0 + i * 4.4;
      p.addRect(Rect.fromLTRB(x, 20.6, x + 2.6, 22));
    }
    return p;
  }

  /// 定位针（圆头 + 尖脚），用于「顺路捎带」。
  ///
  /// 参数：`center` 圆头中心。
  /// 返回：针形路径。
  Path _pin(Offset center) {
    final head = Path()..addOval(Rect.fromCircle(center: center, radius: 3.0));
    final tip = Path()
      ..moveTo(center.dx - 1.9, center.dy + 2.0)
      ..lineTo(center.dx, center.dy + 5.2)
      ..lineTo(center.dx + 1.9, center.dy + 2.0)
      ..close();
    return Path.combine(PathOperation.union, head, tip);
  }

  /// 日历（挂环 + 页身 + 镂空标题条），用于「长期拼车求带」。
  ///
  /// 与搭车人同图：人 + 日历 = 「按天/按长期约」。标题条做镂空，
  /// 保证 18px 下仍能看出「这是日历而不是方块」。
  /// 返回：日历路径。
  Path _calendar() {
    final body = _rounded(const Rect.fromLTRB(13.4, 4.6, 22.6, 11.8), 1.2);
    final header = Path()..addRect(const Rect.fromLTRB(14.6, 5.6, 21.4, 7.2));
    final rings = Path()
      ..addRect(const Rect.fromLTRB(15.2, 2.6, 16.6, 5.4))
      ..addRect(const Rect.fromLTRB(19.4, 2.6, 20.8, 5.4));
    return Path.combine(
      PathOperation.union,
      _subtract(body, header),
      rings,
    );
  }

  /// 车窗里的一个头，用于「个人二手车」（车主在车里）。
  ///
  /// 车窗本身是镂空，这里在洞内补一个实心圆，读作「车里坐着人」。
  /// 返回：头部路径。
  Path _headInWindow() => Path()
    ..addOval(Rect.fromCircle(center: const Offset(11.2, 15.0), radius: 1.5));

  /// 三厢轿车：低矮、长机盖 + 长短尾。
  ///
  /// 与通用车体（[`_car`]）的区别：轮廓是多边形而非圆角矩形，
  /// 20px 下能看出「长头长尾」，与 SUV 的方盒形形成对比。
  /// 返回：车形路径。
  Path _sedan() {
    final body = Path()
      ..moveTo(1.6, 18)
      ..lineTo(2.8, 14.6)
      ..lineTo(6.4, 14)
      ..lineTo(8.8, 11)
      ..lineTo(15.2, 11)
      ..lineTo(17.6, 14)
      ..lineTo(21.2, 14.6)
      ..lineTo(22.4, 18)
      ..close();
    final window = Path()..addRect(const Rect.fromLTRB(9.4, 12.2, 14.6, 14.2));
    final wheels = Path()
      ..addOval(Rect.fromCircle(center: const Offset(6.4, 18.4), radius: 2.0))
      ..addOval(Rect.fromCircle(center: const Offset(17.6, 18.4), radius: 2.0));
    return Path.combine(PathOperation.union, _subtract(body, window), wheels);
  }

  /// SUV/MPV：方盒车身 + 平顶 + 高腰线。
  ///
  /// 与轿车的对比点是「高、方、窗带宽」，不靠细节纹理。
  /// 返回：车形路径。
  Path _suv() {
    final body = _rounded(const Rect.fromLTRB(2.4, 9.4, 21.6, 17.8), 1.6);
    final roof = _rounded(const Rect.fromLTRB(5.6, 8.2, 18.4, 10.2), 0.9);
    final window = _rounded(const Rect.fromLTRB(4.6, 11.2, 19.4, 14.2), 0.7);
    final wheels = Path()
      ..addOval(Rect.fromCircle(center: const Offset(7, 18.4), radius: 2.2))
      ..addOval(Rect.fromCircle(center: const Offset(17, 18.4), radius: 2.2));
    final shell = Path.combine(PathOperation.union, body, roof);
    return Path.combine(PathOperation.union, _subtract(shell, window), wheels);
  }

  /// 货车/工程车：抬起的自卸斗 + 驾驶室 + 两轮。
  ///
  /// 自卸斗向后上方倾斜是工程车最强的识别特征，比车头细节更耐缩小。
  /// 返回：车形路径。
  Path _dumpTruck() {
    final tipper = Path()
      ..moveTo(2, 7.6)
      ..lineTo(12.4, 5.4)
      ..lineTo(12.4, 11.6)
      ..lineTo(2, 11.6)
      ..close();
    final cab = Path()
      ..moveTo(13, 9.6)
      ..lineTo(18.4, 9.6)
      ..lineTo(21, 12.6)
      ..lineTo(21, 15.4)
      ..lineTo(13, 15.4)
      ..close();
    final window = Path()..addRect(const Rect.fromLTRB(14.4, 10.8, 17.4, 12.8));
    final wheels = Path()
      ..addOval(Rect.fromCircle(center: const Offset(5.6, 16.8), radius: 2.0))
      ..addOval(Rect.fromCircle(center: const Offset(16.6, 16.8), radius: 2.0));
    final shell = Path.combine(PathOperation.union, tipper, cab);
    return Path.combine(PathOperation.union, _subtract(shell, window), wheels);
  }

  /// 刷子（美发造型）：斜柄 + 刷头 + 三道刷毛缝。
  ///
  /// 返回：刷子路径。
  Path _brush() {
    final handle = Path()
      ..moveTo(14.6, 2.4)
      ..lineTo(19.6, 5.2)
      ..lineTo(12, 15.2)
      ..lineTo(7.6, 12.4)
      ..close();
    final head = _rounded(const Rect.fromLTRB(4.6, 13, 12, 21), 1.4);
    final slots = Path()
      ..addRect(const Rect.fromLTRB(5.9, 17, 6.9, 20.2))
      ..addRect(const Rect.fromLTRB(7.8, 17, 8.8, 20.2))
      ..addRect(const Rect.fromLTRB(9.7, 17, 10.7, 20.2));
    return Path.combine(PathOperation.union, handle, _subtract(head, slots));
  }

  /// 刮水器 + 亮星（玻璃/窗户清洗）。
  ///
  /// 返回：刮水器路径。
  Path _squeegee() {
    final blade = _rounded(const Rect.fromLTRB(2.6, 13.6, 18, 16.8), 1.2);
    final handle = Path()..addRect(const Rect.fromLTRB(9.4, 5.6, 11.2, 13.8));
    final star = Path()
      ..moveTo(18.6, 3)
      ..lineTo(19.5, 5.6)
      ..lineTo(22, 6.5)
      ..lineTo(19.5, 7.4)
      ..lineTo(18.6, 10)
      ..lineTo(17.7, 7.4)
      ..lineTo(15.2, 6.5)
      ..lineTo(17.7, 5.6)
      ..close();
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, blade, handle),
      star,
    );
  }

  /// 公文包 + 三个镂空点（其他全职）。
  ///
  /// 返回：公文包路径。
  Path _briefcase() {
    final body = _rounded(const Rect.fromLTRB(2.8, 8, 21.2, 20), 1.8);
    final handleOuter = _rounded(const Rect.fromLTRB(9.2, 5.2, 14.8, 9), 1.2);
    final handleInner = _rounded(const Rect.fromLTRB(10.6, 6.4, 13.4, 9.4), 0.8);
    final dots = Path()
      ..addOval(Rect.fromCircle(center: const Offset(7.6, 14), radius: 1.0))
      ..addOval(Rect.fromCircle(center: const Offset(12, 14), radius: 1.0))
      ..addOval(Rect.fromCircle(center: const Offset(16.4, 14), radius: 1.0));
    final shell = Path.combine(
      PathOperation.union,
      body,
      _subtract(handleOuter, handleInner),
    );
    return _subtract(shell, dots);
  }

  /// 沙发 + 电视（家具家电转让）。
  ///
  /// 返回：组合路径。
  Path _sofaTv() {
    final tv = _rounded(const Rect.fromLTRB(6.4, 2.4, 17.6, 9), 1.0);
    final screen = _rounded(const Rect.fromLTRB(7.8, 3.8, 16.2, 7.4), 0.6);
    final back = _rounded(const Rect.fromLTRB(2, 11, 22, 14.6), 1.0);
    final seat = _rounded(const Rect.fromLTRB(3.4, 14, 20.6, 19.4), 1.2);
    final arms = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTRB(1.6, 12, 5, 19),
          const Radius.circular(1.2),
        ),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTRB(19, 12, 22.4, 19),
          const Radius.circular(1.2),
        ),
      );
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, _subtract(tv, screen), back),
      Path.combine(PathOperation.union, seat, arms),
    );
  }

  /// 家电 + 螺丝刀（家电维修）。
  ///
  /// 返回：组合路径。
  Path _fixAppliance() {
    final box = _rounded(const Rect.fromLTRB(2.4, 6.6, 14.2, 20.4), 1.8);
    final door = Path()..addOval(Rect.fromCircle(center: const Offset(8.3, 13.5), radius: 2.6));
    final handle = Path()
      ..moveTo(15.8, 4.4)
      ..lineTo(20.2, 3.2)
      ..lineTo(21.2, 6.4)
      ..lineTo(16.8, 7.6)
      ..close();
    final shaft = Path()..addRect(const Rect.fromLTRB(17.4, 7.2, 19.4, 18.6));
    return Path.combine(
      PathOperation.union,
      _subtract(box, door),
      Path.combine(PathOperation.union, handle, shaft),
    );
  }

  /// 水滴 + 闪电（水电维修）。
  ///
  /// 返回：组合路径。
  Path _waterElec() {
    final drop = Path()
      ..moveTo(8, 2.8)
      ..cubicTo(4.4, 8.4, 4.4, 11.2, 6, 12.8)
      ..cubicTo(7.6, 14.4, 10.4, 14, 11.4, 12.2)
      ..cubicTo(12.4, 10.4, 11.4, 7.4, 8, 2.8)
      ..close();
    final bolt = Path()
      ..moveTo(18.4, 6)
      ..lineTo(13.4, 14.6)
      ..lineTo(16.2, 14.6)
      ..lineTo(14, 20.8)
      ..lineTo(20.4, 11.4)
      ..lineTo(17.2, 11.4)
      ..close();
    return Path.combine(PathOperation.union, drop, bolt);
  }

  /// 拖把 + 水桶（家政保洁）。
  ///
  /// 返回：组合路径。
  Path _mop() {
    final head = _rounded(const Rect.fromLTRB(2.6, 17, 10.6, 21.6), 1.2);
    final pole = Path()
      ..moveTo(9.2, 17.4)
      ..lineTo(11.4, 18.4)
      ..lineTo(19.4, 3)
      ..lineTo(17.2, 2)
      ..close();
    final bucket = Path()
      ..moveTo(12, 14.4)
      ..lineTo(22, 14.4)
      ..lineTo(20.8, 21.2)
      ..lineTo(13.6, 21.2)
      ..close();
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, head, pole),
      bucket,
    );
  }

  /// 调色板 + 音符（艺术/乐器）。
  ///
  /// 返回：组合路径。
  Path _artMusic() {
    final palette = Path()..addOval(Rect.fromCircle(center: const Offset(8.6, 13), radius: 6.6));
    final holes = Path()
      ..addOval(Rect.fromCircle(center: const Offset(6.2, 14.4), radius: 1.4))
      ..addOval(Rect.fromCircle(center: const Offset(7.6, 9.4), radius: 0.9))
      ..addOval(Rect.fromCircle(center: const Offset(11.6, 8.6), radius: 0.9))
      ..addOval(Rect.fromCircle(center: const Offset(13.8, 12), radius: 0.9));
    final noteHead = Path()..addOval(Rect.fromCircle(center: const Offset(17.4, 17.6), radius: 2.2));
    final stem = Path()..addRect(const Rect.fromLTRB(19.2, 7, 20.4, 17.8));
    return Path.combine(
      PathOperation.union,
      _subtract(palette, holes),
      Path.combine(PathOperation.union, noteHead, stem),
    );
  }

  /// 双手 + 背（上门按摩）。
  ///
  /// 返回：组合路径。
  Path _massage() {
    final back = _rounded(const Rect.fromLTRB(8.4, 4, 16.2, 12.4), 3.2);
    final leftHand = _rounded(const Rect.fromLTRB(2.6, 9.4, 8, 15.6), 2.2);
    final rightHand = _rounded(const Rect.fromLTRB(16.6, 9.4, 22, 15.6), 2.2);
    final spine = Path()..addRect(const Rect.fromLTRB(11.8, 12.4, 12.8, 20.4));
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, back, leftHand),
      Path.combine(PathOperation.union, rightHand, spine),
    );
  }

  /// 取号单（代排队）：票据 + 两条镂空信息行。
  ///
  /// 返回：票据路径。
  Path _ticket() {
    final body = _rounded(const Rect.fromLTRB(4.6, 2.6, 19.4, 21.4), 1.6);
    final lines = Path()
      ..addRect(const Rect.fromLTRB(7.4, 7, 16.6, 8.4))
      ..addRect(const Rect.fromLTRB(7.4, 11, 16.6, 12.4))
      ..addRect(const Rect.fromLTRB(7.4, 15, 11.6, 17.2));
    return _subtract(body, lines);
  }

  /// 杂物箱（其他二手）：箱体 + 箱盖 + 顶部提手（凸起，不镂空）。
  ///
  /// 返回：箱体路径。
  Path _junkBox() {
    final box = _rounded(const Rect.fromLTRB(3.0, 9.6, 21.0, 20.6), 1.4);
    final lid = _rounded(const Rect.fromLTRB(2.0, 6.0, 22.0, 10.6), 1.2);
    // 顶部提手做「凸起」而不是横向镂空：镂空会把箱体劈成两个矩形。
    final handle = _rounded(const Rect.fromLTRB(9.2, 2.8, 14.8, 6.4), 1.2);
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, box, lid),
      handle,
    );
  }

  @override
  bool shouldRepaint(CategoryGlyphPainter oldDelegate) =>
      oldDelegate.name != name || oldDelegate.color != color;
}
