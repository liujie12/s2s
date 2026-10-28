import 'package:flutter_test/flutter_test.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';
import 'package:zhaoyazhao/features/cert/cert_models.dart';

void main() {
  group('CertStatus.fromJson（认证状态解析）', () {
    test('解析 realname.status 与空资质列表', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': <Object>[],
      });

      expect(status.realnameStatus, 'passed');
      expect(status.isRealnamePassed, isTrue);
      expect(status.qualifications, isEmpty);
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

    test('资质项缺 cert_id 抛 ApiException(parseError)', () {
      expect(
        () => CertStatus.fromJson({
          'realname': {'status': 'none'},
          'qualifications': [
            {'cert_name': '营业执照', 'status': 'approved'},
          ],
        }),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('资质档案（QualificationItem）', () {
    test('解析 cert_name / name_source / image_url', () {
      final item = CertQualification.fromJson(_item(
        certId: 7,
        certName: '养老护理员证',
        nameSource: CertQualification.nameSourceOcr,
        imageUrl: 'https://cdn.example.com/a.jpg',
      ));

      expect(item.certId, 7);
      expect(item.certName, '养老护理员证');
      expect(item.nameSource, CertQualification.nameSourceOcr);
      expect(item.status, CertQualification.statusApproved);
      expect(item.imageUrl, 'https://cdn.example.com/a.jpg');
    });

    test('passedQualificationCount 等于资质档案条数（提交即 approved）', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': [
          _item(certId: 1),
          _item(certId: 2),
        ],
      });

      expect(status.passedQualificationCount, 2);
    });

    test('attachableQualifications 只取 approved', () {
      final status = CertStatus.fromJson({
        'realname': {'status': 'passed'},
        'qualifications': [
          _item(certId: 1),
          _item(certId: 2, status: 'revoked'),
        ],
      });

      expect(status.attachableQualifications.map((e) => e.certId), [1]);
    });

    test('证名为空回落「未命名证书」，不臆造证名', () {
      final item = CertQualification.fromJson(_item(certId: 1, certName: '  '));

      expect(item.displayName, '未命名证书');
    });

    test('证名存在时 displayName 用去空白后的证名', () {
      final item = CertQualification.fromJson(_item(certId: 1, certName: ' 月嫂证 '));

      expect(item.displayName, '月嫂证');
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
    test('cert_name 为 null 时 isEmpty 为真，不算错误', () {
      final result = CertOcrResult.fromJson({'cert_name': null});

      expect(result.certName, isNull);
      expect(result.isEmpty, isTrue);
    });

    test('解析证名', () {
      final result = CertOcrResult.fromJson({'cert_name': '养老护理员证'});

      expect(result.certName, '养老护理员证');
      expect(result.isEmpty, isFalse);
    });
  });

  group('QualificationUpdateRequest.toJson（PATCH 载荷）', () {
    test('只出现显式赋值的键', () {
      final json = const QualificationUpdateRequest(certName: '家政服务资质').toJson();

      expect(json.keys, ['cert_name']);
      expect(json['cert_name'], '家政服务资质');
    });

    test('未传字段不进载荷（null 等价于不传）', () {
      final json = const QualificationUpdateRequest(certName: null).toJson();

      expect(json.containsKey('cert_name'), isFalse);
      expect(json, isEmpty);
      expect(const QualificationUpdateRequest().hasAny, isFalse);
    });

    test('media_ids 原样上送', () {
      final json = const QualificationUpdateRequest(
        mediaIds: ['m-1', 'm-2'],
        nameSource: CertQualification.nameSourceManual,
      ).toJson();

      expect(json['media_ids'], ['m-1', 'm-2']);
      expect(json['name_source'], 'manual');
    });

    test('hasAny 判断是否至少一项', () {
      expect(const QualificationUpdateRequest().hasAny, isFalse);
      expect(const QualificationUpdateRequest(certName: '月嫂证').hasAny, isTrue);
      expect(const QualificationUpdateRequest(mediaIds: []).hasAny, isTrue);
    });
  });
}

/// 构造一条契约 `QualificationItem` JSON。
///
/// 参数：[certId] 档案 ID；[certName] 证名；[nameSource] 证名来源；
///   [status] 状态；[imageUrl] 证照地址。
/// 返回：Map。
Map<String, Object?> _item({
  required int certId,
  String? certName,
  String? nameSource,
  String status = 'approved',
  String? imageUrl,
}) =>
    {
      'cert_id': certId,
      'cert_name': certName,
      'name_source': nameSource,
      'status': status,
      'image_url': imageUrl,
    };
