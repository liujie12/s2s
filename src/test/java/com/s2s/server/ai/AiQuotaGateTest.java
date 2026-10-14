package com.s2s.server.ai;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link AiQuotaGate} AI 配额闸测试（B2-4；PRD §5.8/§5.9）。
 *
 * <p>覆盖：未达上限放行且不计数、达上限抛 42901（携 Retry-After 正数）、首次计数设 TTL、
 * Redis 异常放行。</p>
 */
class AiQuotaGateTest {

    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOperations;
    private AiQuotaGate gate;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOperations = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);
        gate = new AiQuotaGate(redisTemplate);
    }

    @Test
    void 未达上限放行不计数() {
        when(valueOperations.get(anyString())).thenReturn("1");
        gate.ensureAvailable(1L, 3, RateLimitKeys.today());
        verify(valueOperations, never()).increment(anyString());
    }

    @Test
    void 达上限抛42901且携RetryAfter正数() {
        when(valueOperations.get(anyString())).thenReturn("3");
        assertThatThrownBy(() -> gate.ensureAvailable(1L, 3, RateLimitKeys.today()))
                .isInstanceOf(BizException.class)
                .satisfies(e -> {
                    BizException be = (BizException) e;
                    assertThat(be.getErrorCode()).isEqualTo(ErrorCode.AI_QUOTA_EXCEEDED);
                    assertThat(be.getRetryAfterSeconds()).isNotNull().isPositive();
                });
    }

    @Test
    void 首次计数设TTL() {
        when(valueOperations.increment(anyString())).thenReturn(1L);
        gate.increment(1L, RateLimitKeys.today());
        verify(redisTemplate).expire(anyString(), any());
    }

    @Test
    void Redis异常放行不抛出() {
        when(valueOperations.increment(anyString())).thenThrow(new RuntimeException("redis down"));
        gate.increment(1L, RateLimitKeys.today());
        // 无异常即通过（写失败放行）
    }
}
