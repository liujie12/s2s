package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 重置后台账号口令入参（[153] B2-5）。
 *
 * @param newPassword 新口令（长度下限见 {@code NfrAdmin.PASSWORD_MIN_LENGTH}，服务层校验）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminPasswordResetRequest(
        @NotBlank @Size(max = 128) String newPassword) {
}
