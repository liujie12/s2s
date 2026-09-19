package com.s2s.server.common.ratelimit;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.util.ArrayList;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.data.redis.core.script.DefaultRedisScript;
import org.springframework.data.redis.core.script.RedisScript;
import org.springframework.stereotype.Component;

/**
 * 限频计数<b>唯一执行处</b>（[122] U4；详设 §3.4；编码规范 §1.2 唯一实现处清单）。
 *
 * <p>核心能力：对一组限频键做原子 INCR + EXPIRE，返回是否超限与剩余秒数；
 * 多键同时超限时取剩余秒数的最大值（用户等待最久的那个作为 Retry-After——
 * 因为只要有一个维度还在限频，请求就不能通过，Retry-After 要覆盖所有维度）。
 *
 * <p><b>Lua 原子脚本</b>：INCR 和 EXPIRE 用一段 Lua 脚本原子执行——
 * 首次 INCR（计数为 1）时同时设 TTL，防键永不过期（如果只用 INCR 后再 EXPIRE，
 * 两条命令之间进程崩溃会导致键永久存在，计数永不归零）。
 * Lua 脚本返回当前计数（INCR 后的值），调用方与阈值比较判断是否超限。
 *
 * <p><b>Redis 写失败的处理（详设 §3.4 纪律 3）</b>：
 * 限频计数是「防滥用」非「账务」，Redis 写失败（连接超时、脚本执行异常等）
 * 记 WARN 日志后<b>放行</b>——宁可让少量请求漏过，也不能因 Redis 故障让全站不可用。
 * 这与鉴权黑名单的 KTD7（读失败 50001）形成对比：黑名单读失败是安全红线，
 * 限频写失败是可用性红线，两条线走向不同，不可混淆。
 *
 * <p><b>剩余秒数计算</b>：
 * <ul>
 *   <li>滚动窗口（:1m/:1h）：剩余秒 = TTL 剩余秒，由 Redis {@code TTL} 命令获取；
 *       Lua 脚本同时返回计数与 TTL，省一次 RTT。</li>
 *   <li>自然日窗口（:1d）：剩余秒 = 到次日零点的秒数（Asia/Shanghai 时区），
 *       不依赖 Redis TTL（因为键的 TTL 是 26h 不是到零点的时长）。</li>
 * </ul>
 * 为简化实现（Batch1 性能足够），本类统一从 Lua 返回 TTL，自然日键的 TTL 设为
 * 到零点的秒数 + 2h 缓冲（由调用方传入精确 TTL）——Lua 返回的 TTL 就是剩余秒数，
 * 调用方不用再做时区计算。
 */
@Component
public class RateLimiter {

    /** 日志（独立命名，限频计数 WARN 不被 com.s2s: WARN 压制——同访问日志的考量）。 */
    private static final Logger log = LoggerFactory.getLogger(RateLimiter.class);

    /** Redis 字符串模板（注入构造器，便于测试替换）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * Lua 脚本：原子 INCR + EXPIRE，返回 {当前计数, TTL 剩余秒} 数组。
     *
     * <p>KEYS[1] = 限频键；ARGV[1] = TTL 秒数。
     * <ol>
     *   <li>{@code local current = redis.call('INCR', KEYS[1])}</li>
     *   <li>{@code if current == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end}
     *       ——首次 INCR 时设 TTL，防键永不过期；后续 INCR 不重置 TTL（滚动窗口语义）。</li>
     *   <li>返回 {current, ttl} —— ttl 用 {@code TTL} 命令取当前剩余秒数。</li>
     * </ol>
     *
     * <p>返回类型：{@code List<Long>}（Lua 的 array → Java List，两个元素）。
     * 显式构造 {@code DefaultRedisScript<List<Long>>} 并 setResultType 以避免泛型推断失败。
     */
    @SuppressWarnings("unchecked")
    private static final RedisScript<List<Long>> INCR_EXPIRE_SCRIPT;

    static {
        DefaultRedisScript<List<Long>> script = new DefaultRedisScript<>();
        script.setScriptText(
                "local current = redis.call('INCR', KEYS[1])\n"
                        + "if current == 1 then\n"
                        + "  redis.call('EXPIRE', KEYS[1], ARGV[1])\n"
                        + "end\n"
                        + "local ttl = redis.call('TTL', KEYS[1])\n"
                        + "return {current, ttl}"
        );
        script.setResultType((Class<List<Long>>) (Class<?>) List.class);
        INCR_EXPIRE_SCRIPT = script;
    }

