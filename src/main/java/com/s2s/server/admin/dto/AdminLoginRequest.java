package com.s2s.server.admin.dto;

import jakarta.validation.constraints.NotBlank;

/**
 * 后台登录入参（[153] B2-5；{@code POST /admin/login}）。
 *
 * @param username 登录名（非空）
 * @param password 口令明文（非空；服务端用 PBKDF2 校验，不落库）
 */
public record AdminLoginRequest(
        @NotBlank String username,
        @NotBlank String password) {
}
