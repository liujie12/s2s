package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

/**
 * 微信授权登录请求（B2-6a；对应 openapi {@code POST /auth/wechat/login} 请求体）。
 *
 * <p>字段设计：客户端经微信 SDK 拉起授权后拿到一次性 {@code code}（最长 64 字符，
 * 微信官方文档明定），服务端用此 code 向微信服务器交换 {@code openid + access_token}。
 * 其余字段（{@code agreed} / {@code platform} / {@code push_token}）语义与
 * {@link LoginRequest} 完全一致，复用 auth 域通用登录协议：先查协议 → 再鉴权凭据 →
 * 成功后写 device 表。</p>
 *
 * @param code      微信授权 code（一次性，最长 64 字符，由客户端经微信 SDK 获得）
 * @param agreed    是否已勾选《用户协议》与《隐私政策》（false/缺失回 40002）
 * @param platform  客户端平台（{@code android/ios}），用于写 device 表
 * @param pushToken 推送 token（可空，上限 128）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record WechatLoginRequest(
        @NotBlank @Size(max = 64) String code,
        @NotNull Boolean agreed,
        String platform,
        @Size(max = 128) String pushToken) {
}
