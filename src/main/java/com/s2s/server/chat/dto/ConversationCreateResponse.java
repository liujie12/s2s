package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 开会话结果（V30 / 计划 U2；openapi {@code POST /conversations} 响应 {@code data}）。
 *
 * <p>{@code created} 用于客户端区分「新建」与「复用」：复用时不应再弹「已发起」提示，
 * 也不应把用户带到空白会话（原会话里可能已有历史）。</p>
 *
 * @param conversationId 会话 ID
 * @param created        true=本次新建；false=复用既有会话（含 90 天隐藏后恢复）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ConversationCreateResponse(
        Long conversationId,
        boolean created) {
}
