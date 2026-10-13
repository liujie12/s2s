package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotEmpty;
import java.util.List;

/**
 * 举报工单<b>批量</b>处理入参（[153] B2-5 ④；PRD §9.10.1 ④「批量处理」）。
 *
 * <p>整批**同事务**：任一条失败（不存在/已处理/动作非法）则整批回滚，不做部分成功
 * —— 「一半下架一半没下」对运营是无法核对的中间态。</p>
 *
 * @param reportIds 举报 ID 列表（非空；单次上限见 {@code NfrAdmin.BATCH_MAX}）
 * @param action    处理动作：{@code false_report} 或 {@code offline}
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminReportBatchHandleRequest(
        @NotEmpty List<Long> reportIds,
        @NotBlank String action) {
}
