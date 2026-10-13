package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 更新后台账号入参（[153] B2-5；PRD §9.10.1 超管「账号与角色管理」）。
 *
 * <p>{@code null} 字段表示「不改该项」。</p>
 *
 * @param role   新角色落库值（可空）
 * @param status 新状态 active/disabled（可空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminAccountUpdateRequest(
        String role,
        String status) {
}
