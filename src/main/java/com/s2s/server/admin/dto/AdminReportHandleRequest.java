package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;

/**
 * 举报工单处理入参（[153] B2-5 ④；PRD §9.10.1 ④）。
 *
 * @param action 处理动作：{@code false_report}（打标误报，回撤风险分）或
 *               {@code offline}（判定下架）；其余值 → 40001
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminReportHandleRequest(@NotBlank String action) {
}
