package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 提交资质认证请求（对应 openapi {@code POST /cert/qualification} 请求体
 * {@code QualificationSubmitRequest}）。
 *
 * <p>2026-10-28 产品口径简化：资质只要「证照图 + 证书名」，不再选择证件类型、不再有有效期。
 * 本轮取消人工审核，提交即生效（{@code approved}）。证书名由 {@code POST /cert/ocr}
 * 预填，用户确认后提交；抽取失败且用户未填时 {@code certName} 可为空。</p>
 *
 * @param mediaIds   证照图 media_id 列表（必填，至少 1 项，首张作为证照图）
 * @param certName   证书名称（可空；最长 64 字，超出由 service 回 40001）
 * @param nameSource 证名来源（{@code ocr}/{@code manual}，可空；其他值由 service 回 40001）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitRequest(
        @NotNull @Size(min = 1) List<String> mediaIds,
        @Size(max = 64) String certName,
        String nameSource) {
}
