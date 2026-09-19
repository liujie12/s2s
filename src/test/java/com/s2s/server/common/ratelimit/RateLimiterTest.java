package com.s2s.server.common.ratelimit;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.RedisScript;

/**
 * {@link RateLimiter} 计数与超限判定测试（[122] U4；详设 §3.4；编码规范 §1.2）。
 *
 * <p>覆盖测试场景：
 * <ol>
 *   <li>单键计数：窗口内第 N 次未超限（返回 -1），第 N+1 次超限（抛异常带剩余秒）；</li>
 *   <li>多轨 max：两轨同时超限取剩余秒较大者；</li>
 *   <li>Redis 写失败：Lua 执行异常 → 放行（不抛异常，返回 -1）；</li>
 *   <li>Lua 返回 null/空 → 放行。</li>
 * </ol>
 *
 * <p>测试策略：Redis 用 Mockito mock 的 {@link StringRedisTemplate}，
 * {@code execute} 方法模拟 Lua 脚本返回值（List<Long> = [current, ttl]）。
 * 纯单测（KTD12：不起 Spring 容器，不依赖嵌入式 Redis）。
 */
class RateLimiterTest {

    /** mock 的 Redis 模板。 */
    private StringRedisTemplate redisTemplate;

    /** 被测限频计数器。 */
    private RateLimiter rateLimiter;

    /**
     * 每测前置：构造 mock Redis 与被测计数器。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        rateLimiter = new RateLimiter(redisTemplate);
    }

    /**
     * 场景一：单键计数未超限——首次 INCR 返回 1（≤ 阈值 10），返回 -1（表示未超限）。
     *
     * @return void；断言失败即计数逻辑把未超限判错了
     */
    @Test
    void singleKeyUnderLimitReturnsNegative() {
        // INCR 返回 current=5, ttl=60
        when(redisTemplate.execute(
                any(RedisScript.class), anyList(), anyString()))
                .thenReturn(Arrays.asList(5L, 60L));

        long result = rateLimiter.incrementAndCheck(
                "rl:contact:uid:1:1d:20260918", 60L, 10, ErrorCode.CONTACT_LIMIT);

        assertThat(result).isEqualTo(-1);
    }

    /**
     * 场景二：单键计数超限——current > 阈值，抛异常带超限码与剩余秒数。
     *
     * @return void；断言失败即超限判定或剩余秒数传递错误
     */
    @Test
    void singleKeyOverLimitThrowsWithRetryAfter() {
        // INCR 返回 current=11 (> 10), ttl=42
        when(redisTemplate.execute(
                any(RedisScript.class), anyList(), anyString()))
                .thenReturn(Arrays.asList(11L, 42L));

        assertThatThrownBy(() -> rateLimiter.incrementAndCheck(
                "rl:contact:uid:1:1d:20260918", 60L, 10, ErrorCode.CONTACT_LIMIT))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(42L);
                });
    }

    /**
     * 场景三：多轨同时超限取 max 剩余秒——两轨分别超限，剩余秒 10 和 50，取 50。
     *
     * @return void；断言失败即 max 逻辑取错
     */
    @Test
    void multiTrackOverLimitTakesMaxRetryAfter() {
        // 第一轨返回 current=11, ttl=10；第二轨返回 current=11, ttl=50
        when(redisTemplate.execute(
                any(RedisScript.class), any(List.class), anyString()))
                .thenReturn(Arrays.asList(11L, 10L))   // 第一次调用
                .thenReturn(Arrays.asList(11L, 50L));  // 第二次调用

        List<RateLimiter.RateLimitEntry> entries = Arrays.asList(
                new RateLimiter.RateLimitEntry("rl:a:1", 60L, 10, ErrorCode.CONTACT_LIMIT),
                new RateLimiter.RateLimitEntry("rl:b:1", 60L, 10, ErrorCode.CONTACT_LIMIT));

        assertThatThrownBy(() -> rateLimiter.incrementAndCheck(entries))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(50L);
                });
    }

    /**
     * 场景四：Redis 写失败（Lua 抛异常）→ 放行（不抛异常）。
     * 限频计数允许丢失（详设 §3.4 纪律 3：防滥用非账务），Redis 故障放行而非 50001。
     *
     * @return void；断言失败即写失败未放行（把限频故障当成了致命错误）
     */
    @Test
    void redisFailureIsSwallowedAndAllows() {
        when(redisTemplate.execute(
                any(RedisScript.class), anyList(), anyString()))
                .thenThrow(new RuntimeException("Redis connection refused"));

        // 不应抛异常 —— 写失败放行
        long result = rateLimiter.incrementAndCheck(
                "rl:track:uid:1:1m", 60L, 60, ErrorCode.TRACK_LIMIT);

        assertThat(result).isEqualTo(-1);
    }

    /**
     * 场景五：Lua 返回 null（异常返回）→ 放行。
     *
     * @return void；断言失败即 null 结果未做防御
     */
    @Test
    void nullLuaResultIsSwallowedAndAllows() {
        when(redisTemplate.execute(
                any(RedisScript.class), anyList(), anyString()))
                .thenReturn(null);

        long result = rateLimiter.incrementAndCheck(
                "rl:track:uid:1:1m", 60L, 60, ErrorCode.TRACK_LIMIT);

        assertThat(result).isEqualTo(-1);
    }

    /**
     * 场景六：多轨中一轨超限、一轨未超限 → 只判超限的轨，剩余秒取超限者。
     * 第一轨 current=11>10 超限 ttl=30，第二轨 current=5<10 未超限。
     *
     * @return void；断言失败即部分超限判定错误
     */
    @Test
    void multiTrackPartialOverLimitTakesOverLimitTrack() {
        when(redisTemplate.execute(
                any(RedisScript.class), any(List.class), anyString()))
                .thenReturn(Arrays.asList(11L, 30L))  // 超限
                .thenReturn(Arrays.asList(5L, 60L));  // 未超限

        List<RateLimiter.RateLimitEntry> entries = Arrays.asList(
                new RateLimiter.RateLimitEntry("rl:a:1", 60L, 10, ErrorCode.CONTACT_LIMIT),
                new RateLimiter.RateLimitEntry("rl:b:1", 60L, 10, ErrorCode.CONTACT_LIMIT));

        assertThatThrownBy(() -> rateLimiter.incrementAndCheck(entries))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(30L);
                });
    }
}