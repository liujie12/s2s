package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Size;

/**
 * 更新类目可配字段入参（[153] B2-5 ①；PRD §9.10.1 ①）。
 *
 * <p>字段为 {@code null} 表示<b>不改该列</b>（本表无「清空」语义）。</p>
 *
 * @param name      新名（可空）
 * @param icon      新图标（可空）
 * @param needCert  新高敏认证类型（可空）
 * @param forbidden 禁发标记（0/1，可空）
 * @param sortOrder 排序号（可空）
 * @param clusterThreshold 差异化聚合阈值（可空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCategoryUpdateRequest(
        @Size(max = 32) String name,
        @Size(max = 64) String icon,
        @Size(max = 32) String needCert,
        @Min(0) @Max(1) Integer forbidden,
        Integer sortOrder) {
}
