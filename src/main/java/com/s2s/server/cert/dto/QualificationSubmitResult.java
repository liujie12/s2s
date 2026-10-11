package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 提交资质认证响应（[149]；对应 openapi {@code QualificationSubmitResult}）。
 *
 * <p>资质本轮落 {@code cert} 表 {@code status='pending'}，人工审核留 B2-5 运营后台，
 * 故 {@code status} 恒 {@code pending}；{@code slaHours} 为人工审核 SLA（PRD §4.5）。</p>
 *
 * @param status   提交后状态（本轮恒 {@code pending}）
 * @param slaHours 人工审核 SLA（小时，PRD §4.5）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitResult(String status, int slaHours) {
}
