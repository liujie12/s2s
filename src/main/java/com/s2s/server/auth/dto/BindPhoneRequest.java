package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Pattern;

/**
 * 绑定手机号请求（B2-6a；对应 openapi {@code POST /auth/phone/bind} 请求体）。
 *
 * <p>语义：登录态用户（典型为懒绑定下的微信用户）把手机号身份挂到当前账号。
 * 验证码由 {@code POST /auth/sms/send} 的 {@code scene=bind} 下发，
 * 手机号已属于其他账号时拒绝绑定（40302，不自动合并）。</p>
 *
 * @param phone 中国大陆手机号（11 位）
 * @param code  6 位数字验证码
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record BindPhoneRequest(
        @NotBlank @Pattern(regexp = "^1[3-9]\\d{9}$") String phone,
        @NotBlank @Pattern(regexp = "^\\d{6}$") String code) {
}
