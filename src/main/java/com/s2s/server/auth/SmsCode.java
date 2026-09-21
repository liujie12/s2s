package com.s2s.server.auth;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 验证码 Redis 存储值（[123] U4；plan KTD1）。
 *
 * <p>值结构 {@code {code, expire_at}}。失败计数<b>不</b>放在本值内（plan KTD1 初稿的
 * {@code fail_count} 字段已废弃）——按详设 §3.4 行 3 的权威口径，登录失败锁定用独立
 * 限频键 {@code rl:login:fail:{phone}}（{@code RateLimitTrack.LOGIN_FAIL}）承载，与
 * 验证码值解耦，避免失败计数随验证码 TTL（5 分钟）一并过期丢失（plan KTD1 初稿的
 * 键 {@code sms:lock:{phone}} 与 {@code fail_count} 字段均按此口径回退）。</p>
 *
 * <p>这是 Redis 内部存储结构（非 API 出参），故不参与 {@code ResponseBodyWrapper}
 * 套壳，仅经 {@code ObjectMapper} 序列化为 JSON 落 Redis。</p>
 *
 * @param code     验证码（dev 桩固定 {@code 888888}）
 * @param expireAt 验证码到期时刻（服务端生成，供 U5 校验过期）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SmsCode(String code, Instant expireAt) {
}
