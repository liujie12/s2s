package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 提交实名认证响应（[149]；对应 openapi {@code RealnameSubmitResult}）。
 *
 * <p>只回实名状态，不回任何敏感列（{@code real_name}/{@code id_card} 禁止出现在响应）。</p>
 *
 * @param status 实名状态（{@code none/pending/passed/rejected}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record RealnameSubmitResult(String status) {
}
