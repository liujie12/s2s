package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;

/**
 * 提交资质认证请求（[149]；对应 openapi {@code POST /cert/qualification} 请求体
 * {@code QualificationSubmitRequest}）。
 *
 * <p>字段与契约逐字对齐：{@code cert_type}（个人资质/企业/车辆）+ {@code media_ids}
 * （OCR 证照图 media_id 列表，至少 1 项）。</p>
 *
 * @param certType 认证类型（{@code personal_qualification/enterprise/vehicle}）
 * @param mediaIds OCR 证照图 media_id 列表
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitRequest(
        @NotBlank String certType,
        @NotNull @Size(min = 1) List<String> mediaIds) {
}
