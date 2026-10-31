package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 消息功能总开关入参（V30 / U8；R30）。
 *
 * @param enabled 目标状态（必填）：{@code false} 即把消息域置为只读
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MessageSwitchUpdateRequest(
        @NotNull Boolean enabled) {
}
