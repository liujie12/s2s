package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;

/**
 * 证照图抽取请求（对应 openapi {@code POST /cert/ocr} 请求体）。
 *
 * @param mediaId 已 commit 的证照图 media_id
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CertOcrRequest(@NotBlank String mediaId) {
}
