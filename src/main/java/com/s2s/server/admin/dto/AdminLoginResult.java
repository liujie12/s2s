package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 后台登录出参（[153] B2-5）。
 *
 * @param token 后台 Token（{@code scope=admin}；用法同 C 端 {@code Authorization: Bearer}）
 * @param role  当前账号角色落库值（super_admin/auditor/operator/algo），供前端按角色渲染入口
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminLoginResult(String token, String role) {
}
