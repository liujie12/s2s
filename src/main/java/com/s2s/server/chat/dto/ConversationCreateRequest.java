package com.s2s.server.chat.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 开会话入参（V30 / 计划 U2；openapi {@code POST /conversations}）。
 *
 * <p>请求体只有帖子标识：会话的两方由服务端从帖子派生（发起人 = 当前登录用户，
 * 另一方 = 帖子发布者），客户端传不了第三方 ID。</p>
 *
 * @param postId 帖子 ID（必填；不存在或对当前用户不可见时回 {@code 41001}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ConversationCreateRequest(
        @NotNull(message = "post_id") Long postId) {
}
