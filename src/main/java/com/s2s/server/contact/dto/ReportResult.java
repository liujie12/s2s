package com.s2s.server.contact.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 举报受理结果（[128]；对应 openapi {@code POST /posts/{post_id}/report} 响应 {@code data}）。
 *
 * <p>新建举报的 {@code status} 恒为 {@code pending}（DDL 默认值），运营处理后才会变为
 * {@code handled}/{@code dismissed}——本 DTO 仍声明 {@code status} 字段而非写死常量，
 * 是为了让响应体与契约 schema 逐字一致（客户端按 schema 解析，多一个字段不会崩，
 * 少一个字段会崩）。</p>
 *
 * @param reportId 举报记录 ID（{@code report.id}，客户端可用于后续查询处理进展）
 * @param status   处理状态（新建恒 {@code pending}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ReportResult(
        Long reportId,
        String status) {
}
