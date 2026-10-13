package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 新建后台账号入参（[153] B2-5；PRD §9.10.1 超管「账号与角色管理」）。
 *
 * @param username 登录名（唯一）
 * @param password 初始口令（长度下限见 {@code NfrAdmin.PASSWORD_MIN_LENGTH}，服务层校验）
 * @param role     角色落库值（super_admin/auditor/operator/algo）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminAccountCreateRequest(
        @NotBlank @Size(max = 64) String username,
        @NotBlank @Size(max = 128) String password,
        @NotBlank String role) {
}
