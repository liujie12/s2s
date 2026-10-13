package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 复核认证敏感查看申请入参（[153] B2-5；PRD §9.10.1「需另一名管理员确认」）。
 *
 * @param approved 是否通过（必填）
 * @param reason   复核说明（驳回时必填，对齐 PRD §9.10.1「驳回强制填写理由」）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCertAccessReviewRequest(
        @NotNull Boolean approved,
        @Size(max = 255) String reason) {
}
