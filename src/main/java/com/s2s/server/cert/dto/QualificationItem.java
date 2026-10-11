package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 资质认证条目（[149]；对应 openapi {@code QualificationItem}）。
 *
 * <p>出自 {@code cert} 表已通过/审核中的资质行。本轮人工审核未上线，资质列表恒空，
 * 本 DTO 仅在契约与测试中承载形态。</p>
 *
 * @param type     认证类型（{@code personal_qualification/enterprise/vehicle}）
 * @param status   认证状态（{@code pending/approved/rejected/expired}）
 * @param expireAt 认证到期时间（可空，资质年审用）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationItem(String type, String status, Instant expireAt) {
}
