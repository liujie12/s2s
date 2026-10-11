import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/cert/cert_models.dart';
import 'package:zhaoyazhao/features/cert/cert_type_option.dart';

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

  group('资质状态枚举（防再犯：资质 approved ≠ 实名的 passed）', () {
    // 守的是一个真缺陷：`QualificationItem.status` 枚举是 pending/approved/
    // rejected/expired，而实名是 passed；两者只差一个词，误用会让「已通过
    // 的资质」计数恒为 0（界面显示「资质 0 项」），编译器不报错。
    test('passedQualificationCount 只数 approved，混入实名的 passed 不计', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': [
          {'type': 'enterprise', 'status': 'approved'},
          {'type': 'vehicle', 'status': 'pending'},
          {'type': 'personal_qualification', 'status': 'rejected'},
          {'type': 'enterprise', 'status': 'passed'},
        ],
      });

      expect(status.passedQualificationCount, 1);
    });

    test('qualificationOf 按 type 取记录、解析 expire_at，未提交返回 null', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'none'},
        'qualifications': [
          {'type': 'vehicle', 'status': 'expired', 'expire_at': '2026-01-31T00:00:00Z'},
        ],
      });

      expect(status.qualificationOf('vehicle')?.status, CertQualification.statusExpired);
      expect(status.qualificationOf('vehicle')?.expireAt, isNotNull);
      expect(status.qualificationOf('enterprise'), isNull);
    });
  });

  group('QualificationSubmitResult.fromJson（POST /cert/qualification）', () {
    test('解析 status 与 sla_hours', () {
      final result = QualificationSubmitResult.fromJson({'status': 'pending', 'sla_hours': 48});

      expect(result.status, 'pending');
      expect(result.slaHours, 48);
    });

    test('sla_hours 缺失抛 ApiException(parseError)', () {
      expect(
        () => QualificationSubmitResult.fromJson({'status': 'pending'}),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('CertTypeOption.fromApi（契约类型值 ↔ 展示名）', () {
    test('三类可提交资质可反查', () {
      expect(CertTypeOption.fromApi('enterprise'), CertTypeOption.enterprise);
      expect(CertTypeOption.fromApi('personal_qualification'), CertTypeOption.personalQualification);
      expect(CertTypeOption.fromApi('vehicle'), CertTypeOption.vehicle);
    });

    test('实名类型与未知值/空值返回 null，不猜默认', () {
      // personal_realname 是「第一层」实名的类型，不属可提交资质选项。
      expect(CertTypeOption.fromApi('personal_realname'), isNull);
      expect(CertTypeOption.fromApi('unknown'), isNull);
      expect(CertTypeOption.fromApi(null), isNull);
    });
  });
}
