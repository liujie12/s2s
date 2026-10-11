package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.NfrCert;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.LocalDate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link DetailQuotaGate} 未实名详情额度闸测试（[149]；详设 §5.3.4 回填口径）。
 *
 * <p>覆盖：计数未达上限放行并计数、计数达上限抛 40301 且不计数、键不存在视为零计数。</p>
 */
class DetailQuotaGateTest {

    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOperations;
    private DetailQuotaGate gate;

    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOperations = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);
        gate = new DetailQuotaGate(redisTemplate);
    }

    @Test
    void 计数未达上限放行并计数() {
        when(valueOperations.get(anyString())).thenReturn("4");
        when(valueOperations.increment(anyString())).thenReturn(5L);
        gate.checkAndIncrement(1L, LocalDate.of(2026, 10, 11));
        verify(valueOperations).increment(anyString());
    }

    @Test
    void 计数达上限抛40301且不计数() {
        when(valueOperations.get(anyString()))
                .thenReturn(String.valueOf(NfrCert.DETAIL_QUOTA_LIMIT_PER_DAY));
        assertThatThrownBy(() -> gate.checkAndIncrement(1L, LocalDate.of(2026, 10, 11)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.DETAIL_QUOTA_USED);
        verify(valueOperations, never()).increment(anyString());
    }

    @Test
    void 键不存在视为零计数放行() {
        when(valueOperations.get(anyString())).thenReturn(null);
        when(valueOperations.increment(anyString())).thenReturn(1L);
        gate.checkAndIncrement(1L, LocalDate.of(2026, 10, 11));
        verify(valueOperations).increment(anyString());
    }
}
