package com.s2s.server.ai;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import java.time.Duration;
import java.time.LocalDate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * AI 解析配额闸（B2-4；PRD §5.8/§5.9）。
 *
 * <p>职责：承载「今日 AI 解析次数」的读取、上限判定与扣减。与 {@code post.DetailQuotaGate}
 * 同族（配额闸而非限频轨），差异在超限码为 {@code 42901}（{@code needRetryAfter=true}，
 * HTTP 429）——故判定走 {@link BizException#ofRetryAfter}（携 {@code Retry-After} 剩余秒），
 * 且<b>必须用 {@code ofRetryAfter}</b>（{@code BizException.of} 会拒绝该码）。</p>
 *
 * <p><b>扣减点</b>：仅 {@code POST /posts}（带 {@code ai_assisted=true}）调用
 * {@link #increment}；解析端点（{@code POST /ai/publish/parse}）只调 {@link #ensureAvailable}
 * 只读判定，不扣减（PRD §5.9「仅确认发布才计 1 次」）。</p>
 *
 * <p><b>并发与丢失取舍</b>（详设 §3.4 纪律 3）：配额是防滥用而非账务，「GET 后 INCR」非原子，
 * 极端并发下可能多放行 1 次，对目标不敏感，故不引入 Lua 脚本。Redis 写失败放行
 * （不阻塞 P0 闭环），记 WARN。键拼装收口于 {@link RateLimitKeys#aiQuotaUidDay}。</p>
 */
@Component
public class AiQuotaGate {

    /** 日志（独立命名，与既有 QuotaGate 同考量）。 */
    private static final Logger log = LoggerFactory.getLogger(AiQuotaGate.class);

    /** Redis 字符串模板（配额计数读写）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 构造 AI 配额闸。
     *
     * @param redisTemplate Redis 字符串模板（计数读写）
     */
    public AiQuotaGate(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 读当前配额计数（键不存在或脏数据归一为 0）。
     *
     * @param userId 用户 ID（非 null，由调用方保证）
     * @param today  当前自然日（Asia/Shanghai，由调用方注入便于测试）
     * @return int 今日已用次数；键不存在/脏数据返回 0（不抛异常）
     */
    public int used(Long userId, LocalDate today) {
        return (int) readCount(RateLimitKeys.aiQuotaUidDay(userId, today));
    }

    /**
     * 判定配额是否可用：已达上限抛 {@code 42901}，否则放行（<b>不计数</b>）。
     *
     * @param userId 用户 ID
     * @param limit  今日上限（由 {@link AiQuotaService#resolveLimit} 计算）
     * @param today  当前自然日
     * @throws BizException 已达上限 → {@code 42901}（携 {@code Retry-After} 到次日零点剩余秒）
     */
    public void ensureAvailable(Long userId, int limit, LocalDate today) {
        if (readCount(RateLimitKeys.aiQuotaUidDay(userId, today)) >= limit) {
            throw BizException.ofRetryAfter(
                    ErrorCode.AI_QUOTA_EXCEEDED, RateLimitKeys.secondsUntilEndOfDay(today));
        }
    }

    /**
     * 扣减 1 次配额（发布成功时调用），并维护自然日 TTL。
     *
     * @param userId 用户 ID
     * @param today  当前自然日
     */
    public void increment(Long userId, LocalDate today) {
        String key = RateLimitKeys.aiQuotaUidDay(userId, today);
        try {
            Long next = redisTemplate.opsForValue().increment(key);
            if (next != null && next == 1L) {
                // 首次计数设 TTL：到次日零点 + 2h 缓冲（KTD6，与 §3.4 :1d 轨同口径）
                long ttl = RateLimitKeys.secondsUntilEndOfDay(today)
                        + RateLimitThresholds.NATURAL_DAY_TTL_BUFFER_SECONDS;
                redisTemplate.expire(key, Duration.ofSeconds(ttl));
            }
        } catch (Exception exception) {
            // Redis 写失败放行（配额防滥用非账务，详设 §3.4 纪律 3）；键无敏感维度，按 maskKey 保守脱敏
            log.warn("AiQuotaGate Redis 计数失败，跳过键 {}——写失败放行，详设 §3.4 纪律 3",
                    RateLimitKeys.maskKey(key), exception);
        }
    }

    /**
     * 读原始计数（键不存在或脏数据归一为 0）。
     *
     * @param key 配额计数键
     * @return long 当前计数；键不存在或非数字返回 0（不抛异常）
     */
    private long readCount(String key) {
        String value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return 0;
        }
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException exception) {
            // 本键只由本类写入数字，脏数据即缺陷；归一为 0 放行（配额不阻塞 P0 闭环）
            log.warn("AiQuotaGate 配额键 {} 计数非数字，归一为 0: {}", key, value);
            return 0;
        }
    }
}
