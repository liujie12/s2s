import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/widgets/category_glyph.dart';

/// 宠物族自绘的契约：五个名字都能画出来，且与 Material 兜底区分开。
///
/// 为什么要测：自绘走的是 Path 运算（含 difference 镂空），
/// 路径写错不会编译报错，只会画出空白或整块黑；20px 下肉眼也难发现。
void main() {
  const pets = ['PAW:house', 'PAW:heart', 'PAW:bag', 'PAW:walk', 'PAW:cross'];
  const vehicles = [
    'CARPOOL', 'COMMUTE', 'CROSS_CITY', 'WEEKEND', 'FLIGHT', 'LONGTERM',
    'CARKEY', 'KEY', 'TRUCK', 'BUS', 'CAR_BOW', 'PAPER',
    'CAR_PERSON', 'SEDAN', 'SUV', 'DUMP',
    'HITCH', 'HITCH_ROAD', 'HITCH_CAL', 'HITCH_ROUTE',
  ];

  const misc = [
    'BRUSH', 'SQUEEGEE', 'MISC_WORK', 'SOFA_TV', 'FIX_APPLIANCE',
    'WATER_ELEC', 'MOP', 'ART_MUSIC', 'MASSAGE', 'TICKET', 'JUNK',
  ];

  test('全部自绘字形名命中', () {
    for (final name in [...pets, ...vehicles, ...misc]) {
      expect(hasCustomCategoryGlyph(name), isTrue, reason: '$name 应走自绘');
    }
    expect(hasCustomCategoryGlyph('pets'), isFalse);
    expect(hasCustomCategoryGlyph(null), isFalse);
  });

  testWidgets('20px 下宠物与杂项绘图完成', (tester) async {
    for (final name in [...pets, ...misc]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: CategoryGlyph(
              name: name,
              icon: Icons.pets,
              size: 20,
              color: const Color(0xFFEC4899),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$name 绘制抛异常');
      expect(find.byType(CustomPaint), findsWidgets, reason: '$name 应走 CustomPaint');
    }
  });

  testWidgets('20px 下车辆绘图完成', (tester) async {
    for (final name in vehicles) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: CategoryGlyph(
              name: name,
              icon: Icons.directions_car,
              size: 20,
              color: const Color(0xFF22C55E),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull, reason: '$name 绘制抛异常');
      expect(find.byType(CustomPaint), findsWidgets, reason: '$name 应走 CustomPaint');
    }
  });

  testWidgets('未命中自绘时退回 Material 字形', (tester) async {
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: CategoryGlyph(
          name: 'restaurant',
          icon: Icons.restaurant,
          size: 20,
          color: Color(0xFF3B82F6),
        ),
      ),
    );
    expect(find.byIcon(Icons.restaurant), findsOneWidget);
  });
}
