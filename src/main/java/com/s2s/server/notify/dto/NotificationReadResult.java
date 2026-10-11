package com.s2s.server.notify.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 标记通知已读结果（openapi {@code NotificationReadResult}）。
 *
 * @param updated 实际置为已读的行数（幂等：无未读行可标记时回 0）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record NotificationReadResult(int updated) {
}
