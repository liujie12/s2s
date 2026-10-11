package com.s2s.server.cert.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * 提交实名认证请求（[149]；对应 openapi {@code POST /cert/realname} 请求体
 * {@code RealnameSubmitRequest}）。
 *
 * <p>字段与契约逐字对齐：{@code real_name}（≤64 字符）+ {@code id_card}（18 位身份证号）
 * + {@code agreement_accepted}（必填；{@code false} 回 {@code 40002}）。</p>
 *
 * <p><b>数据最小化红线</b>：{@code real_name}/{@code id_card} 为敏感明文，仅用于核验与
 * 加密落库，禁止出现在任何 API 响应与日志中（编码规范 §4.11、安全 §9.6）。</p>
 *
 * @param realName           真实姓名（明文）
 * @param idCard             18 位身份证号（明文）
 * @param agreementAccepted  是否已同意实名认证相关协议（false/缺失回 40002）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record RealnameSubmitRequest(
        @NotBlank @Size(max = 64) String realName,
        @NotBlank @Pattern(regexp = "^\\d{17}[\\dXx]$") String idCard,
        @NotNull Boolean agreementAccepted) {
}
