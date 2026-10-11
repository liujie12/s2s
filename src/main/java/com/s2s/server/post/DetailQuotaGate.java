package com.s2s.server.post;

import com.s2s.server.common.constants.NfrCert;
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
 * 未实名详情额度闸（[149]；详设 §5.3.4 回填口径）。
 *
 * <p>职责：承载 {@code GET /posts/{id}} 的「已登录未实名每日 5 条详情」额度判定——当前计数
 * 已达 {@link NfrCert#DETAIL_QUOTA_LIMIT_PER_DAY} 时抛 {@code 40301}，否则计数 +1 放行。</p>
 *
 * <p><b>为什么不复用 {@code RateLimiter.incrementAndCheck}</b>（与 §3.4 限频轨的边界）：
 * <ol>
 *   <li>超限码 {@code 40301} 是 {@code needRetryAfter=false}（HTTP 403，引导实名），而
 *       {@code RateLimiter} 超限统一走 {@code ofRetryAfter}（强制 needRetryAfter 码），语义不兼容；</li>
 *   <li>额度耗尽语义是「引导实名」而非「限频等待」，不写 {@code Retry-After} 头；</li>
 *   <li>额度语义是「先查后增」——第 6 条拒绝且<b>不计入</b>，而 {@code RateLimiter}
 *       是「先增后判」，第 6 条会被计进计数再拒绝。</li>
 * </ol>
 * 键拼装仍收口于 {@link RateLimitKeys#detailQuotaUidDay}（守「键拼装唯一处」，编码规范 §1.2）。</p>
 *
 * <p><b>并发与丢失取舍</b>（详设 §3.4 纪律 3「限频计数键允许丢失，防滥用非账务」）：
 * 额度是防爬而非账务，「GET 后 INCR」非原子，极端并发下可能多放行 1 条——对「每日 5 条
 * 详情」的防滥用目标不敏感，故不引入 Lua 原子脚本（避免在 {@code RateLimiter} 之外复刻
 * 第二份计数脚本）。Redis 写失败放行（额度不阻塞 P0 闭环），记 WARN。</p>
 */
@Component
public class DetailQuotaGate {

    /** 日志（独立命名，与 {@code RateLimiter} 同考量）。 */
    private static final Logger log = LoggerFactory.getLogger(DetailQuotaGate.class);

    /** Redis 字符串模板（额度计数读写）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 构造额度闸。
     *
     * @param redisTemplate Redis 字符串模板（计数读写）
     */
    public DetailQuotaGate(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 校验并扣减未实名详情额度：未达上限则计数 +1 放行，已达上限抛 {@code 40301}。
     *
     * @param userId 已登录访问者 ID（非 null，由调用方保证）
     * @param today  当前自然日（Asia/Shanghai，由调用方注入便于测试）
     * @throws BizException 已达每日额度上限 → {@code 40301}
     */
    public void checkAndIncrement(Long userId, LocalDate today) {
        String key = RateLimitKeys.detailQuotaUidDay(userId, today);
        long current = readCount(key);
        if (current >= NfrCert.DETAIL_QUOTA_LIMIT_PER_DAY) {
            throw BizException.of(ErrorCode.DETAIL_QUOTA_USED);
        }
        try {
            Long next = redisTemplate.opsForValue().increment(key);
            if (next != null && next == 1L) {
                // 首次计数设 TTL：到次日零点 + 2h 缓冲（KTD6，与 §3.4 :1d 轨同口径）
                long ttl = RateLimitKeys.secondsUntilEndOfDay(today)
                        + RateLimitThresholds.NATURAL_DAY_TTL_BUFFER_SECONDS;
                redisTemplate.expire(key, Duration.ofSeconds(ttl));
            }
        } catch (Exception exception) {
            // Redis 写失败放行（额度防滥用非账务，详设 §3.4 纪律 3）——键无敏感维度（仅 userId），
            // 无需 maskKey 脱敏（编码规范 §4.11 脱敏针对的是键中可能出现的手机号段）。
            log.warn("DetailQuotaGate Redis 计数失败，跳过键 {}——写失败放行，详设 §3.4 纪律 3",
                    key, exception);
        }
    }

    /**
     * 读当前额度计数（键不存在或脏数据归一为 0）。
     *
     * @param key 额度计数键
     * @return long 当前计数；键不存在返回 0，脏数据（非数字）返回 0（不抛异常）
     */
    private long readCount(String key) {
        String value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return 0;
        }
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException exception) {
            // 本键只由本类写入数字，脏数据即缺陷；归一为 0 放行（额度不阻塞 P0 闭环）
            log.warn("DetailQuotaGate 额度键 {} 计数非数字，归一为 0: {}", key, value);
            return 0;
        }
    }
}
