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

  /// 提交资质（`POST /cert/qualification`，高敏类目前置实名）。
  ///
  /// 本轮服务端**提交即 `approved`**，不落 `pending`、不返回 SLA。
  ///
  /// 参数：
  ///   [certType] 契约 `CertTypeEnum`（`personal_qualification`/`enterprise`/`vehicle`）；
  ///   [mediaIds] 证照图 media_id 列表（**必填**，须先走上传链路拿到）；
  ///   [certName] 证书名称（可空：抽取失败且用户未填）；
  ///   [nameSource] 证名来源（`ocr`=原样提交抽取值，`manual`=用户改过）；
  ///   [expireType] 有效期类型（`dated`/`permanent`）；
  ///   [expireAt] 有效期至 wire 值（`dated` 时必填，见
  ///     [expireAtWireFromYearMonth]；`permanent` 时忽略）；
  ///   [interactionId] 交互 ID，null 由拦截器兜底。
  /// 返回：[QualificationSubmitResult]（cert_id + status）。
  /// 抛出：[ApiException] 信封业务错误（40302 未实名提交资质 / 40001 参数 / 50302 认证服务不可用）。
  Future<QualificationSubmitResult> submitQualification({
    required String certType,
    required List<String> mediaIds,
    String? certName,
    String? nameSource,
    required String expireType,
    String? expireAt,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/cert/qualification',
      data: {
        'cert_type': certType,
        'media_ids': mediaIds,
        'cert_name': ?certName,
        'name_source': ?nameSource,
        'expire_type': expireType,
        if (expireType != CertQualification.expireTypePermanent && expireAt != null)
          'expire_at': expireAt,
      },
      options: _interactionOptions(interactionId),
    );
    return QualificationSubmitResult.fromJson(response.data);
  }

  /// 从证照图抽取证名与有效期（`POST /cert/ocr`，纯读不写库）。
  ///
  /// 抽取失败不是错误：仍返回 200/code=0，两个字段为 null。
  ///
  /// 参数：
  ///   [mediaId] 已 commit 的证照图 media_id（须属本人，否则 40001）；
  ///   [interactionId] 交互 ID，null 由拦截器兜底。
  /// 返回：[CertOcrResult]。
  /// 抛出：[ApiException] 信封业务错误（40001 媒体不存在/非本人 / 50301 模型不可用）。
  Future<CertOcrResult> extractCertProfile({
    required String mediaId,
    String? interactionId,
  }) async {
    final response = await _dio.post<Object?>(
      '/cert/ocr',
      data: {'media_id': mediaId},
      options: _interactionOptions(interactionId),
    );
    return CertOcrResult.fromJson(response.data);
  }

  /// 编辑资质（`PATCH /cert/qualification/{cert_id}`）。
  ///
  /// 只改传入项；**换图不重新抽取**（抽取由客户端换图后先调 [extractCertProfile]）。
  /// 新有效期在未来 → `approved`，已过去 → 直接 `expired`，改完立即生效。
  ///
  /// 参数：
  ///   [certId] 资质档案 ID；
  ///   [request] 编辑载荷（至少一项，否则 40001）；
  ///   [interactionId] 交互 ID，null 由拦截器兜底。
  /// 返回：[QualificationSubmitResult]（cert_id + 新状态）。
  /// 抛出：[ApiException] 信封业务错误（40001 参数/非本人/不存在）。
  Future<QualificationSubmitResult> updateQualification(
    int certId,
    QualificationUpdateRequest request, {
    String? interactionId,
  }) async {
    final response = await _dio.patch<Object?>(
      '/cert/qualification/$certId',
      data: request.toJson(),
      options: _interactionOptions(interactionId),
    );
    return QualificationSubmitResult.fromJson(response.data);
  }

  /// 删除资质（`DELETE /cert/qualification/{cert_id}`）。
  ///
  /// 用户显式删除：服务端删记录并清理证照原件；已挂载帖子的主行保留、
  /// 说明行变为「该资质已不再有效」。
  ///
  /// 参数：
  ///   [certId] 资质档案 ID；
  ///   [interactionId] 交互 ID，null 由拦截器兜底。
  /// 返回：[Future<void>]。
  /// 抛出：[ApiException] 信封业务错误（40001 非本人/不存在）。
  Future<void> deleteQualification(
    int certId, {
    String? interactionId,
  }) async {
    await _dio.delete<Object?>(
      '/cert/qualification/$certId',
      options: _interactionOptions(interactionId),
    );
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
