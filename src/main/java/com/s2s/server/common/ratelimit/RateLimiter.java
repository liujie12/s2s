package com.s2s.server.common.ratelimit;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.nio.charset.StandardCharsets;
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
 * <p><b>Lua 原子脚本（单值返回）</b>：INCR 和 EXPIRE 用一段 Lua 脚本原子执行——
 * 首次 INCR（计数为 1）时同时设 TTL，防键永不过期（如果只用 INCR 后再 EXPIRE，
 * 两条命令之间进程崩溃会导致键永久存在，计数永不归零）。脚本只返回当前计数
 * （不返回 TTL——Retry-After 由调用方按窗口语义精确计算，见 {@link RateLimitEntry#retryAfterSeconds}，
 * 避免把「键 TTL 缓冲」泄漏成「用户可见剩余秒」）。
 *
 * <p><b>返回值反序列化与可靠解包（[122] review P0 修复）</b>：本类注入
 * {@link StringRedisTemplate}，其 value 序列化器是 {@code StringRedisSerializer}——Lua 返回值
 * 会被反序列化为 {@code String}（或底层连接的 {@code byte[]}），<b>而非</b> {@code Long}。
 * 故脚本的 {@code resultType} 保持 {@code null}（不强制类型），消费侧经
 * {@link #toLong(Object)} 统一解包 {@code Number}/{@code String}/{@code byte[]} 三种形态，
 * 杜绝「泛型声明 {@code List<Long>} 但运行时是 {@code List<String>}」导致的
 * {@code ClassCastException}——该异常此前被 {@code catch (Exception)} 当作「写失败放行」吞掉，
 * 使全局限频静默失效（green-while-red：单测 mock 返回 {@code List<Long>} 掩盖了真实类型失配）。
 *
 * <p><b>Redis 写失败的处理（详设 §3.4 纪律 3）</b>：
 * 限频计数是「防滥用」非「账务」，Redis 写失败（连接超时、脚本执行异常等）
 * 记 WARN 日志后<b>放行</b>——宁可让少量请求漏过，也不能因 Redis 故障让全站不可用。
 * 这与鉴权黑名单的 KTD7（读失败 50001）形成对比：黑名单读失败是安全红线，
 * 限频写失败是可用性红线，两条线走向不同，不可混淆。日志只打印脱敏后的键
 * （防手机号等 PII 落日志，编码规范 §4.11），且传异常对象保留堆栈供排障。
 */
@Component
public class RateLimiter {

    /** 日志（独立命名，限频计数 WARN 不被 com.s2s: WARN 压制——同访问日志的考量）。 */
    private static final Logger log = LoggerFactory.getLogger(RateLimiter.class);

    /** Redis 字符串模板（注入构造器，便于测试替换）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * Lua 脚本：原子 INCR + EXPIRE，返回当前计数（单值）。
     *
     * <p>KEYS[1] = 限频键；ARGV[1] = TTL 秒数。
     * <ol>
     *   <li>{@code local current = redis.call('INCR', KEYS[1])}</li>
     *   <li>{@code if current == 1 then redis.call('EXPIRE', KEYS[1], ARGV[1]) end}
     *       ——首次 INCR 时设 TTL，防键永不过期；后续 INCR 不重置 TTL（滚动窗口语义）。</li>
     *   <li>{@code return current} —— 单值返回，消费侧经 {@link #toLong(Object)} 解包。</li>
     * </ol>
     *
     * <p>resultType 保持 {@code null}：StringRedisTemplate 的 value 序列化器会把返回值
     * 反序列化为 {@code String}，强制 {@code Long.class} 反而在反序列化处抛
     * {@code ClassCastException}（review P0 根因）。
     */
    private static final RedisScript<Object> INCR_EXPIRE_SCRIPT = new DefaultRedisScript<>(
            "local current = redis.call('INCR', KEYS[1])\n"
                    + "if current == 1 then\n"
                    + "  redis.call('EXPIRE', KEYS[1], ARGV[1])\n"
                    + "end\n"
                    + "return current"
    );

    /**
     * 构造限频计数器。
     *
     * @param redisTemplate Redis 字符串模板（计数写入）
     */
    public RateLimiter(StringRedisTemplate redisTemplate) {
        this.redisTemplate = redisTemplate;
    }

    /**
     * 对多个键同时计数（多轨并发生效），任一超限即抛异常，多轨同时超限取
     * 剩余秒数最大值作为 Retry-After（用户等最久的那个，详设 §3.4 纪律 4）。
     *
     * <p>执行流程：
     * <ol>
     *   <li>逐键执行 Lua 原子 INCR+EXPIRE；</li>
     *   <li>Redis 异常 → 记 WARN（脱敏键 + 堆栈）+ 跳过该键继续下一个（全部失败则全部放行）；</li>
     *   <li>全部执行完后，汇总超限的键，取 max({@link RateLimitEntry#retryAfterSeconds})；</li>
     *   <li>有超限 → 抛 {@code BizException.ofRetryAfter(maxCode, maxSeconds)}。</li>
     * </ol>
     *
     * <p><b>注意</b>：所有传入的 ErrorCode 都必须是 needRetryAfter=true 的码（40105 + 429xx），
     * 否则 ofRetryAfter 语义不成立。本方法不做二次校验，调用方（RateLimitInterceptor）
     * 从 RateLimitTrack 拿的码天然是 needRetryAfter=true，枚举绑定是守卫。
     *
     * @param entries 多轨道条目列表（键/键 TTL/用户可见剩余秒/阈值/超限码 五元组）
     * @return long 未超限时返回 -1；方法返回表示所有轨都通过
     * @throws BizException 任一轨超限时抛出，携带超限码与最大剩余秒数
     */
    public long incrementAndCheck(List<RateLimitEntry> entries) {
        long maxRetryAfter = -1;
        ErrorCode overflowCode = null;

        for (RateLimitEntry entry : entries) {
            try {
                Object result = redisTemplate.execute(
                        INCR_EXPIRE_SCRIPT,
                        java.util.Collections.singletonList(entry.key()),
                        String.valueOf(entry.ttlSeconds())
                );
                long current = toLong(result);
                if (current > entry.limit()) {
                    // 超限：Retry-After 用「用户可见剩余秒」（不含键 TTL 缓冲），取最大值
                    long retryAfter = Math.max(entry.retryAfterSeconds(), 1);
                    if (retryAfter > maxRetryAfter) {
                        maxRetryAfter = retryAfter;
                        overflowCode = entry.overflowCode();
                    }
                }
            } catch (Exception exception) {
                // Redis 连接失败 / 超时 / 脚本执行失败 —— 记 WARN（脱敏键 + 堆栈），放行该轨
                log.warn("RateLimiter Redis 操作失败，跳过键 {}——写失败放行，详设 §3.4 纪律 3",
                        maskKey(entry.key()), exception);
            }
        }

        if (overflowCode != null) {
            throw BizException.ofRetryAfter(overflowCode, maxRetryAfter);
        }
        return -1;
    }

    /**
     * 将 Lua 返回值可靠解包为 {@code long}（[122] review P0 修复）。
     * StringRedisTemplate 的 {@code StringRedisSerializer} 会把 Lua 数字返回值反序列化为
     * {@code String}（或底层连接的 {@code byte[]}），而非 {@code Long}——直接强转
     * {@code (long) result} 会抛 {@code ClassCastException}。本方法兼容
     * {@code Number}/{@code String}/{@code byte[]} 三种形态，是 Lua 数值解包的唯一实现处。
     *
     * @param value Lua 脚本返回的原始对象（可能为 Number/String/byte[]/null）
     * @return long 数值；null 或空串返回 0（调用方视为「计数归零」，不会误判超限）
     */
    private static long toLong(Object value) {
        if (value == null) {
            return 0;
        }
        if (value instanceof Number number) {
            return number.longValue();
        }
        if (value instanceof byte[] bytes) {
            String text = new String(bytes, StandardCharsets.UTF_8).trim();
            return text.isEmpty() ? 0 : Long.parseLong(text);
        }
        String text = value.toString().trim();
        return text.isEmpty() ? 0 : Long.parseLong(text);
    }

    /**
     * 对限频键做日志脱敏（[122] review #3 修复）：掩码键中出现的 11 位连续数字段
     * （手机号）中间 4 位，如 {@code rl:sms:phone:13800138000:1m} → {@code rl:sms:phone:138****8000:1m}。
     * 防止 SMS 轨写失败日志把完整手机号落盘（编码规范 §4.11「日志不得出现完整手机号」）。
     * userId 通常非 11 位连续数字，不会被误掩；即便命中（极小概率）也只损失可读性，无信息泄露。
     *
     * @param key 原始 Redis 键
     * @return 脱敏后的键（11 位数字段中间 4 位替换为 {@code ****}）
     */
    private static String maskKey(String key) {
        return key.replaceAll("(\\d{3})\\d{4}(\\d{4})", "$1****$2");
    }

    /**
     * 单条限频计数条目（键 / 键 TTL / 用户可见剩余秒 / 阈值 / 超限码 五元组）。
     *
     * <p>承载形态：record（Java 21）；仅在 {@link RateLimiter#incrementAndCheck(List)}
     * 调用方组装使用，是「一次多轨计数」的参数承载对象。</p>
     *
     * <p><b>ttlSeconds 与 retryAfterSeconds 的分离（[122] review #5 修复）</b>：
     * 自然日窗口的键 TTL 需比真实剩余时间多 2h 缓冲（26h，防跨日残留），但用户可见的
     * Retry-After 应是「到次日零点的真实剩余秒数」。二者若混用，Retry-After 会恒虚高 2h。
     * 故 {@code ttlSeconds} 是键的 EXPIRE 值（含缓冲），{@code retryAfterSeconds} 是
     * 用户可见剩余秒（不含缓冲），超限时只用后者。</p>
     *
     * @param key                Redis 计数键
     * @param ttlSeconds         键首次创建时的 TTL（秒，含自然日窗口的 +2h 缓冲）
     * @param retryAfterSeconds  超限时返回给用户的剩余秒（不含缓冲，滚动窗 = 窗口秒，
     *                           自然日窗 = 到次日零点秒数）
     * @param limit              计数阈值（> limit 即超限）
     * @param overflowCode       超限错误码（应为 needRetryAfter=true 的码）
     */
    public record RateLimitEntry(String key, long ttlSeconds, long retryAfterSeconds,
            int limit, ErrorCode overflowCode) {
    }
}
