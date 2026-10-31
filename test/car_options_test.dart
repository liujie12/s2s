/// 车辆选单常量与车牌值工具的单元测试。
///
/// 守的是三件事：候选值本身可用（无重复、省份字母齐全）、车牌三段拼接与
/// 拆分可逆、展示格式化不污染存储值。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/domain/car_options.dart';

void main() {
  group('候选值常量', () {
    test('品牌候选值非空且无重复（重复会让下拉出现同名两项）', () {
      expect(kCarBrandOptions, isNotEmpty);
      expect(kCarBrandOptions.toSet(), hasLength(kCarBrandOptions.length));
    });

    test('车型候选值为车身形式七类，且包含「其他」兜底', () {
      expect(kCarModelOptions, hasLength(7));
      expect(kCarModelOptions, contains('其他'));
    });

    test('颜色候选值为五个常用色', () {
      expect(kCarColorOptions, hasLength(5));
      expect(kCarColorOptions, contains('白色'));
    });

    test('车牌省份简称 31 个且无重复', () {
      expect(kPlateProvinces, hasLength(31));
      expect(kPlateProvinces.toSet(), hasLength(31));
      expect(kPlateProvinces, contains('皖'));
    });

    test('发牌机关字母 24 个，且不含易混的 I / O', () {
      expect(kPlateLetters, hasLength(24));
      expect(kPlateLetters, isNot(contains('I')));
      expect(kPlateLetters, isNot(contains('O')));
      expect(kPlateLetters.first, 'A');
      expect(kPlateLetters.last, 'Z');
    });

    test('只有品牌与颜色允许手填', () {
      expect(allowsCustomOption(kCarBrandFieldKey), isTrue);
      expect(allowsCustomOption(kCarColorFieldKey), isTrue);
      expect(allowsCustomOption(kCarModelFieldKey), isFalse);
      expect(allowsCustomOption(kPlateFieldKey), isFalse);
    });

    test('手填上限：品牌 12、颜色 8、车型无', () {
      expect(customOptionMaxLength(kCarBrandFieldKey), 12);
      expect(customOptionMaxLength(kCarColorFieldKey), 8);
      expect(customOptionMaxLength(kCarModelFieldKey), isNull);
    });
  });

  group('车牌拼接与拆分', () {
    test('三段齐全时拼成 皖A12345，且号码段自动大写去符号', () {
      expect(
        composePlate(province: '皖', letter: 'A', code: '12·345'),
        '皖A12345',
      );
      expect(composePlate(province: '皖', letter: 'A', code: 'd12345'), '皖AD12345');
    });

    test('任一段为空即整体未填（不产生半截值）', () {
      expect(composePlate(province: '', letter: 'A', code: '12345'), '');
      expect(composePlate(province: '皖', letter: '', code: '12345'), '');
      expect(composePlate(province: '皖', letter: 'A', code: ''), '');
    });

    test('拆分可逆：拼好的值能拆回三段', () {
      final parts = splitPlate('皖A12345');
      expect(parts.province, '皖');
      expect(parts.letter, 'A');
      expect(parts.code, '12345');
    });

    test('拆分兼容小写与带点写法', () {
      final parts = splitPlate('皖a·12345');
      expect(parts.province, '皖');
      expect(parts.letter, 'A');
      expect(parts.code, '12345');
    });

    test('识别不出省份时整段当号码，不抛错', () {
      final parts = splitPlate('12345');
      expect(parts.province, '');
      expect(parts.letter, '');
      expect(parts.code, '12345');
    });

    test('空值拆分为全空三段', () {
      final parts = splitPlate('  ');
      expect(parts.province, '');
      expect(parts.letter, '');
      expect(parts.code, '');
    });
  });

  group('展示格式化', () {
    test('完整车牌展示为 皖A·12345（带间隔点）', () {
      expect(formatPlate('皖A12345'), '皖A·12345');
    });

    test('半截或历史自由文本原样返回，不清洗旧值', () {
      expect(formatPlate('皖A'), '皖A');
      expect(formatPlate('白色轩逸三厢'), '白色轩逸三厢');
      expect(formatPlate(''), '');
    });
  });
}
