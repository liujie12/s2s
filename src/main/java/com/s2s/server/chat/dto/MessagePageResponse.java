package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 消息分页 / 增量结果（V30 / 计划 U4；openapi {@code GET /conversations/{id}/messages}）。
 *
 * <p>{@code items} 恒按 {@code seq} 正序返回：翻历史时服务端倒序取一页再翻转，
 * 客户端无需按请求方向切换渲染顺序。</p>
 *
 * @param items   当前页消息（按 seq 正序）
 * @param hasMore 是否还有更多（历史方向=更早，增量方向=更新）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessagePageResponse(
        List<MessageItem> items,
        boolean hasMore) {
}
