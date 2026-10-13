package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 创建 72h 临时类目入参（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * @param l2ParentId 挂载的「临时」二级类目 ID（必填；非 L2 → 40001）
 * @param name       临时类目名（必填）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminTempCategoryCreateRequest(
        @NotNull Integer l2ParentId,
        @NotBlank @Size(max = 32) String name) {
}
