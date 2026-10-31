package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import com.s2s.server.common.constants.ChatLimits;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 发送消息入参（V30 / 计划 U3；openapi {@code POST /conversations/{id}/messages}）。
 *
 * <p><b>只收正文</b>：消息类型、发送者与可见范围全部由服务端派生——客户端若能指定
 * {@code type}，就能伪造「联系方式卡」；能指定 {@code sender_id}，就能冒名发言。</p>
 *
 * @param content 文本正文（必填；长度上限引用 {@link ChatLimits#MESSAGE_CONTENT_MAX_LENGTH}，
 *                与 {@code message.content} 列宽一致）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessageSendRequest(
        @NotBlank(message = "content")
        @Size(max = ChatLimits.MESSAGE_CONTENT_MAX_LENGTH, message = "content")
        String content) {
}
