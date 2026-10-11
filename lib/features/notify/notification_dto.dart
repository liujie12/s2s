/// notify 域契约 DTO（[B2-11]）：openapi.yaml `Notification` 与 `/notifications`
/// 响应（`items`/`total`/`page`/`page_size`/`unread_count`）的逐字段映射。
library;

import 'package:zhaoyazhao/core/contract_json.dart';

/// 通知项 DTO（openapi `Notification`：required = id/type/title/is_read/created_at）。
class NotificationDto {
  /// 构造通知项 DTO。
  const NotificationDto({
    required this.id,
    required this.type,
    required this.title,
    required this.isRead,
    required this.createdAt,
    this.content,
    this.targetKind,
    this.targetPostId,
  });

  /// 由信封 data 内的 `items[]` 元素构造。
  ///
  /// 参数：[json] `GET /notifications` 的 data.items 元素。
  /// 返回：[NotificationDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时（含实际值）。
  factory NotificationDto.fromJson(Object? json) {
    final map = requireMap(json, 'Notification');
    final target = map['target'];
    Map<String, Object?>? targetMap;
    if (target != null) {
      targetMap = requireMap(target, 'Notification.target');
    }
    return NotificationDto(
      id: requireInt(map, 'id', 'Notification'),
      type: requireString(map, 'type', 'Notification'),
      title: requireString(map, 'title', 'Notification'),
      isRead: requireBool(map, 'is_read', 'Notification'),
      createdAt: requireDateTime(map, 'created_at', 'Notification'),
      content: optString(map, 'content', 'Notification'),
      targetKind: targetMap == null ? null : optString(targetMap, 'kind', 'Notification.target'),
      targetPostId:
          targetMap == null ? null : optInt(targetMap, 'post_id', 'Notification.target'),
    );
  }

  /// 通知 ID。
  final int id;

  /// 类型（`system`/`interaction`/`cert`）。
  final String type;

  /// 标题。
  final String title;

  /// 是否已读。
  final bool isRead;

  /// 创建时间。
  final DateTime createdAt;

  /// 正文（可空）。
  final String? content;

  /// 跳转目标类型（`post`/`cert`/`none`；可空）。
  final String? targetKind;

  /// 跳转目标帖子 ID（target.kind=post 时有值；可空）。
  final int? targetPostId;
}

/// 通知分页响应 DTO（openapi `/notifications` 的 data）。
class NotificationsPageDto {
  /// 构造分页 DTO。
  const NotificationsPageDto({
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.unreadCount,
  });

  /// 由信封 data 构造。
  ///
  /// 参数：[json] 信封 data（`GET /notifications` 的 data 字段）。
  /// 返回：[NotificationsPageDto]。
  /// 抛出：[ApiException.parse] required 字段缺失/类型不符时。
  factory NotificationsPageDto.fromJson(Object? json) {
    final map = requireMap(json, 'NotificationsResponse');
    return NotificationsPageDto(
      items: [
        for (final item in requireList(map, 'items', 'NotificationsResponse'))
          NotificationDto.fromJson(item),
      ],
      total: requireInt(map, 'total', 'NotificationsResponse'),
      page: requireInt(map, 'page', 'NotificationsResponse'),
      pageSize: requireInt(map, 'page_size', 'NotificationsResponse'),
      unreadCount: requireInt(map, 'unread_count', 'NotificationsResponse'),
    );
  }

  /// 当前页通知项。
  final List<NotificationDto> items;

  /// 符合条件的总条数。
  final int total;

  /// 当前页码。
  final int page;

  /// 每页条数。
  final int pageSize;

  /// 未读总数（用于 Tab 角标与「我的」页「N 未读」）。
  final int unreadCount;
}
