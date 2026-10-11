/// notify 域仓库（[B2-11]）：通知列表 / 标记已读。
///
/// 与 `PostRepository` 同一模式：真网络走 [dioProvider] 生产同款五拦截器链，
/// 本层只做「发请求 + 交 DTO 解析」。冷启动/登出清角标等本地缓存不是本层职责。
library;

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zhaoyazhao/core/network/api_client.dart';

import '../../core/contract_json.dart';
import '../../nfr_constants.dart';
import 'notification_dto.dart';

/// notify 域仓库。
class NotificationRepository {
  /// 构造仓库。
  ///
  /// 参数：[dio] 生产同款五拦截器链 dio（测试经 NetworkChainHarness 注入）。
  NotificationRepository(this._dio);

  final Dio _dio;

  /// 查通知列表（`GET /notifications`）。
  ///
  /// 参数：[type] 类型筛选（`system`/`interaction`/`cert`；null＝全部）；
  ///   [page] 页码；[pageSize] 每页条数；[interactionId] X-Interaction-Id。
  /// 返回：[NotificationsPageDto]（含 `unread_count`）。
  /// 抛出：[ApiException] 信封业务错误（40101 未登录）/解析失败/传输错误。
  Future<NotificationsPageDto> fetchNotifications({
    String? type,
    int page = 1,
    int pageSize = NfrApi.pageSizeDefault,
    String? interactionId,
  }) async {
    final query = <String, Object?>{'page': page, 'page_size': pageSize};
    // 缺省不传 type：契约 required=false，传空串会被服务端判非法值。
    if (type != null) query['type'] = type;
    final response = await _dio.get<Object?>(
      '/notifications',
      queryParameters: query,
      options: _interactionOptions(interactionId),
    );
    return NotificationsPageDto.fromJson(response.data);
  }

  /// 标记通知已读（`POST /notifications/read`）。
  ///
  /// 参数：[ids] 待标记的通知 ID；null/空 = 标记全部未读为已读（「全部已读」）；
  ///   [interactionId] X-Interaction-Id。
  /// 返回：int 实际置为已读的行数（服务端 `NotificationReadResult.updated`）。
  /// 抛出：[ApiException]（40101 未登录）/解析失败/传输错误。
  Future<int> markRead({List<int>? ids, String? interactionId}) async {
    final response = await _dio.post<Object?>(
      '/notifications/read',
      data: <String, Object?>{'ids': ids ?? const <int>[]},
      options: _interactionOptions(interactionId),
    );
    return requireInt(
      requireMap(response.data, 'NotificationReadResult'),
      'updated',
      'NotificationReadResult',
    );
  }

  /// 组装携带 X-Interaction-Id 的按请求选项。
  ///
  /// 参数：[interactionId] 交互 ID，null 表示无透传值。
  /// 返回：[Options]；null 时由拦截器兜底生成。
  Options? _interactionOptions(String? interactionId) {
    if (interactionId == null) return null;
    return Options(
      headers: {HeaderInterceptor.interactionIdHeader: interactionId},
    );
  }
}

/// notify 仓库 Provider（dio 经 [dioProvider] 注入）。
final notificationRepositoryProvider = Provider<NotificationRepository>(
  (ref) => NotificationRepository(ref.watch(dioProvider)),
);
