package com.s2s.server.contact;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.common.ratelimit.RateLimiter;
import java.time.Duration;
import java.time.LocalDate;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.ValueOperations;

/**
 * {@link ContactRateGuard} 测试（[128]；详设 §5.5.1 第 [2]–[4] 步）。
 *
 * <p>覆盖四条：冻结命中 {@code 42903} 且带剩余秒数、Redis 读失败按纪律 3 放行、
 * 突发超限时写冻结标记（非超限不写）、账号维剩余量的换算与读失败降级。</p>
 */
class ContactRateGuardTest {

    /** 测试用用户 ID。 */
    private static final Long USER_ID = 42L;

    /**
     * 当前自然日：<b>不硬编码日期</b>（[129] 实测踩坑）。
     *
     * <p>本类断言了「到次日零点的剩余秒数」（由墙上时钟算出），硬编码日期会在该日零点后
     * 变成过去日 → 剩余秒数转负、用例必红（2026-09-28 硬编码日期于 09-29 零点失效）。
     * 取 {@link RateLimitKeys#today()} 而非 {@code LocalDate.now(...)}：时区口径的唯一来源
     * 是 {@code RateLimitThresholds#ZONE}，测试不另写一份时区。</p>
     */
    private static final LocalDate TODAY = RateLimitKeys.today();

    private RateLimiter rateLimiter;
    private StringRedisTemplate redisTemplate;
    private ValueOperations<String, String> valueOperations;
    private ContactRateGuard guard;

    /**
     * 装配被测对象与两个 mock（RateLimiter 计数、Redis 冻结键与剩余量）。
     *
     * @return void；无断言
     */
    @BeforeEach
    void setUp() {
        rateLimiter = mock(RateLimiter.class);
        redisTemplate = mock(StringRedisTemplate.class);
        @SuppressWarnings("unchecked")
        ValueOperations<String, String> ops = mock(ValueOperations.class);
        valueOperations = ops;
        when(redisTemplate.opsForValue()).thenReturn(valueOperations);
        guard = new ContactRateGuard(rateLimiter, redisTemplate);
    }

    /**
     * 冻结标记存在 → {@code 42903}，且 {@code Retry-After} 为「到次日零点」的剩余秒数
     * （自然日语义，跨零点自动解除）。
     *
     * <p>断言用「与 {@link RateLimitKeys#secondsUntilEndOfDay(LocalDate)} 相等 + 非负」而非
     * 「正数」：该值由墙上时钟算出，跨零点前最后一秒内整除后可为 0，写死 {@code isPositive}
     * 会留下一个每日必现的窄窗抖动。</p>
     *
     * @return void；断言失败即冻结判定或剩余秒数口径错误
     */
    @Test
    void frozenUserIsRejectedWith42903AndRetryAfter() {
        when(redisTemplate.hasKey(RateLimitKeys.contactFreezeDay(USER_ID, TODAY))).thenReturn(true);

        assertThatThrownBy(() -> guard.assertNotFrozen(USER_ID, TODAY))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException biz = (BizException) thrown;
                    assertThat(biz.getErrorCode()).isEqualTo(ErrorCode.CIRCUIT_BROKEN);
                    assertThat(biz.getRetryAfterSeconds())
                            .isNotNull()
                            .isNotNegative()
                            .isEqualTo(RateLimitKeys.secondsUntilEndOfDay(TODAY));
                });
    }

    /**
     * Redis 读冻结标记失败 → <b>放行</b>（详设 §3.4 纪律 3：防滥用控制不因 Redis
     * 故障升级为全站不可用），且不抛异常。
     *
     * @return void；断言失败即把「可用性红线」写成了「安全红线」的 fail-closed
     */
    @Test
    void freezeReadFailureFailsOpen() {
        when(redisTemplate.hasKey(any())).thenThrow(new RuntimeException("redis down"));

        assertThatCode(() -> guard.assertNotFrozen(USER_ID, TODAY)).doesNotThrowAnyException();
    }

    /**
     * 突发计数超限（{@link RateLimiter} 抛 {@code 42903}）→ 必须落当日冻结标记，
     * 否则「1min ≥10 次 → 当日冻结」会退化成「每分钟最多 10 次」。
     *
     * @return void；断言失败即熔断退化为窗口内限流
     */
    @Test
    void burstOverflowMarksDailyFreeze() {
        when(rateLimiter.incrementAndCheck(anyList()))
                .thenThrow(BizException.ofRetryAfter(ErrorCode.CIRCUIT_BROKEN, 45));

        assertThatThrownBy(() -> guard.checkBurst(dimensions()))
                .isInstanceOf(BizException.class);

        verify(valueOperations).set(RateLimitKeys.contactFreezeDay(USER_ID, TODAY), "1",
                Duration.ofSeconds(RateLimitEntries.naturalDayKeyTtlSeconds(TODAY)));
    }

    /**
     * 突发计数未超限 → 不写冻结标记（误写会把正常用户整天关在门外）。
     *
     * @return void；断言失败即正常请求被错误冻结
     */
    @Test
    void normalBurstDoesNotMarkFreeze() {
        guard.checkBurst(dimensions());

        verify(valueOperations, never()).set(any(), any(), any(Duration.class));
    }

    /**
     * 剩余次数 = 阈值 − 已用（账号维），且读数与限频键是同一个键
     * （键由唯一拼装处 {@link RateLimitKeys} 提供）。
     *
     * @return void；断言失败即 remaining_today 与账号维计数脱钩
     */
    @Test
    void remainingTodayIsThresholdMinusUsed() {
        when(valueOperations.get(RateLimitKeys.contactUidDay(USER_ID, TODAY))).thenReturn("3");

        assertThat(guard.remainingToday(USER_ID, TODAY))
                .isEqualTo(RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY - 3);
    }

    /**
     * 已用超过阈值（理论上不该发生，如阈值被连夜调小）→ 剩余钳到 0，不给负数。
     *
     * @return void；断言失败即可能出现负剩余，被客户端当成「欠了几次」
     */
    @Test
    void remainingTodayNeverNegative() {
        when(valueOperations.get(RateLimitKeys.contactUidDay(USER_ID, TODAY)))
                .thenReturn(String.valueOf(RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY + 5));

        assertThat(guard.remainingToday(USER_ID, TODAY)).isZero();
    }

    /**
     * Redis 读失败 → 返回阈值本身（不返回 0）：该字段非承诺值（契约明令
     * 「以实际请求结果为准」），而返回 0 会让界面用错误信息否定自己。
     *
     * @return void；断言失败即读失败时向用户谎报「已用完」
     */
    @Test
    void remainingReadFailureReturnsThresholdNotZero() {
        when(valueOperations.get(any())).thenThrow(new RuntimeException("redis down"));

        assertThat(guard.remainingToday(USER_ID, TODAY))
                .isEqualTo(RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY);
    }

    /**
     * 构造账号维测试维度（设备头与 IP 用固定值）。
     *
     * @return {@link RateLimitEntries.RateLimitDimensions} 五元组
     */
    private RateLimitEntries.RateLimitDimensions dimensions() {
        return RateLimitEntries.RateLimitDimensions.of(USER_ID, null, "127.0.0.1", TODAY);
    }
}
