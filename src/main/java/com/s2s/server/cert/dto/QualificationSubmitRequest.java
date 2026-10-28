package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.time.Instant;
import java.util.List;

/**
 * 提交资质认证请求（对应 openapi {@code POST /cert/qualification} 请求体
 * {@code QualificationSubmitRequest}）。
 *
 * <p>本轮取消人工审核，提交即生效：字段包含类型、证照图、证名与有效期。
 * 证名与有效期由 {@code POST /cert/ocr} 预填，用户确认后提交；抽取失败时
 * {@code certName}/{@code expireAt} 可为空，但 {@code expireType=dated} 时
 * {@code expireAt} 必填（由 service 校验，缺失回 40001）。</p>
 *
 * @param certType   认证类型（{@code personal_qualification/enterprise/vehicle}）
 * @param mediaIds   证照图 media_id 列表（至少 1 项，首张参与 OCR 预填）
 * @param certName   证书名称（可空）
 * @param nameSource 证名来源（{@code ocr}/{@code manual}，可空）
 * @param expireType 有效期类型（{@code dated}/{@code permanent}）
 * @param expireAt   有效期至（{@code expireType=dated} 时必填；UTC 时刻）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record QualificationSubmitRequest(
        @NotBlank String certType,
        @NotNull @Size(min = 1) List<String> mediaIds,
        @Size(max = 64) String certName,
        String nameSource,
        @NotBlank String expireType,
        Instant expireAt) {
}
