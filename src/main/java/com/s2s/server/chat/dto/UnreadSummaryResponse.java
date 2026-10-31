package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 未读汇总（V30 / 计划 U5；openapi {@code GET /unread-summary} 响应 {@code data}）。
 *
 * <p><b>唯一出口</b>（KTD9 / R8）：Tab 角标、会话列表红点、安卓桌面角标都读本响应，
 * 客户端不做二次汇总。{@code total} 由服务端相加后下发，避免三处各自求和后
 * 因取数时刻不同出现三个数字。</p>
 *
 * @param total               未读总数 = 会话未读 + 通知未读
 * @param conversationUnread  会话未读条数（按已读水位推导，排除本人发出的消息与隐藏会话）
 * @param notificationUnread  通知未读条数（沿用既有 {@code notification} 口径）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record UnreadSummaryResponse(
        long total,
        long conversationUnread,
        long notificationUnread) {
}
