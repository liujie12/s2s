package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 降级开关入参（[153] B2-5；PRD §9.10.1 ⑦）。
 *
 * @param modelDowngradeEnabled 模型降级开关
 * @param perfDowngradeEnabled  性能降级开关
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SwitchConfigUpdateRequest(
        @NotNull Boolean modelDowngradeEnabled,
        @NotNull Boolean perfDowngradeEnabled) {
}
