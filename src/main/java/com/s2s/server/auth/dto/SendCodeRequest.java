package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;

/**
 * 发送短信验证码请求（[123] U3；对应 openapi {@code POST /auth/sms/send} 请求体）。
 *
 * <p>字段与契约逐字对齐：{@code phone}（11 位中国大陆手机号）+ {@code scene}
 * （验证码场景，Batch1 仅 {@code login}）。校验注解为 Bean Validation 输入校验
 * （编码规范 §4.12）的承载层。</p>
 *
 * @param phone 中国大陆手机号（11 位，{@code ^1[3-9]\d{9}$}）
 * @param scene 验证码场景（Batch1 仅 {@code login}）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SendCodeRequest(
        @NotBlank @Pattern(regexp = "^1[3-9]\\d{9}$") String phone,
        @NotBlank String scene) {
}
