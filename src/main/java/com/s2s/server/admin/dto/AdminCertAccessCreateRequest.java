package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 发起认证敏感查看复核申请入参（[153] B2-5；PRD §9.10.1「敏感查看双人复核」）。
 *
 * @param certId 目标认证记录 ID（必填）
 * @param reason 查看理由（必填，合规举证）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCertAccessCreateRequest(
        @NotNull Long certId,
        @NotBlank @Size(max = 255) String reason) {
}
