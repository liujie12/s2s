package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 会话列表分页结果（V30 / 计划 U4；openapi {@code GET /conversations} 响应 {@code data}）。
 *
 * @param items    当前页会话（按最后消息时间倒序）
 * @param total    满足条件的会话总数（已排除 90 天无往来的隐藏会话）
 * @param page     实际页码（越界入参已钳制到 1）
 * @param pageSize 实际每页条数（越界入参已按 {@code ChatLimits} 钳制）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ConversationPageResponse(
        List<ConversationItem> items,
        long total,
        int page,
        int pageSize) {
}
