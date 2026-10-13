package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 降级开关出参（[153] B2-5；PRD §9.10.1 ⑦）。
 *
 * @param modelDowngradeEnabled 模型降级开关（§6.12 冷启动降级）
 * @param perfDowngradeEnabled  性能降级开关（§6.10.1）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SwitchConfigResponse(
        boolean modelDowngradeEnabled,
        boolean perfDowngradeEnabled) {
}
