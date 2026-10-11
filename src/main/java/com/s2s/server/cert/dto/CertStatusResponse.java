package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 认证状态响应（[149]；对应 openapi {@code CertStatusResponse}）。
 *
 * <p>实名状态读 {@code user.realname_status}；资质列表读 {@code cert} 表（本轮恒空，
 * 人工审核未上线）。敏感列（{@code real_name}/{@code id_card}）永不出现在本响应。</p>
 *
 * @param realname       实名状态（{@code status} 子对象）
 * @param qualifications 资质列表（本轮恒空）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CertStatusResponse(
        RealnameStatus realname,
        List<QualificationItem> qualifications) {

    /**
     * 实名状态子对象（契约 {@code realname.status}）。
     *
     * @param status 实名状态（{@code none/pending/passed/rejected}）
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record RealnameStatus(String status) {
    }
}
