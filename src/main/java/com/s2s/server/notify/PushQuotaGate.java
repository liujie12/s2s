package com.s2s.server.notify;

import com.s2s.server.common.constants.NfrPush;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import java.time.Duration;
import java.time.LocalDate;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * 推送每日配额闸（[B2-2]；PRD §6.14 / §12.3）。
 *
 * <p>职责：维护「单用户每日接收推送 ≤ {@link NfrPush#DAILY_LIMIT} 条」——未达上限则
 * 记一次并返回 {@code true}，已达上限返回 {@code false}。**不抛任何错误码**：
 * PRD §12.3 明写超限「服务端静默转站内通知，客户端无感」，超限不是错误而是降级。
 * （{@code 42904} 保留给显式受限场景，如运营定向邀请被频控。）</p>
 *
 * <p>键拼装收口 {@link RateLimitKeys#pushQuotaUidDay}，计数范式镜像
 * {@code post.DetailQuotaGate}（先查后增、自然日窗口 + 26h TTL）。</p>
 *
 * <p><b>Redis 不可用时拒发（与 {@code DetailQuotaGate} 的「放行」刻意相反）</b>：
 * 详情额度的失败放行代价是「多看几条详情」，而推送配额的失败放行代价是
 * **用户被超发骚扰**——正好违背 §6.14 立这条限额的目的。且失败拒发不会丢信息：
 * 站内通知由调用方先写，用户仍能在通知中心看到（§6.14「站内通知中心兜底」）。
 * 故此处选择失败即拒发并记 WARN。</p>
 */
@Component
public class PushQuotaGate {

    /** 日志（独立命名，与 {@code DetailQuotaGate} 同考量）。 */
    private static final Logger log = LoggerFactory.getLogger(PushQuotaGate.class);

    /** Redis 字符串模板（配额计数读写）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 构造配额闸。
     *
     * @param redisTemplate Redis 字符串模板（计数读写）
     */
    public PushQuotaGate(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 尝试占用一份当日推送配额。
     *
     * @param userId 接收者 user ID（非 null，由调用方保证）
     * @param today  当前自然日（Asia/Shanghai，由调用方注入便于测试）
     * @return boolean {@code true} 未达上限且已计数（允许下发）；
     *         {@code false} 已达上限，或 Redis 不可用（保守拒发，见类注释）
     */
    public boolean tryConsume(Long userId, LocalDate today) {
        String key = RateLimitKeys.pushQuotaUidDay(userId, today);
        try {
            long current = readCount(key);
            if (current >= NfrPush.DAILY_LIMIT) {
                return false;
            }
            Long next = redisTemplate.opsForValue().increment(key);
            if (next != null && next == 1L) {
                // 首次计数设 TTL：到次日零点 + 2h 缓冲（KTD6，与 §3.4 :1d 轨同口径）
                long ttl = RateLimitKeys.secondsUntilEndOfDay(today)
                        + RateLimitThresholds.NATURAL_DAY_TTL_BUFFER_SECONDS;
                redisTemplate.expire(key, Duration.ofSeconds(ttl));
            }
            return true;
        } catch (Exception exception) {
            // 计数器不可用即保守拒发：键无敏感维度（仅 userId），无需 maskKey 脱敏
            // （编码规范 §4.11 脱敏针对的是键中可能出现的手机号段）。
            log.warn("PushQuotaGate Redis 不可用，{} 日推送拒发（保守；站内兜底仍在），键 {}",
                    today, key, exception);
            return false;
        }
    }

    /**
     * 读取当前计数（键不存在或脏数据归一为 0）。
     *
     * @param key 配额计数键
     * @return long 当前计数；键不存在或非数字返回 0
     */
    private long readCount(String key) {
        String value = redisTemplate.opsForValue().get(key);
        if (value == null) {
            return 0;
        }
        try {
            return Long.parseLong(value);
        } catch (NumberFormatException exception) {
            log.warn("PushQuotaGate 配额键 {} 计数非数字，归一为 0: {}", key, value);
            return 0;
        }
    }
}
