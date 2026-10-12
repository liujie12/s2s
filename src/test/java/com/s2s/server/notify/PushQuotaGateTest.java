package com.s2s.server.notify;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.NfrPush;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import java.time.Duration;
import java.time.LocalDate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link PushQuotaGate} 每日推送配额测试（[B2-2]；PRD §6.14 / §12.3）。
 *
 * <p>守的是什么：配额是「≤10 条/日」的**唯一落点**，且它的两种失败方向代价不同 ——
 * 多放一条是用户被骚扰（违背立此限额的目的），少放一条只是这条消息走站内。
 * 因此「已达上限」与「Redis 不可用」都必须落在「不放行」一侧，任何一处写反
 * 都不会有编译错误，只会让限额在线上静默失效。</p>
 */
class PushQuotaGateTest {

    /** 测试用自然日（固定值，避开真实时钟）。 */
    private static final LocalDate TODAY = LocalDate.of(2026, 10, 12);

    /** mock 的 Redis 模板。 */
    private StringRedisTemplate redisTemplate;

    /** mock 的字符串 value 操作。 */
    @SuppressWarnings("unchecked")
    private ValueOperations<String, String> valueOps;

    /** 被测配额闸。 */
    private PushQuotaGate quotaGate;

    /**
     * 每测前置：装配 mock Redis 与被测配额闸。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOps = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOps);
        quotaGate = new PushQuotaGate(redisTemplate);
    }

    /**
     * 未达上限：返回 true，且首次计数（INCR 得 1）时设置 TTL。
     *
     * @return void
     */
    @Test
    void tryConsumeAllowsAndSetsTtlOnFirstCount() {
        when(valueOps.get(anyString())).thenReturn(null);
        when(valueOps.increment(anyString())).thenReturn(1L);

        assertThat(quotaGate.tryConsume(1L, TODAY)).isTrue();

        verify(valueOps).increment(RateLimitKeys.pushQuotaUidDay(1L, TODAY));
        verify(redisTemplate).expire(anyString(), any(Duration.class));
    }

    /**
     * 未达上限但非首次：返回 true，且不重复设 TTL（TTL 只应在计数为 1 时设一次）。
     *
     * @return void
     */
    @Test
    void tryConsumeDoesNotResetTtlOnLaterCounts() {
        when(valueOps.get(anyString())).thenReturn(String.valueOf(NfrPush.DAILY_LIMIT - 1));
        when(valueOps.increment(anyString())).thenReturn((long) NfrPush.DAILY_LIMIT);

        assertThat(quotaGate.tryConsume(1L, TODAY)).isTrue();

        verify(redisTemplate, never()).expire(anyString(), any(Duration.class));
    }

    /**
     * 已达上限：返回 false，且**不再计数**（超限条目不应被计入，否则「先查后增」退化为「先增后判」）。
     *
     * @return void
     */
    @Test
    void tryConsumeRejectsWhenLimitReached() {
        when(valueOps.get(anyString())).thenReturn(String.valueOf(NfrPush.DAILY_LIMIT));

        assertThat(quotaGate.tryConsume(1L, TODAY)).isFalse();

        verify(valueOps, never()).increment(anyString());
    }

    /**
     * Redis 不可用：保守拒发（false），与 {@code DetailQuotaGate} 的「失败放行」刻意相反。
     *
     * @return void
     */
    @Test
    void tryConsumeRejectsWhenRedisUnavailable() {
        when(valueOps.get(anyString())).thenThrow(new IllegalStateException("redis down"));

        assertThat(quotaGate.tryConsume(1L, TODAY)).isFalse();
    }

    /**
     * 脏数据（非数字）：归一为 0 后放行，不让畸形值把用户永久挡在配额之外。
     *
     * @return void
     */
    @Test
    void tryConsumeTreatsDirtyCountAsZero() {
        when(valueOps.get(anyString())).thenReturn("oops");
        when(valueOps.increment(anyString())).thenReturn(1L);

        assertThat(quotaGate.tryConsume(1L, TODAY)).isTrue();
    }
}
