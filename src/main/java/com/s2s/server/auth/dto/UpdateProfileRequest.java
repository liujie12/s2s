package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Size;

/**
 * 更新本人资料请求（[123] U3；对应 openapi {@code PATCH /users/me} 请求体）。
 *
 * <p>局部更新，仅提交需变更字段（契约 {@code minProperties: 1}）。字段与契约逐字对齐：
 * {@code nickname}（1–20 字符）+ {@code avatar_media_id} + {@code default_radius}。</p>
 *
 * @param nickname      昵称（1–20 字符）
 * @param avatarMediaId 已 commit 且 audit_status=pass 的媒体 ID
 * @param defaultRadius 默认搜索半径档
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record UpdateProfileRequest(
        @Size(min = 1, max = 20) String nickname,
        String avatarMediaId,
        String defaultRadius) {
}
