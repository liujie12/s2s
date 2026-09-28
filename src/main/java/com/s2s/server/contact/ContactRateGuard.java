package com.s2s.server.contact;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitEntries;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import com.s2s.server.common.ratelimit.RateLimiter;
import java.time.Duration;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.List;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Component;

/**
 * 联系域限频与熔断守卫（[128]；详设 §5.5.1 第 [2]–[4] 步）。
 *
 * <p><b>为什么必须是命令式而非 {@code @RateLimit} 注解</b>：详设 §5.5.1 给出的是一条
 * <b>有序</b>链路（[2] 冻结 → [3] 三维日限 → [4] 突发 → [5] 帖子可见性 → [6] 解密 → …）。
 * 注解驱动的 {@code RateLimitInterceptor} 在 controller 之前统一执行，无法表达
 * 「先查冻结再计数」「计数通过才继续」这两层次序，而次序在这里是有意义的：
 * 已冻结用户再发请求时应当直接 42903，不能先去消耗三维日限（那会让「冻结」与
 * 「日限」两个计数器同时被无意义地推进，也使用户看到 42902 而非 42903 的错误文案）。</p>
 *
 * <p>计数本身仍<b>只经 {@link RateLimiter}</b>（唯一计数处，编码规范 §1.2）；本类只负责
 * 「按次序编排 + 冻结标记的读写」，轨到键的换算复用 {@link RateLimitEntries}（唯一换算处）。</p>
 *
 * <p><b>冻结标记与计数键的分工</b>（详设 §3.4 行 7）：1 分钟窗计数器
 * （{@code rl:contact:burst:...}）只在窗口内生效，窗口中滑出即归零；
 * 「当日冻结」需要跨窗口持续生效，故由独立的标记键
 * （{@code fz:contact:{userId}:{yyyyMMdd}}）承载。缺标记键时，「1min ≥10 次 → 当日冻结」
 * 会退化成「每分钟最多 10 次」。</p>
 *
 * <p><b>Redis 故障时的走向（详设 §3.4 纪律 3）</b>：本类的三类 Redis 操作
 * （冻结读、计数、冻结写）失败时一律 <b>WARN + 放行</b>，不 fail-closed。
 * 与鉴权黑名单的 KTD7（读失败 50001 绝不放行）刻意相反，理由：黑名单是
 * <b>安全边界</b>（被登出的 Token 复活 = 越权），而本类是<b>防滥用</b>
 * （漏过几次请求只是少一次拦截），纪律 3 明文「宁可让少量请求漏过，也不能因
 * Redis 故障让全站不可用」。两条线性质不同，不可混用同一处置。</p>
 */
@Component
public class ContactRateGuard {

    /** 日志。 */
    private static final Logger log = LoggerFactory.getLogger(ContactRateGuard.class);

    /** 限频计数唯一执行处。 */
    private final RateLimiter rateLimiter;

    /** Redis 模板：承载冻结标记的读写与账号维剩余量读取（计数仍归 RateLimiter）。 */
    private final StringRedisTemplate redisTemplate;

    /**
     * 构造联系域限频守卫。
     *
     * @param rateLimiter   限频计数器（三维日限与突发检测）
     * @param redisTemplate Redis 模板（冻结标记读写 + 剩余量读取）
     */
    public ContactRateGuard(RateLimiter rateLimiter, StringRedisTemplate redisTemplate) {
        this.rateLimiter = rateLimiter;
        this.redisTemplate = redisTemplate;
    }

