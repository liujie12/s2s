package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 单条消息（V30 / 计划 U4；openapi {@code GET /conversations/{id}/messages} 的 {@code items[]}）。
 *
 * <p><b>联系方式卡不承载号码</b>：{@code type=contact} 时 {@code content} 恒为 null，
 * 完整号码仍只由取号接口返回（R22）。非目标用户根本查不到该行（{@code visible_to} 过滤）。</p>
 *
 * @param messageId  消息 ID
 * @param seq        会话内序号（增量游标与已读水位）
 * @param senderId   发送者 user_id（客户端据此判断左右气泡）
 * @param type       消息类型（text/apply/contact）
 * @param content    文本正文；卡片类为 null
 * @param createdAt  发送时刻（UTC）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessageItem(
        Long messageId,
        Integer seq,
        Long senderId,
        String type,
        String content,
        Instant createdAt) {
}
