import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/features/cert/cert_name_store.dart';
import 'package:zhaoyazhao/features/cert/cert_type_option.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('资质类型的默认候选证名（2026-10-28 用户裁定）', () {
    test('三类各自有非空候选', () {
      for (final option in CertTypeOption.values) {
        expect(option.suggestedNames, isNotEmpty, reason: '${option.label} 无候选');
      }
    });

    test('候选名称不重复', () {
      for (final option in CertTypeOption.values) {
        expect(
          option.suggestedNames.toSet().length,
          option.suggestedNames.length,
          reason: '${option.label} 候选有重复项',
        );
      }
    });
  });

  group('CertNameStore（自定义证名本机记忆，按用户+类型隔离）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('无记录时返回空列表', () async {
      const store = CertNameStore();
      expect(await store.read('u1', 'enterprise'), isEmpty);
    });

    test('记住后可按用户+类型读回；同类型重复即置顶', () async {
      const store = CertNameStore();
      await store.remember('u1', 'enterprise', '营业执照（副本）');
      await store.remember('u1', 'enterprise', '食品经营许可证');
      await store.remember('u1', 'enterprise', '营业执照（副本）');

      expect(
        await store.read('u1', 'enterprise'),
        ['营业执照（副本）', '食品经营许可证'],
      );
    });

    test('不同用户、不同资质类型互不可见', () async {
      const store = CertNameStore();
      await store.remember('u1', 'enterprise', '营业执照（副本）');

      expect(await store.read('u2', 'enterprise'), isEmpty);
      expect(await store.read('u1', 'vehicle'), isEmpty);
    });

    test('内置候选不落库；空白名称忽略', () async {
      const store = CertNameStore();
      await store.remember(
        'u1',
        'personal_qualification',
        '月嫂证',
        exclude: CertTypeOption.personalQualification.suggestedNames,
      );
      await store.remember('u1', 'personal_qualification', '   ');

      expect(await store.read('u1', 'personal_qualification'), isEmpty);
    });

    test('超出上限按最近使用淘汰', () async {
      const store = CertNameStore();
      for (var i = 0; i <= NfrCert.rememberedNameLimit; i++) {
        await store.remember('u1', 'vehicle', '证名$i');
      }

      final names = await store.read('u1', 'vehicle');
      expect(names.length, NfrCert.rememberedNameLimit);
      expect(names.first, '证名${NfrCert.rememberedNameLimit}');
      expect(names.contains('证名0'), isFalse);
    });
  });
}
