package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 撮合权重配置出参（[153] B2-5；PRD §9.10.1 ③、§6.11）。
 *
 * @param weightTime         时效权重（默认 0.40）
 * @param weightDistance     距离权重（默认 0.40）
 * @param weightCompleteness 完整度档权重（默认 0.20）
 * @param gbdtEnabled        GBDT override 开关
 * @param grayRatio          AB 灰度比例（整数百分比 0–100）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MatchConfigResponse(
        double weightTime,
        double weightDistance,
        double weightCompleteness,
        boolean gbdtEnabled,
        int grayRatio) {
}
