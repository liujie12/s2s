package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 新增叶子类目入参（[153] B2-5 ①；PRD §9.10.1 ①「新增/禁用类目（leaf 级）」）。
 *
 * @param parentId  挂载的二级类目 ID（必填；非 L2 → 40001）
 * @param name      类目名（必填）
 * @param icon      图标名（可空）
 * @param needCert  高敏所需认证类型（可空 = 非高敏）
 * @param forbidden 禁发标记（0/1，可空 = 0）
 * @param sortOrder 同级排序（可空 = 0）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCategoryCreateRequest(
        @NotNull Integer parentId,
        @NotBlank @Size(max = 32) String name,
        @Size(max = 64) String icon,
        @Size(max = 32) String needCert,
        @Min(0) @Max(1) Integer forbidden,
        Integer sortOrder) {
}
