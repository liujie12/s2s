package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;

/**
 * 模板保存入参（[153] B2-5 ②；PRD §9.10.1 ②「保存新版本」）。
 *
 * @param fields 新 Schema JSON（必须为非空数组；形状同模板字段定义，非法 → 40001）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminTemplateSaveRequest(@NotNull JsonNode fields) {
}
