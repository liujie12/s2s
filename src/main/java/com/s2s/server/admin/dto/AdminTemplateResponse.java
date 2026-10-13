package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 模板读取出参（[153] B2-5 ②；PRD §9.10.1 ②）。
 *
 * @param templateKey     模板键（即 {@code template.leaf_category_id}；本工程按 <b>L2 父级</b> 存储）
 * @param templateVersion 当前模板版本号（无自定义模板时为 0）
 * @param fields          Schema JSON（数组；无自定义模板时为 null，前端按通用模板渲染）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminTemplateResponse(
        int templateKey,
        int templateVersion,
        JsonNode fields) {
}
