import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zhaoyazhao/features/cert/cert_name_store.dart';
import 'package:zhaoyazhao/nfr_constants.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('内置常用证名（2026-10-28 用户裁定：全局一份，不按类型分组）', () {
    test('候选非空', () {
      expect(kCertNameSuggestions, isNotEmpty);
    });

    test('候选名称不重复', () {
      expect(kCertNameSuggestions.toSet().length, kCertNameSuggestions.length);
    });
  });

  group('CertNameStore（自定义证名本机记忆，按用户隔离）', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('无记录时返回空列表', () async {
      const store = CertNameStore();
      expect(await store.read('u1'), isEmpty);
    });

    test('记住后可按用户读回；重复即置顶', () async {
      const store = CertNameStore();
      await store.remember('u1', '营业执照（副本）');
      await store.remember('u1', '食品经营许可证');
      await store.remember('u1', '营业执照（副本）');

      expect(
        await store.read('u1'),
        ['营业执照（副本）', '食品经营许可证'],
      );
    });

    test('不同用户互不可见（没有类型维度）', () async {
      const store = CertNameStore();
      await store.remember('u1', '营业执照（副本）');

      expect(await store.read('u2'), isEmpty);
    });

    test('内置候选不落库；空白名称忽略', () async {
      const store = CertNameStore();
      await store.remember(
        'u1',
        kCertNameSuggestions.first,
        exclude: kCertNameSuggestions,
      );
      await store.remember('u1', '   ');

      expect(await store.read('u1'), isEmpty);
    });

    test('超出上限按最近使用淘汰', () async {
      const store = CertNameStore();
      for (var i = 0; i <= NfrCert.rememberedNameLimit; i++) {
        await store.remember('u1', '证名$i');
      }

      final names = await store.read('u1');
      expect(names.length, NfrCert.rememberedNameLimit);
      expect(names.first, '证名${NfrCert.rememberedNameLimit}');
      expect(names.contains('证名0'), isFalse);
    });
  });
}