    /**
     * 第 [2] 步：熔断冻结检查（详设 §5.5.1）。
     *
     * <p>冻结标记存在即 {@code 42903}，并携带「到次日零点的剩余秒数」作为
     * {@code Retry-After}——冻结是自然日语义，跨零点自动解除。</p>
     *
     * @param userId 当前登录用户 ID
     * @param today  当前自然日（Asia/Shanghai）
     * @throws BizException {@code 42903}（needRetryAfter，带剩余秒数）
     */
    public void assertNotFrozen(Long userId, LocalDate today) {
        String key = RateLimitKeys.contactFreezeDay(userId, today);
        boolean frozen;
        try {
            frozen = Boolean.TRUE.equals(redisTemplate.hasKey(key));
        } catch (RuntimeException exception) {
            // 读失败放行（详设 §3.4 纪律 3）：防滥用控制不因 Redis 故障升级为全站不可用。
            // 键经脱敏（userId 非 PII，但统一走 mask 习惯，避免日后误将手机号塞进键）。
            log.warn("联系熔断冻结标记读取失败，放行本次请求（详设 §3.4 纪律 3）：key={}",
                    mask(key), exception);
            return;
        }
        if (frozen) {
            throw BizException.ofRetryAfter(ErrorCode.CIRCUIT_BROKEN,
                    RateLimitKeys.secondsUntilEndOfDay(today));
        }
    }

    /**
     * 第 [3] 步：三维日限（账号 30 / 设备 30 / IP 100，任一超限即拒）。
     *
     * <p>三轨一次提交给 {@link RateLimiter}，由它取超限轨中最大的剩余秒数作为
     * {@code Retry-After}（用户等待最久的那个维度），且响应<b>不区分命中维度</b>
     * ——三维同码 {@code 42902}，风控阈值不外泄（编码规范 §4.7）。</p>
     *
     * @param dimensions 本次请求的限频维度（账号/设备/IP + 自然日）
     * @throws BizException {@code 42902}（needRetryAfter，带剩余秒数）
     */
    public void checkDailyLimits(RateLimitEntries.RateLimitDimensions dimensions) {
        List<RateLimiter.RateLimitEntry> entries = new ArrayList<>();
        entries.addAll(RateLimitEntries.forTrack(RateLimitTrack.CONTACT_UID, dimensions));
        entries.addAll(RateLimitEntries.forTrack(RateLimitTrack.CONTACT_DEV, dimensions));
        entries.addAll(RateLimitEntries.forTrack(RateLimitTrack.CONTACT_IP, dimensions));
        if (entries.isEmpty()) {
            // 理论上不可达：IP 轨恒产生条目（ip 非 null）。留此分支是为「配置被改空」
            // 时不静默跳过整段判定——跳过会让限频无声消失。
            throw new IllegalStateException("联系三维日限未产生任何计数条目：IP 轨应恒有条目");
        }
        rateLimiter.incrementAndCheck(entries);
    }

    /**
     * 第 [4] 步：突发检测（1 分钟内计数超阈值 → 写当日冻结标记 → {@code 42903}）。
     *
     * <p>「先计数、超限则落标记」的次序不可颠倒：标记必须在超限被确认的那一刻写入，
     * 否则用户下一次请求会因 1 分钟窗滑出而复通，与「当日冻结」口径不符。</p>
     *
     * <p>实现上靠捕获 {@link RateLimiter} 抛出的 {@code 42903} 来识别超限——这是
     * 「计数判定唯一归 {@link RateLimiter}」的必然形态：本类不自行读取计数器的值
     * 来判阈值，避免出现第二套判定逻辑（两处判定不同步时，冻结会在错误的时刻触发）。</p>
     *
     * <p><b>已知的边界差一（登记见说明文档 §2.9 DEC-12）</b>：详设 §3.4 行 7 的措辞是
     * 「1min <b>≥10</b> 次 → 当日冻结」，而 {@link RateLimiter} 的超限判定统一为
     * 「计数 {@code > limit}」（严格大于），{@link RateLimitTrack#CONTACT_BURST} 的
     * limit 直接取常量 10，故实际在第 <b>11</b> 次触发。本类不在此处自行做 {@code −1}
     * 修正（那会形成第二套阈值口径），保持与 [122] 已验收的轨绑定一致，
     * 差异登记待详设评审裁定。</p>
     *
     * @param dimensions 本次请求的限频维度（突发轨只用账号维）
     * @throws BizException {@code 42903}（needRetryAfter，带剩余秒数）
     */
    public void checkBurst(RateLimitEntries.RateLimitDimensions dimensions) {
        List<RateLimiter.RateLimitEntry> entries =
                RateLimitEntries.forTrack(RateLimitTrack.CONTACT_BURST, dimensions);
        if (entries.isEmpty()) {
            // userId 为 null（游客）时突发轨不生效；联系接口在 service 前已强制登录，
            // 此分支只是防御性表达，不抛异常（游客由 controller 的 40101 拦住）。
            return;
        }
        try {
            rateLimiter.incrementAndCheck(entries);
        } catch (BizException exception) {
            if (exception.getErrorCode() == ErrorCode.CIRCUIT_BROKEN) {
                markFrozen(dimensions.userId(), dimensions.today());
            }
            throw exception;
        }
    }

