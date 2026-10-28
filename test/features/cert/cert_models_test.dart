import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/cert/cert_models.dart';
import 'package:zhaoyazhao/features/cert/cert_type_option.dart';

void main() {
  group('CertStatus.fromJson（认证状态解析）', () {
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

    test('资质项缺 cert_id / expire_type 抛 ApiException(parseError)', () {
      expect(
        () => CertStatus.fromJson({
          'realname': {'status': 'none'},
          'qualifications': [
            {'cert_type': 'vehicle', 'status': 'approved'},
          ],
        }),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('资质档案（QualificationItem）', () {
    test('passedQualificationCount 只数 approved，混入实名的 passed 不计', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': [
          _item(certId: 1, type: 'enterprise', status: 'approved'),
          _item(certId: 2, type: 'vehicle', status: 'pending'),
          _item(certId: 3, type: 'personal_qualification', status: 'rejected'),
          _item(certId: 4, type: 'enterprise', status: 'passed'),
        ],
      });

      expect(status.passedQualificationCount, 1);
    });

    test('qualificationOf 按 cert_type 取记录、解析 expire_at，未提交返回 null', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'none'},
        'qualifications': [
          _item(
            certId: 7,
            type: 'vehicle',
            status: 'expired',
            expireAt: '2026-01-31T23:59:59+08:00',
          ),
        ],
      });

      expect(status.qualificationOf('vehicle')?.status, CertQualification.statusExpired);
      expect(status.qualificationOf('vehicle')?.expireAt, isNotNull);
      expect(status.qualificationOf('enterprise'), isNull);
    });

    test('attachableQualifications 只取 approved（到期由服务端置 expired）', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': [
          _item(certId: 1, type: 'enterprise', status: 'approved'),
          _item(certId: 2, type: 'vehicle', status: 'expired'),
        ],
      });

      expect(status.attachableQualifications.map((e) => e.certId), [1]);
    });

    test('档案状态文案：有效期至 / 长期有效 / 已于 YYYY-MM 过期', () {
      final dated = CertQualification.fromJson(
        _item(certId: 1, type: 'enterprise', expireAt: '2027-06-30T23:59:59+08:00'),
      );
      final permanent = CertQualification.fromJson(
        _item(certId: 2, type: 'enterprise', expireType: 'permanent'),
      );
      final expired = CertQualification.fromJson(
        _item(
          certId: 3,
          type: 'enterprise',
          status: 'expired',
          expireAt: '2026-08-31T23:59:59+08:00',
        ),
      );

      expect(dated.archiveStatusLabel, '有效期至 2027-06');
      expect(permanent.archiveStatusLabel, '长期有效');
      expect(expired.archiveStatusLabel, '已于 2026-08 过期');
    });

    test('证名为空回落类型展示名，不臆造证名', () {
      final item = CertQualification.fromJson(
        _item(certId: 1, type: 'personal_qualification', certName: '  '),
      );

      expect(item.displayName, '家政资质');
    });
  });

  group('QualificationSubmitResult.fromJson（POST/PATCH /cert/qualification）', () {
    test('解析 cert_id 与 status', () {
      final result = QualificationSubmitResult.fromJson({'cert_id': 12, 'status': 'approved'});

      expect(result.certId, 12);
      expect(result.status, 'approved');
    });

    test('cert_id 缺失抛 ApiException(parseError)', () {
      expect(
        () => QualificationSubmitResult.fromJson({'status': 'approved'}),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('CertOcrResult.fromJson（POST /cert/ocr）', () {
    test('两字段可为 null，不算错误', () {
      final result = CertOcrResult.fromJson({'cert_name': null, 'expire_at': null});

      expect(result.isEmpty, isTrue);
    });

    test('解析证名与有效期', () {
      final result = CertOcrResult.fromJson({
        'cert_name': '养老护理员证',
        'expire_at': '2027-06-30T23:59:59+08:00',
      });

      expect(result.certName, '养老护理员证');
      expect(yearMonthOf(result.expireAt!), (year: 2027, month: 6));
    });
  });

  group('有效期 wire 值（含本日口径）', () {
    test('2027-06 → 当月最后一天 23:59:59 +08:00', () {
      expect(expireAtWireFromYearMonth(2027, 6), '2027-06-30T23:59:59+08:00');
    });

    test('闰年 2 月 → 29 日', () {
      expect(expireAtWireFromYearMonth(2028, 2), '2028-02-29T23:59:59+08:00');
    });

    test('formatYearMonth 不随设备时区漂移', () {
      final at = DateTime.parse('2027-06-30T23:59:59+08:00');
      expect(formatYearMonth(at), '2027-06');
    });
  });

  group('QualificationUpdateRequest.toJson（PATCH 载荷）', () {
    test('只出现显式赋值的键', () {
      final json = const QualificationUpdateRequest(certName: '家政服务资质').toJson();

      expect(json.keys, ['cert_name']);
    });

    test('permanent 显式带 expire_at: null（清掉旧到期日）', () {
      final json = const QualificationUpdateRequest(
        expireType: CertQualification.expireTypePermanent,
      ).toJson();

      expect(json['expire_at'], isNull);
      expect(json.containsKey('expire_at'), isTrue);
    });

    test('dated 时上送 wire 值', () {
      final json = QualificationUpdateRequest(
        expireType: CertQualification.expireTypeDated,
        expireAt: expireAtWireFromYearMonth(2027, 8),
      ).toJson();

      expect(json['expire_at'], '2027-08-31T23:59:59+08:00');
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

/// 构造一条契约 `QualificationItem` JSON。
///
/// 参数：[certId] 档案 ID；[type] 契约类型；[status] 状态；
///   [certName] 证名；[expireType] 有效期类型；[expireAt] 有效期 wire 值。
/// 返回：Map。
Map<String, Object?> _item({
  required int certId,
  required String type,
  String status = 'approved',
  String? certName,
  String expireType = 'dated',
  String? expireAt,
}) =>
    {
      'cert_id': certId,
      'cert_type': type,
      'cert_name': certName,
      'status': status,
      'expire_type': expireType,
      'expire_at': expireAt,
    };