    /**
     * 构造限频计数器。
     *
     * @param redisTemplate Redis 字符串模板（计数写入与 TTL 查询）
     */
    public RateLimiter(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 对单个键执行一次计数并判断是否超限。
     * 单键版是多键版的退化（内部调多键版），提供给单轨接口使用。
     *
     * @param key           Redis 计数键
     * @param ttlSeconds    键的 TTL（秒）；滚动窗 = 窗口秒数，自然日窗 = 到次日零点 + 缓冲
     * @param limit         阈值（超限判断依据）
     * @param overflowCode  超限错误码（needRetryAfter 码，必须带剩余秒数）
     * @return long 剩余秒数；未超限时返回 -1（调用方忽略）
     * @throws BizException 超限时抛出，携带 {@code overflowCode} 与剩余秒数（经 ofRetryAfter）
     */
    public long incrementAndCheck(String key, long ttlSeconds, int limit, ErrorCode overflowCode) {
        List<RateLimitEntry> entries = new ArrayList<>();
        entries.add(new RateLimitEntry(key, ttlSeconds, limit, overflowCode));
        return incrementAndCheck(entries);
    }

    /**
     * 对多个键同时计数（多轨并发生效），任一超限即抛异常，多轨同时超限取
     * 剩余秒数最大值作为 Retry-After（用户等最久的那个，详设 §3.4 纪律 4）。
     *
     * <p>执行流程：
     * <ol>
     *   <li>逐键执行 Lua 原子 INCR+EXPIRE；</li>
     *   <li>Redis 异常 → 记 WARN + 跳过该键继续下一个（全部失败则全部放行）；</li>
     *   <li>全部执行完后，汇总超限的键，取 max(剩余秒数)；</li>
     *   <li>有超限 → 抛 {@code BizException.ofRetryAfter(maxCode, maxSeconds)}。</li>
     * </ol>
     *
     * <p><b>注意</b>：所有传入的 ErrorCode 都必须是 needRetryAfter=true 的码（40105 + 429xx），
     * 否则 ofRetryAfter 语义不成立。本方法不做二次校验，调用方（RateLimitInterceptor）
     * 从 RateLimitTrack 拿的码天然是 needRetryAfter=true，枚举绑定是守卫。
     *
     * @param entries 多轨道条目列表（键/TTL/阈值/超限码 四元组）
     * @return long 未超限时返回 -1；方法返回表示所有轨都通过
     * @throws BizException 任一轨超限时抛出，携带超限码与最大剩余秒数
     */
    public long incrementAndCheck(List<RateLimitEntry> entries) {
        long maxRetryAfter = -1;
        ErrorCode overflowCode = null;

        for (RateLimitEntry entry : entries) {
            try {
                List<Long> result = redisTemplate.execute(
                        INCR_EXPIRE_SCRIPT,
                        java.util.Collections.singletonList(entry.key()),
                        String.valueOf(entry.ttlSeconds())
                );
                if (result == null || result.size() < 2) {
                    // Lua 返回异常或空 —— 记 WARN，放行该轨（写失败放行）
                    log.warn("RateLimiter Lua 返回异常，跳过键 {}（写失败放行，详设 §3.4 纪律 3）", entry.key());
                    continue;
                }
                long current = result.get(0);
                long ttl = result.get(1);
                if (current > entry.limit()) {
                    // 超限：比较剩余秒数，取最大值
                    long retryAfter = Math.max(ttl, 1); // TTL 至少 1s（防 0/-1 异常值）
                    if (retryAfter > maxRetryAfter) {
                        maxRetryAfter = retryAfter;
                        overflowCode = entry.overflowCode();
                    }
                }
            } catch (Exception exception) {
                // Redis 连接失败 / 超时 / 脚本执行失败 —— 记 WARN，放行该轨
                log.warn("RateLimiter Redis 操作失败，跳过键 {}（{}）—— 写失败放行，详设 §3.4 纪律 3",
                        entry.key(), exception.getMessage());
            }
        }

        if (overflowCode != null) {
            throw BizException.ofRetryAfter(overflowCode, maxRetryAfter);
        }
        return -1;
    }

    /**
     * 单条限频计数条目（键 / TTL 秒 / 阈值 / 超限码 四元组）。
     *
     * <p>承载形态：record（Java 21）；仅在 {@link RateLimiter#incrementAndCheck(List)}
     * 调用方组装使用，是「一次多轨计数」的参数承载对象。</p>
     *
     * @param key          Redis 计数键
     * @param ttlSeconds   键首次创建时的 TTL（秒）
     * @param limit        计数阈值（> limit 即超限）
     * @param overflowCode 超限错误码（应为 needRetryAfter=true 的码）
     */
    public record RateLimitEntry(String key, long ttlSeconds, int limit, ErrorCode overflowCode) {
    }
}