    /**
     * 取账号维的今日剩余可查看次数（契约 {@code remaining_today}，仅账号维）。
     *
     * <p><b>只读不计数</b>：读取的是 {@link RateLimiter} 刚推进过的账号维计数键
     * （键由唯一键拼装处 {@link RateLimitKeys} 提供），不自行累加、不落第二份计数。</p>
     *
     * <p>读失败（Redis 异常）时返回<b>阈值本身</b>而非 0：该字段在客户端只是前置提示，
     * 契约已明令「不得当成承诺、以实际请求结果为准」；而返回 0 会让界面显示
     * 「今日剩余 0 次」却仍能成功请求，属于用错误信息否定自己。</p>
     *
     * @param userId 当前登录用户 ID
     * @param today  当前自然日（Asia/Shanghai）
     * @return int 账号维今日剩余次数（{@code 阈值 − 已用}，钳制到 ≥0；
     *         Redis 读失败时返回阈值本身）
     */
    public int remainingToday(Long userId, LocalDate today) {
        String key = RateLimitKeys.contactUidDay(userId, today);
        String raw;
        try {
            raw = redisTemplate.opsForValue().get(key);
        } catch (RuntimeException exception) {
            log.warn("联系剩余次数读取失败，按阈值返回（该字段非承诺值）：key={}", mask(key), exception);
            return RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY;
        }
        long used = parseCount(raw);
        long remaining = RateLimitThresholds.CONTACT_UID_LIMIT_PER_DAY - used;
        return (int) Math.max(remaining, 0);
    }

    /**
     * 写当日冻结标记（值无意义，存在即冻结）。
     *
     * <p>TTL 取「到次日零点 + 2h 缓冲」——与自然日计数键同一口径
     * （{@link RateLimitEntries#naturalDayKeyTtlSeconds(LocalDate)}），保证冻结与日限
     * 同时失效；写失败 WARN 后放行（详设 §3.4 纪律 3），本次仍按 {@code 42903} 拒绝。</p>
     *
     * @param userId 当前登录用户 ID
     * @param today  当前自然日（Asia/Shanghai）
     */
    private void markFrozen(Long userId, LocalDate today) {
        String key = RateLimitKeys.contactFreezeDay(userId, today);
        try {
            redisTemplate.opsForValue().set(key, "1",
                    Duration.ofSeconds(RateLimitEntries.naturalDayKeyTtlSeconds(today)));
            log.warn("联系熔断触发，已写当日冻结标记：key={}", mask(key));
        } catch (RuntimeException exception) {
            log.warn("联系熔断冻结标记写入失败（本次仍拒绝，标记可能未持久）：key={}",
                    mask(key), exception);
        }
    }

    /**
     * 解析 Redis 计数值（可能为 null/空串/非数字）。
     *
     * @param raw Redis 取回的原始值
     * @return long 计数值；不可解析时返回 0（视为未使用，不误报「已用完」）
     */
    private long parseCount(String raw) {
        if (raw == null || raw.isBlank()) {
            return 0;
        }
        try {
            return Long.parseLong(raw.trim());
        } catch (NumberFormatException exception) {
            log.warn("联系计数值不可解析，按 0 处理：raw={}", raw);
            return 0;
        }
    }

    /**
     * 键脱敏（11 位连续数字段中间 4 位掩码）——与 {@code RateLimiter} 同一习惯，
     * 防日后键里混入手机号类 PII（编码规范 §4.11）。
     *
     * @param key 原始键
     * @return {@link String} 脱敏后键
     */
    private String mask(String key) {
        return key.replaceAll("(\\d{3})\\d{4}(\\d{4})", "$1****$2");
    }
}
