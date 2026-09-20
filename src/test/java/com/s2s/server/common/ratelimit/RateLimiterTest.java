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
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
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
 *   <li>Lua 返回 null → 放行（toLong(null)=0，不误判超限）。</li>
 * </ol>
 *
 * <p><b>测试策略（[122] review P0 回归）</b>：Redis 用 Mockito mock 的
 * {@link StringRedisTemplate}，{@code execute} 返回 <b>{@code String}</b>（而非 {@code List<Long>}）——
 * 真实运行时 StringRedisTemplate 的 {@code StringRedisSerializer} 会把 Lua 数字返回值
 * 反序列化为 {@code String}，此前的测试 mock 返回 {@code List<Long>} 掩盖了
 * {@code ClassCastException} 类型失配（green-while-red）。本测试锁定真实类型，
 * 验证 {@link RateLimiter#toLong(Object)} 的可靠解包。
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
     * 场景一：单键计数未超限——Lua 返回 "5"（String，模拟真实反序列化），
     * toLong 解包为 5（≤ 阈值 10），返回 -1（未超限）。
     *
     * @return void；断言失败即 toLong 对 String 解包错误或未超限判错
     */
    @Test
    void singleKeyUnderLimitReturnsNegative() {
        when(redisTemplate.execute(any(RedisScript.class), anyList(), anyString()))
                .thenReturn("5");

        long result = rateLimiter.incrementAndCheck(singleEntry("rl:contact:uid:1:1d:20260918", 60, 60, 10));

        assertThat(result).isEqualTo(-1);
    }

    /**
     * 场景二：单键计数超限——Lua 返回 "11"（> 阈值 10），抛异常带超限码与
     * retryAfterSeconds（entry 显式声明 42，不用 Lua TTL）。
     *
     * @return void；断言失败即超限判定或剩余秒传递错误
     */
    @Test
    void singleKeyOverLimitThrowsWithRetryAfter() {
        when(redisTemplate.execute(any(RedisScript.class), anyList(), anyString()))
                .thenReturn("11");

        assertThatThrownBy(() -> rateLimiter.incrementAndCheck(
                singleEntry("rl:contact:uid:1:1d:20260918", 60, 42, 10)))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(42L);
                });
    }

    /**
     * 场景三：多轨同时超限取 max 剩余秒——两轨分别超限，retryAfterSeconds 10 和 50，取 50。
     * Lua 返回值按「依次调用」返回 "11"（两轨都超限）。
     *
     * @return void；断言失败即 max 逻辑取错
     */
    @Test
    void multiTrackOverLimitTakesMaxRetryAfter() {
        when(redisTemplate.execute(any(RedisScript.class), any(List.class), anyString()))
                .thenReturn("11")
                .thenReturn("11");

        List<RateLimiter.RateLimitEntry> entries = Arrays.asList(
                new RateLimiter.RateLimitEntry("rl:a:1", 60, 10, 10, ErrorCode.CONTACT_LIMIT),
                new RateLimiter.RateLimitEntry("rl:b:1", 60, 50, 10, ErrorCode.CONTACT_LIMIT));

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
        when(redisTemplate.execute(any(RedisScript.class), anyList(), anyString()))
                .thenThrow(new RuntimeException("Redis connection refused"));

        long result = rateLimiter.incrementAndCheck(
                singleEntry("rl:track:uid:1:1m", 60, 60, 60));

        assertThat(result).isEqualTo(-1);
    }

    /**
     * 场景五：Lua 返回 null → toLong(null)=0，不超限（放行）。
     *
     * @return void；断言失败即 null 结果未做防御
     */
    @Test
    void nullLuaResultIsSwallowedAndAllows() {
        when(redisTemplate.execute(any(RedisScript.class), anyList(), anyString()))
                .thenReturn(null);

        long result = rateLimiter.incrementAndCheck(
                singleEntry("rl:track:uid:1:1m", 60, 60, 60));

        assertThat(result).isEqualTo(-1);
    }

    /**
     * 场景六：多轨中一轨超限、一轨未超限 → 只判超限的轨，剩余秒取超限者。
     * 第一轨 "11" 超限（retryAfter 30），第二轨 "5" 未超限。
     *
     * @return void；断言失败即部分超限判定错误
     */
    @Test
    void multiTrackPartialOverLimitTakesOverLimitTrack() {
        when(redisTemplate.execute(any(RedisScript.class), any(List.class), anyString()))
                .thenReturn("11")
                .thenReturn("5");

        List<RateLimiter.RateLimitEntry> entries = Arrays.asList(
                new RateLimiter.RateLimitEntry("rl:a:1", 60, 30, 10, ErrorCode.CONTACT_LIMIT),
                new RateLimiter.RateLimitEntry("rl:b:1", 60, 60, 10, ErrorCode.CONTACT_LIMIT));

        assertThatThrownBy(() -> rateLimiter.incrementAndCheck(entries))
                .isInstanceOf(BizException.class)
                .satisfies(ex -> {
                    BizException biz = (BizException) ex;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
                    assertThat(biz.getRetryAfterSeconds()).isEqualTo(30L);
                });
    }

    /**
     * 辅助：构造单键条目列表（ttl 与 retryAfter 相等，滚动窗口语义）。
     *
     * @param key           Redis 键
     * @param ttlSeconds    键 TTL
     * @param retryAfter    Retry-After 剩余秒
     * @param limit         阈值
     * @return 含单条目的列表
     */
    private static List<RateLimiter.RateLimitEntry> singleEntry(
            String key, long ttlSeconds, long retryAfter, int limit) {
        return List.of(new RateLimiter.RateLimitEntry(
                key, ttlSeconds, retryAfter, limit, ErrorCode.CONTACT_LIMIT));
    }
}
