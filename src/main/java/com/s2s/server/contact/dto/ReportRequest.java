package com.s2s.server.contact.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 举报入参（[128]；对应 openapi {@code POST /posts/{post_id}/report} 请求体）。
 *
 * <p><b>{@code reason} 是唯一必填项</b>（契约 {@code required: [reason]}）：无原因的举报
 * 无法进入 §9.10.3 的权重计算——风险分按举报原因分级累计，缺原因只能记 0 分，
 * 等于收下一条永远不参与判定的记录。故缺失即 Bean Validation 拒绝 → {@code 40001}。</p>
 *
 * <p>字段名与列名的漂移（KTD4 同类）：契约叫 {@code remark}，落库列是
 * {@code report.description}（DDL V1:267），映射在 service 完成。</p>
 *
 * @param reason   举报原因；取值须与 {@code report.reason} 列枚举严格一致
 *                 （{@code false_info}/{@code fraud}/{@code wrong_category}/
 *                 {@code harassment}/{@code other}），合法性校验在 service 完成
 * @param remark   补充说明（可空；契约 {@code maxLength: 200}）
 * @param evidence 证据媒体 ID 列表（可空；契约 {@code maxItems: 3}，落
 *                 {@code report.evidence} JSON 列）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ReportRequest(
        @NotBlank(message = "reason") String reason,
        @Size(max = 200, message = "remark") String remark,
        @Size(max = 3, message = "evidence") List<String> evidence) {
}
