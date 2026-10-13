package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.PositiveOrZero;

/**
 * 撮合权重配置入参（[153] B2-5；PRD §9.10.1 ③）。
 *
 * <p>三项权重之和须为 1（服务层校验，权重口径见 PRD §6.11）；灰度比例为 0–100 整数。</p>
 *
 * @param weightTime         时效权重（≥0）
 * @param weightDistance     距离权重（≥0）
 * @param weightCompleteness 完整度档权重（≥0）
 * @param gbdtEnabled        GBDT override 开关
 * @param grayRatio          AB 灰度比例（0–100）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MatchConfigUpdateRequest(
        @NotNull @PositiveOrZero Double weightTime,
        @NotNull @PositiveOrZero Double weightDistance,
        @NotNull @PositiveOrZero Double weightCompleteness,
        @NotNull Boolean gbdtEnabled,
        @NotNull @Min(0) @Max(100) Integer grayRatio) {
}
