package com.s2s.server.ai;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.NfrAi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import java.time.LocalDate;
import java.time.YearMonth;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link AiCostLedger} 费用台账测试（B2-4；2026-10-17 裁定「每日 &lt;1 元、每月 &lt;10 元」）。
 *
 * <p>覆盖：未达上限放行、日/月分别超限抛 {@code 42901}（携正数 Retry-After）、
 * 记账同时写日/月两键并设 TTL、零费用不写、Redis 异常放行。</p>
 */
class AiCostLedgerTest {

    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOperations;
    private AiCostLedger ledger;

    /**
     * 每例新建 mock 模板（用例间零串扰）。
     */
    @BeforeEach
    @SuppressWarnings("unchecked")
    void setUp() {
        redisTemplate = mock(StringRedisTemplate.class);
        valueOperations = mock(ValueOperations.class);
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);
        ledger = new AiCostLedger(redisTemplate);
    }

    /**
     * 日、月累计都低于上限 ⇒ 放行，不抛异常。
     */
    @Test
    void 未达上限放行() {
        when(valueOperations.get(anyString())).thenReturn("0");
        ledger.ensureWithinBudget(1L);
    }

    /**
     * 日累计达到上限 ⇒ 42901，Retry-After 为正数。
     */
    @Test
    void 日累计达上限抛42901() {
        stubCosts(String.valueOf(NfrAi.COST_DAILY_LIMIT_MICROYUAN), "0");
        assertThatThrownBy(() -> ledger.ensureWithinBudget(1L))
                .isInstanceOf(BizException.class)
                .satisfies(e -> {
                    BizException be = (BizException) e;
                    assertThat(be.getErrorCode()).isEqualTo(ErrorCode.AI_QUOTA_EXCEEDED);
                    assertThat(be.getRetryAfterSeconds()).isNotNull().isPositive();
                });
    }

    /**
     * 日累计未超、月累计达上限 ⇒ 42901（Reset 到下月）。
     */
    @Test
    void 月累计达上限抛42901() {
        stubCosts("0", String.valueOf(NfrAi.COST_MONTHLY_LIMIT_MICROYUAN));
        assertThatThrownBy(() -> ledger.ensureWithinBudget(1L))
                .isInstanceOf(BizException.class)
                .satisfies(e -> assertThat(((BizException) e).getErrorCode())
                        .isEqualTo(ErrorCode.AI_QUOTA_EXCEEDED));
    }

    /**
     * 记账同时写日、月两键，首写设 TTL。
     */
    @Test
    void 记账写日月两键并设TTL() {
        when(valueOperations.increment(anyString(), anyLong())).thenReturn(500L);
        ledger.record(1L, 500L);
        verify(valueOperations, org.mockito.Mockito.times(2)).increment(anyString(), eq(500L));
        verify(redisTemplate, org.mockito.Mockito.times(2)).expire(anyString(), any());
    }

    /**
     * 费用 ≤0 ⇒ 不写 Redis。
     */
    @Test
    void 零费用不记账() {
        ledger.record(1L, 0L);
        verify(valueOperations, never()).increment(anyString(), anyLong());
    }

    /**
     * Redis 异常 ⇒ 放行（与配额闸同口径，不阻断发布闭环）。
     */
    @Test
    void Redis异常放行不抛出() {
        when(valueOperations.increment(anyString(), anyLong()))
                .thenThrow(new RuntimeException("redis down"));
        ledger.record(1L, 100L);
        // 无异常即通过（写失败放行）
    }

    /**
     * 按日键/月键分别打桩读取值。
     *
     * @param dayValue   日累计（微元，字符串）
     * @param monthValue 月累计（微元，字符串）
     */
    private void stubCosts(String dayValue, String monthValue) {
        LocalDate today = RateLimitKeys.today();
        YearMonth month = YearMonth.from(today);
        when(valueOperations.get(RateLimitKeys.aiCostUidDay(1L, today))).thenReturn(dayValue);
        when(valueOperations.get(RateLimitKeys.aiCostUidMonth(1L, month))).thenReturn(monthValue);
    }
}
