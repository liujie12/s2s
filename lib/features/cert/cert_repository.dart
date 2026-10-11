/// cert 域仓库（[149]）：实名认证提交与状态查询。
///
/// 走真网络而非本地替身：请求经 [dioProvider] 生产同款五拦截器链发出，
/// 信封由 EnvelopeInterceptor 拆、业务错误以 [ApiException] 抛出，本层不吞
/// 不改写（编码规范 §1.2）。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';
import 'package:zhaoyazhao/core/network/api_exception.dart';

import 'cert_models.dart';

/// cert 域仓库。
///
/// 无实例状态，故不需要单实例纪律；dio 由构造注入，与 [dioProvider] 同源。
class CertRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（生产经 [certRepositoryProvider] 注入）。
  CertRepository(this._dio);

  final Dio _dio;

  /// 提交实名认证（`POST /cert/realname`，二要素核验）。
  ///
  /// 参数：
  ///   [realName] 真实姓名（明文，仅用于核验与加密，客户端不留存）；
  ///   [idCard] 18 位身份证号（明文，仅用于核验，客户端不留存）；
  ///   [agreementAccepted] 是否已同意实名认证相关协议；
  ///   [interactionId] 交互起点生成的 X-Interaction-Id，null 由拦截器兜底。
  /// 返回：[String] 实名状态（通过后为 `passed`）。
  /// 抛出：[ApiException] 信封业务错误（40001/40002/50302 等）/ 解析失败。
  Future<String> submitRealname({
    required String realName,
    required String idCard,
    required bool agreementAccepted,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/cert/realname',
      data: {
        'real_name': realName,
        'id_card': idCard,
        'agreement_accepted': agreementAccepted,
      },
      options: _interactionOptions(interactionId),
    );
    return _parseStatus(response.data);
  }

  /// 查询认证状态（`GET /cert/status`）。
  ///
  /// 参数：[interactionId] 交互 ID，null 由拦截器兜底。
  /// 返回：[CertStatus] 认证状态（实名状态 + 资质列表，资质本轮恒空）。
  Future<CertStatus> fetchCertStatus({String? interactionId}) async {
    final response = await _dio.get<Object?>(
      '/cert/status',
      options: _interactionOptions(interactionId),
    );
    return CertStatus.fromJson(response.data);
  }

  /// 提交资质认证（`POST /cert/qualification`，高敏类目前置实名）。
  ///
  /// 参数：
  ///   [certType] 契约 `CertTypeEnum`（`personal_qualification`/`enterprise`/`vehicle`）；
  ///   [mediaIds] OCR 证照图 media_id 列表（**必填**，须先走上传链路拿到）；
  ///   [interactionId] 交互 ID，null 由拦截器兜底。
  /// 返回：[QualificationSubmitResult]（status + sla_hours）。
  /// 抛出：[ApiException] 信封业务错误（40302 未实名提交资质 / 40001 参数 / 50302 认证服务不可用）。
  Future<QualificationSubmitResult> submitQualification({
    required String certType,
    required List<String> mediaIds,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/cert/qualification',
      data: {
        'cert_type': certType,
        'media_ids': mediaIds,
      },
      options: _interactionOptions(interactionId),
    );
    return QualificationSubmitResult.fromJson(response.data);
  }

  /// 解析「实名提交」响应 data 的 status 字段。
  ///
  /// 参数：[data] 信封拆出的 data（契约 `RealnameSubmitResult`）。
  /// 返回：[String] 实名状态。
  /// 抛出：[ApiException.parse] status 缺失/类型不符时。
  String _parseStatus(Object? data) {
    if (data is! Map || data['status'] is! String) {
      throw ApiException.parse('实名提交响应 data.status 缺失或非 String: $data');
    }
    return data['status'] as String;
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options?]；null 时走 BaseOptions 默认，头由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// cert 仓库 Provider（dio 经 [dioProvider] 注入，与生产装配同源）。
final certRepositoryProvider = Provider<CertRepository>(
  (ref) => CertRepository(ref.watch(dioProvider)),
);
