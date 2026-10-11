import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/cert/cert_models.dart';

void main() {
  group('CertStatus.fromJson（认证状态解析，[149]）', () {
    test('解析 realname.status 与空资质列表', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': <Object>[],
      });

      expect(status.realnameStatus, 'passed');
    });

    test('data 非 Map 抛 ApiException(parseError)', () {
      expect(
        () => CertStatus.fromJson('x'),
        throwsA(isA<ApiException>()),
      );
    });

    test('realname.status 缺失抛 ApiException(parseError)', () {
      expect(
        () => CertStatus.fromJson({'realname': <String, Object>{}}),
        throwsA(isA<ApiException>()),
      );
    });
  });
}
