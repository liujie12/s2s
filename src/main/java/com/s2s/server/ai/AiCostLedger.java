package com.s2s.server.ai;

import com.s2s.server.common.constants.NfrAi;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import java.time.Duration;
import java.time.LocalDate;
import java.time.YearMonth;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * AI 调用费用台账（B2-4 费用上限；2026-10-17 用户裁定）。
 *
 * <p><b>口径</b>：单用户「每自然日 &lt; 1 元、每自然月 &lt; 10 元」，阈值单源
 * {@link NfrAi#COST_DAILY_LIMIT_MICROYUAN} / {@link NfrAi#COST_MONTHLY_LIMIT_MICROYUAN}
 * （微元，1 元 = 1,000,000 微元）。</p>
 *
 * <p><b>与 {@link AiQuotaGate} 的分工</b>：配额闸计「确认发布次数」（业务配额，
 * PRD §5.8 二维表）；本台账计「实际 token 折算费用」（成本安全阀）。两者并行：
 * 解析前都要过闸，任一道超限均回 {@code 42901}（复用既有码，不新增）。</p>
 *
 * <p><b>记账点</b>：每次真实上游调用（含模式② 的独立转写）由 {@code QwenAiProvider}
 * 按响应 {@code usage} 折算后调用 {@link #record}；dry-run 不调用上游、不记账。</p>
 *
 * <p><b>失败策略</b>：Redis 读写失败一律放行（记 WARN）——与配额闸一致，避免
 * 缓存故障阻断 P0 发布闭环；费用风险仍由上游限流与业务配额兜底（详设 §3.4 纪律 3）。</p>
 */
@Component
public class AiCostLedger {

    /** 日志（独立命名，与 AiQuotaGate 同考量）。 */
    private static final Logger log = LoggerFactory.getLogger(AiCostLedger.class);

    /** Redis 字符串模板（微元累计读写）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 构造 AI 费用台账。
     *
     * @param redisTemplate Redis 字符串模板（累计读写）
     */
    public AiCostLedger(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 校验费用预算：日累计或月累计已达上限时抛 {@code 42901}。
     *
     * <p>先判日、再判月：两者可能同时超限，日窗口更早重置，优先提示更短的等待时间。</p>
     *
     * @param userId 用户 ID（非 null，由调用方保证）
     * @throws BizException 费用超限 → {@code 42901}（携 {@code Retry-After}：
     *         日超限到次日零点、月超限到下月 1 日零点）
     */
    public void ensureWithinBudget(Long userId) {
        LocalDate today = RateLimitKeys.today();
        long dayUsed = read(RateLimitKeys.aiCostUidDay(userId, today));
        if (dayUsed >= NfrAi.COST_DAILY_LIMIT_MICROYUAN) {
            throw BizException.ofRetryAfter(
                    ErrorCode.AI_QUOTA_EXCEEDED, RateLimitKeys.secondsUntilEndOfDay(today));
        }
        YearMonth month = YearMonth.from(today);
        long monthUsed = read(RateLimitKeys.aiCostUidMonth(userId, month));
        if (monthUsed >= NfrAi.COST_MONTHLY_LIMIT_MICROYUAN) {
            throw BizException.ofRetryAfter(
                    ErrorCode.AI_QUOTA_EXCEEDED,
                    RateLimitKeys.secondsUntilStartOfNextMonth(month));
        }
    }

    /**
     * 记一笔调用费用（微元），同时累加日、月两个窗口。
     *
     * @param userId        用户 ID（非 null，由调用方保证）
     * @param costMicroYuan 本次调用折算费用（微元；≤0 直接忽略）
     */
    public void record(Long userId, long costMicroYuan) {
        if (costMicroYuan <= 0L) {
            return;
        }
        LocalDate today = RateLimitKeys.today();
        DayWindow day = new DayWindow(RateLimitKeys.aiCostUidDay(userId, today),
                RateLimitKeys.secondsUntilEndOfDay(today)
                        + RateLimitThresholds.NATURAL_DAY_TTL_BUFFER_SECONDS);
        YearMonth month = YearMonth.from(today);
        DayWindow monthWindow = new DayWindow(RateLimitKeys.aiCostUidMonth(userId, month),
                RateLimitKeys.secondsUntilStartOfNextMonth(month)
                        + RateLimitThresholds.NATURAL_DAY_TTL_BUFFER_SECONDS);
        increment(day, costMicroYuan);
        increment(monthWindow, costMicroYuan);
    }

    /**
     * 读今日已计费用（微元；键不存在或脏数据归一为 0）。
     *
     * @param userId 用户 ID
     * @return long 今日累计微元
     */
    public long usedToday(Long userId) {
        return read(RateLimitKeys.aiCostUidDay(userId, RateLimitKeys.today()));
    }

    /**
     * 读本月已计费用（微元；键不存在或脏数据归一为 0）。
     *
     * @param userId 用户 ID
     * @return long 本月累计微元
     */
    public long usedThisMonth(Long userId) {
        return read(RateLimitKeys.aiCostUidMonth(userId, YearMonth.from(RateLimitKeys.today())));
    }

    /**
     * 对一个窗口键累加费用，首次写入时设置窗口 TTL。
     *
     * @param window 窗口键与 TTL（秒）
     * @param delta  本次费用（微元，&gt;0）
     */
    private void increment(DayWindow window, long delta) {
        try {
            Long next = redisTemplate.opsForValue().increment(window.key(), delta);
            if (next != null && next == delta) {
                // 首次写入（返回值恰为本次增量）⇒ 设置窗口 TTL，防键永久残留
                redisTemplate.expire(window.key(), Duration.ofSeconds(window.ttlSeconds()));
            }
        } catch (Exception exception) {
            // 写失败放行（费用台账失败不阻断 P0 发布闭环，与 AiQuotaGate 同口径）
            log.warn("AiCostLedger Redis 写失败，跳过键 {}——放行，详设 §3.4 纪律 3",
                    RateLimitKeys.maskKey(window.key()), exception);
        }
    }

    /**
     * 读窗口累计（键不存在或脏数据归一为 0）。
     *
     * @param key 窗口键
     * @return long 累计微元；键不存在/非数字返回 0（不抛异常）
     */
    private long read(String key) {
        try {
            String value = redisTemplate.opsForValue().get(key);
            if (value == null) {
                return 0L;
            }
            return Long.parseLong(value);
        } catch (NumberFormatException exception) {
            // 本键只由本类写入数字，脏数据即缺陷；归一为 0 放行
            log.warn("AiCostLedger 费用键 {} 计数非数字，归一为 0", key);
            return 0L;
        } catch (Exception exception) {
            // 读失败放行（同写失败策略），避免缓存故障阻断 P0 闭环
            log.warn("AiCostLedger Redis 读失败，跳过键 {}——放行",
                    RateLimitKeys.maskKey(key), exception);
            return 0L;
        }
    }

    /**
     * 窗口键与 TTL 的轻量载体。
     *
     * @param key        窗口键
     * @param ttlSeconds TTL（秒）
     */
    private record DayWindow(String key, long ttlSeconds) {
    }
}
