package com.s2s.server.notify.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 标记通知已读请求体（openapi {@code NotificationReadRequest}；{@code POST /notifications/read}）。
 *
 * <p>{@code ids} 缺省或空数组 = 标记该用户「全部未读」为已读（PRD §8.3.3「全部已读」）；
 * 非空 = 只标记所列 id（且限定归属当前用户）。</p>
 *
 * @param ids 待标记的通知 ID；{@code null} 或空表示全部
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record NotificationReadRequest(List<Long> ids) {
}
