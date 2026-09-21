package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;

/**
 * 短信验证码登录请求（[123] U3；对应 openapi {@code POST /auth/sms/login} 请求体）。
 *
 * <p>字段与契约逐字对齐：{@code phone} + {@code code} + {@code agreed} 为必填
 * （{@code agreed=false} 或缺失回 {@code 40002}）；{@code platform} / {@code push_token}
 * 可选，用于写 {@code device} 表。</p>
 *
 * @param phone     中国大陆手机号（11 位）
 * @param code      6 位数字验证码
 * @param agreed    是否已勾选《用户协议》与《隐私政策》（false/缺失回 40002）
 * @param platform  客户端平台（{@code android/ios}），用于写 device 表
 * @param pushToken 推送 token（可空，上限 128）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record LoginRequest(
        @NotBlank @Pattern(regexp = "^1[3-9]\\d{9}$") String phone,
        @NotBlank @Pattern(regexp = "^\\d{6}$") String code,
        @NotNull Boolean agreed,
        String platform,
        @Size(max = 128) String pushToken) {
}
