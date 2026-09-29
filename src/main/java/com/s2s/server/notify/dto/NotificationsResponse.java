package com.s2s.server.notify.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 通知列表分页响应（openapi {@code GET /notifications} 的 {@code data}；详设 §5.6）。
 *
 * @param items       当前页通知项
 * @param total       符合条件的总条数（随 {@code type} 筛选收窄）
 * @param page        当前页码（从 1 起）
 * @param pageSize    每页条数
 * @param unreadCount 未读总数（跨三 Tab，供 Tab 角标，不随 {@code type} 收窄）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record NotificationsResponse(
        List<NotificationItem> items,
        long total,
        int page,
        int pageSize,
        long unreadCount) {
}
