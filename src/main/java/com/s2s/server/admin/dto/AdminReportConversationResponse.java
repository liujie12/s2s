package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import com.s2s.server.chat.dto.MessageItem;
import java.util.List;

/**
 * 举报工单对应的会话正文出参（U7；后台复核用）。
 *
 * <p>查看即「查看用户信息」类敏感操作：读取与审计留痕同事务，逐次记录操作人、
 * 角色与会话 ID（口径参照 PRD §9.10.1「查看用户脱敏信息」）。</p>
 *
 * @param reportId       举报工单 ID
 * @param conversationId 举报双方之间的会话 ID
 * @param messages       最近一页消息（按 seq 正序）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminReportConversationResponse(
        Long reportId,
        Long conversationId,
        List<MessageItem> messages) {
}
