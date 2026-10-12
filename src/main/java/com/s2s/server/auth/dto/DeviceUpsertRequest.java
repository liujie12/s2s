package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

/**
 * 推送 token 上报请求（[B2-2]；对应 openapi {@code POST /users/me/devices} 请求体）。
 *
 * <p>字段与契约逐字对齐：{@code platform}（推送通道）+ {@code token} 必填；
 * 通道白名单由 {@code PushPlatform.fromWire} 判定，不在白名单内回 {@code 40001}。</p>
 *
 * @param platform 推送通道（{@code apns}/{@code fcm}/{@code hw}/{@code mi}/
 *                 {@code oppo}/{@code vivo}/{@code honor}）
 * @param token    推送 token（上限 128，与 {@code device.push_token} 列同长）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record DeviceUpsertRequest(
        @NotBlank String platform,
        @NotBlank @Size(max = 128) String token) {
}
