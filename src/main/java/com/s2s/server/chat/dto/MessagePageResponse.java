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
 * <p>{@code peerLastReadSeq} 是 R17 已读回执的唯一数据源：客户端拿它与我发出的
 * 最后一条消息的 {@code seq} 比较，{@code 水位 >= seq} 即显示「已读」。水位只增不减
 * （见 {@code markRead} 的 GREATEST），因此不会出现「已读」退回「未读」。</p>
 *
 * @param items           当前页消息（按 seq 正序）
 * @param hasMore         是否还有更多（历史方向=更早，增量方向=更新）
 * @param peerLastReadSeq 对方已读水位（成员行缺失时为 0）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessagePageResponse(
        List<MessageItem> items,
        boolean hasMore,
        int peerLastReadSeq) {
}
