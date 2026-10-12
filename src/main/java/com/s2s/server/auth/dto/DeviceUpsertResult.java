package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 推送 token 上报结果（[B2-2]；对应 openapi {@code DeviceUpsertResult}）。
 *
 * @param deviceId 被写入的 {@code device} 行 ID（新增或命中同一指纹）
 * @param platform 实际落库的推送通道（回显，供客户端核对）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record DeviceUpsertResult(Long deviceId, String platform) {
}
