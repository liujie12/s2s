package com.s2s.server.notify.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 单条通知（openapi {@code Notification}；详设 §5.6）。
 *
 * <p>字段映射（契约 ← 库内列）：{@code title} ← {@code title}；{@code content} ← {@code summary}；
 * {@code is_read} ← {@code read_at IS NOT NULL}；{@code created_at} ← {@code created_at}；
 * {@code target} ← {@code type} + {@code target_id} 派生（见 {@code NotifyService#targetOf}）。</p>
 *
 * @param id        通知 ID
 * @param type      类型线值（{@code system}/{@code interaction}/{@code cert}）
 * @param title     标题
 * @param content   摘要；库内可空即返回 {@code null}
 * @param isRead    是否已读（{@code read_at} 非空即已读）
 * @param createdAt 创建时间（UTC {@link Instant}）
 * @param target    跳转目标（恒非 null，无跳转时为 {@code kind=none}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record NotificationItem(
        Long id,
        String type,
        String title,
        String content,
        @JsonProperty("is_read") boolean isRead,
        Instant createdAt,
        NotificationTarget target) {
}
