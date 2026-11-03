package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 会话删除结果（V33；openapi {@code DELETE /conversations/{id}} 响应 {@code data}）。
 *
 * <p>「删除」是仅本人口径：只把会话从当前用户的消息列表移除，对方不受影响，
 * 会话与消息数据仍保留（举报取证需要）。再次收到新消息或本人重新发起时会话
 * 自动恢复可见，因此本响应不含「已彻底删除」这类不可逆语义。</p>
 *
 * @param conversationId 被移除的会话 ID
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ConversationRemoveResponse(
        Long conversationId) {
}
