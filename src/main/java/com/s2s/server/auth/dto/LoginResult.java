package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 短信验证码登录响应（[123] U3；对应 openapi {@code LoginResult} schema）。
 *
 * <p>字段与契约逐字对齐：{@code token}（JWT，30 天）+ {@code expire_at}
 * （到期时间，服务端为准）+ {@code is_new_user} + {@code user}（{@link MyProfile}）。</p>
 *
 * <p>{@code expireAt} 用 {@link Instant}：前端 [api_client.dart](lib/core/network/api_client.dart)
 * 明定 {@code expire_at} 为 RFC3339 UTC（解析后 {@code .toUtc()}），Jackson 对 {@link Instant}
 * 默认序列化为 ISO-8601 UTC（含 {@code Z}），逐字对齐。</p>
 *
 * @param token     JWT，有效期 30 天
 * @param expireAt  到期时间（服务端为准，仅供展示；序列化 RFC3339 UTC）
 * @param isNewUser true 表示本次登录同时完成注册，客户端应引导完善资料
 * @param user      本人资料
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record LoginResult(
        String token,
        Instant expireAt,
        boolean isNewUser,
        MyProfile user) {
}
