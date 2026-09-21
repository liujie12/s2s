package com.s2s.server.auth.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * Token 续期响应（[123] U6；对应 openapi {@code POST /auth/token/refresh} 出参）。
 *
 * <p>出参只有 {@code token} + {@code expire_at} 两字段（openapi 内联 schema），
 * 与 {@link LoginResult}（含 {@code is_new_user} + {@code user}）区分——
 * 续期不改变用户资料，无需回传 {@code user}。</p>
 *
 * <p>{@code expireAt} 用 {@link Instant}（RFC3339 UTC，与 {@link LoginResult} 同口径）。</p>
 *
 * @param token    新签发的 JWT（有效期 30 天）
 * @param expireAt 新 Token 到期时间（服务端为准，序列化 RFC3339 UTC）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record RefreshResult(String token, Instant expireAt) {
}
