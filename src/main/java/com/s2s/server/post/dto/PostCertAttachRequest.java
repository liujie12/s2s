package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 发布后补挂 / 替换凭证声明请求（对应 openapi {@code PUT /posts/{post_id}/cert} 请求体）。
 *
 * @param certId 本人资质档案 ID（须为 approved 且在有效期内）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostCertAttachRequest(@NotNull Long certId) {
}
