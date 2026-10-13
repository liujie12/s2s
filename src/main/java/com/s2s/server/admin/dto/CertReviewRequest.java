package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 认证审核入参（[153] B2-5 ⑤）。
 *
 * @param approved     true = 通过，false = 驳回
 * @param rejectReason 驳回原因（驳回时必填，服务层校验；PRD §9.10.1「下架与驳回强制填写理由」）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CertReviewRequest(
        @NotNull Boolean approved,
        String rejectReason) {
}
