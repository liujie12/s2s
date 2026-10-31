package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 发送消息结果（V30 / 计划 U3；openapi {@code POST /conversations/{id}/messages} 响应 {@code data}）。
 *
 * <p>{@code seq} 是客户端对齐本地消息与增量游标的唯一依据：重发命中幂等键时返回的
 * 仍是首次的 {@code seq}，客户端据此把「发送中」替换为已落库的那一条，而不是追加新行。</p>
 *
 * @param messageId      消息 ID
 * @param conversationId 会话 ID
 * @param seq            会话内序号（同会话单调递增，兼作增量拉取游标与已读水位）
 * @param createdAt      发送时刻（UTC {@link Instant}，与通知域出参口径一致）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessageSendResponse(
        Long messageId,
        Long conversationId,
        Integer seq,
        Instant createdAt) {
}
