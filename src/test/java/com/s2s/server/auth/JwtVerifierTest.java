package com.s2s.server.auth;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import io.jsonwebtoken.Jwts;
import io.jsonwebtoken.security.Keys;
import java.nio.charset.StandardCharsets;
import java.util.Date;
import java.util.concurrent.TimeUnit;
import javax.crypto.SecretKey;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;
import static org.mockito.Mockito.verify;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;

/**
 * {@link JwtVerifier} 行为测试（[122] U3；详设 §3.1 鉴权段；KTD7/KTD10）。
 *
 * <p>覆盖计划 U3 Test scenarios 的 JWT 解析与黑名单场景：
 * <ol>
 *   <li>有效 Token 未入黑名单 → 返回 userId；</li>
 *   <li>无效签名 Token → 40101；</li>
 *   <li>格式错误 Token（非 JWT 结构）→ 40101；</li>
 *   <li>过期 Token → 40101；</li>
 *   <li>Token 在黑名单 → 40101；</li>
 *   <li>Redis 查询抛异常 → 50001（KTD7 红线：读故障不降级放行）。</li>
 * </ol>
 *
 * <p>测试策略：用 jjwt 在测试侧签发 Token（密钥与被测 verifier 一致），
 * Redis 用 Mockito mock 的 {@link StringRedisTemplate}，避免启动真实 Redis 或
 * 嵌入式 Redis（纯单测，KTD12：standalone 不起 Spring 容器）。
 */
class JwtVerifierTest {

    /** 测试用密钥（32 字节 HS256 密钥）。 */
    private static final String TEST_SECRET = "test-secret-key-32-bytes-minimum!!";
    private static final SecretKey TEST_KEY =
            Keys.hmacShaKeyFor(TEST_SECRET.getBytes(StandardCharsets.UTF_8));

    /** 被测 verifier。 */
    private JwtVerifier verifier;

    /** mock 的 Redis 模板（黑名单桩）。 */
    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOps;

    /**
     * 每测前置：构造 mock Redis 和被测 verifier。
     * 默认 mock 行为：黑名单 get 返回 null（未命中），即所有 Token 都不在黑名单中。
     *
     * @return void
     */
    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        when(valueOps.get(anyString())).thenReturn(null); // 默认未命中黑名单
        verifier = JwtVerifier.forTest(TEST_KEY, redisTemplate);
    }

    /**
     * 场景一：有效 Token（签名正确、未过期、不在黑名单）→ 成功返回 userId（sub 字段的 Long 值）。
     *
     * @return void；断言失败即验签或 sub 解析有问题
     */
    @Test
    void validTokenReturnsUserId() {
        String token = buildToken(42L, "jti-abc-123", 3600_000); // 1 小时后过期

        Long userId = verifier.verifyAndGetUserId(token);

        assertThat(userId).isEqualTo(42L);
        // 验证黑名单查询被调用且键名正确
        verify(valueOps).get(eq(JwtVerifier.BLACKLIST_KEY_PREFIX + "jti-abc-123"));
    }

    /**
     * 场景二：无效签名的 Token → 40101。
     * 用不同的密钥签发 Token，模拟签名不匹配。
     *
     * @return void；断言失败即签名校验不严格
     */
    @Test
    void invalidSignatureThrowsUnauthorized() {
        SecretKey wrongKey = Keys.hmacShaKeyFor(
                "wrong-secret-key-32-bytes-minimum!".getBytes(StandardCharsets.UTF_8));
        String token = buildTokenWithKey(wrongKey, 99L, "jti-wrong", 3600_000);

        assertThatThrownBy(() -> verifier.verifyAndGetUserId(token))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景三：格式完全错误的字符串（非 JWT 结构）→ 40101。
     *
     * @return void；断言失败即前置格式校验缺失
     */
    @Test
    void malformedTokenThrowsUnauthorized() {
        assertThatThrownBy(() -> verifier.verifyAndGetUserId("not-a-jwt-token-at-all"))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景四：过期 Token → 40101。
     * 签发一个已过期的 Token（exp 设为过去时间）。
     *
     * @return void；断言失败即过期校验缺失
     */
    @Test
    void expiredTokenThrowsUnauthorized() {
        // 签发一个 1 秒后过期的 Token，然后等 2 秒让它过期
        String token = buildToken(77L, "jti-expired", 100); // 100ms 过期

        // 等过期
        try {
            TimeUnit.MILLISECONDS.sleep(200);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }

        assertThatThrownBy(() -> verifier.verifyAndGetUserId(token))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景五：Token 在黑名单中 → 40101。
     * mock Redis 返回非 null 值（黑名单命中），验证拒绝。
     *
     * @return void；断言失败即黑名单校验缺失
     */
    @Test
    void blacklistedTokenThrowsUnauthorized() {
        String jti = "jti-blacklisted";
        String token = buildToken(55L, jti, 3600_000);
        when(valueOps.get(eq(JwtVerifier.BLACKLIST_KEY_PREFIX + jti))).thenReturn("1");

        assertThatThrownBy(() -> verifier.verifyAndGetUserId(token))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.UNAUTHORIZED));
    }

    /**
     * 场景六：Redis 查询抛异常 → 50001（KTD7 红线：读故障不降级放行）。
     * 模拟 Redis 连接失败，验证抛 50001 而非 40101 或默默放行。
     *
     * @return void；断言失败即 KTD7 安全红线未守住
     */
    @Test
    void redisFailureThrowsInternalError() {
        String token = buildToken(88L, "jti-redis-err", 3600_000);
        when(valueOps.get(anyString())).thenThrow(new RuntimeException("Redis connection refused"));

        assertThatThrownBy(() -> verifier.verifyAndGetUserId(token))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> assertThat(((BizException) ex).getErrorCode())
                        .isEqualTo(ErrorCode.INTERNAL_ERROR));
    }

    /**
     * 辅助方法：用测试密钥签发一个 JWT（HS256，sub=userId，jti=tokenId）。
     *
     * @param userId       写入 sub 的用户 ID
     * @param jti          写入 jti 的 Token 唯一标识
     * @param ttlMillis    Token 有效期（毫秒，从当前时间算起）
     * @return {@link String} JWT 字符串
     */
    private String buildToken(long userId, String jti, long ttlMillis) {
        return buildTokenWithKey(TEST_KEY, userId, jti, ttlMillis);
    }

    /**
     * 辅助方法：用指定密钥签发 JWT（用于测试「不同密钥 = 签名不匹配」场景）。
     *
     * @param key       HMAC-SHA256 密钥
     * @param userId    写入 sub 的用户 ID
     * @param jti       写入 jti 的 Token 唯一标识
     * @param ttlMillis Token 有效期（毫秒）
     * @return {@link String} JWT 字符串
     */
    private String buildTokenWithKey(SecretKey key, long userId, String jti, long ttlMillis) {
        long now = System.currentTimeMillis();
        return Jwts.builder()
                .subject(String.valueOf(userId))
                .id(jti)
                .issuedAt(new Date(now))
                .expiration(new Date(now + ttlMillis))
                .signWith(key)
                .compact();
    }
}
