package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import com.s2s.server.common.constants.ChatLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 会话内举报 / 误拦反馈入参（V30 / 计划 U7；R28 / R29）。
 *
 * <p><b>不接收被举报人</b>：会话只有两位成员，被举报人恒为「对方」，由服务端从
 * 会话双方派生——若允许客户端传 {@code reported_user_id}，等于开放了伪造他人被举报
 * 记录的路径（与 {@code POST /posts/{id}/report} 从帖子派生被举报人同一口径）。</p>
 *
 * <p><b>误拦反馈复用本入参</b>：{@code reason=misblock} 时 {@code blocked_text} 承载
 * 被拒发的原文，服务端截取摘要写入举报描述，供后台复核；其余原因忽略该字段。</p>
 *
 * @param reason      举报原因；取值须为 {@code report.reason} 的合法值，非法回 {@code 40001}
 * @param remark      补充说明（可空，上限同既有举报：200 字符）
 * @param evidence    证据媒体 ID 列表（可空，最多 3 条，落 {@code report.evidence} JSON 列）
 * @param blockedText 被敏感词拦截的原文（仅误拦反馈使用；上限同消息正文
 *                    {@link ChatLimits#MESSAGE_CONTENT_MAX_LENGTH}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ConversationReportRequest(
        @NotBlank(message = "reason") String reason,
        @Size(max = 200, message = "remark") String remark,
        @Size(max = 3, message = "evidence") List<String> evidence,
        @Size(max = ChatLimits.MESSAGE_CONTENT_MAX_LENGTH, message = "blocked_text")
        String blockedText) {
}
