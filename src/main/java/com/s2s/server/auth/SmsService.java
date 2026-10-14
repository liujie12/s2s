package com.s2s.server.auth;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.auth.dto.SendCodeRequest;
import com.s2s.server.auth.dto.SendCodeResult;
import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import com.s2s.server.common.ratelimit.RateLimiter;
import com.s2s.server.common.ratelimit.RateLimitTrack;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;

/**
 * 短信验证码服务（[123] U3 骨架 → U4 实现 {@code sendCode}）。
 *
 * <p>职责：发送短信验证码（{@code POST /auth/sms/send}），四维限频（同手机号
 * 1min/1h/1d 三档 + 同 IP 1h），验证码存 Redis（{@code sms:{phone}}），不落库
 * （详设 §5.1）。限频超限回 {@code 42905} 并携带 {@code Retry-After}。</p>
 *
 * <p>限频落地：渠道级三轨（SMS_PHONE/SMS_IP）的维度是手机号（在请求体里），
 * {@link RateLimitInterceptor} 读不到，故本类<b>直调</b> {@link RateLimiter}
 * （[122] review #4 明列）。窗口→条目的转换复用 {@link RateLimiter#entry}
 * （U4 上移的公共方法，避免复制「自然日 +2h 缓冲」字面量）。</p>
 *
 * <p>验证码生成：dev 桩固定 {@link SmsCodePolicy#DEBUG_CODE}（plan Assumptions），
 * 不接真短信服务商；存 Redis 值含 {@code code/expire_at}（{@link SmsCode}）。</p>
 *
 * <p><b>内测白名单闸（2026-10-14 裁定，A+B 分阶段的 B 阶段临时收口）</b>：固定码
 * 在公网等于「任意手机号都能登录」（冒用风险），故由 {@code s2s.sms.whitelist}
 * 把可登录范围收敛为「仅名单内手机号」。<b>留空 = 不启用（dev/staging 全放行）</b>；
 * prod 侧以无默认值占位强制注入，避免「忘配 ⇒ 静默全放行」这类静默失效。
 * 非名单号 → {@code 40305}（复用既有错误码，不新增）。接入真实短信服务商（A 阶段）
 * 后改随机 6 位码，本闸可随之退役。</p>
 *
 * <p>出处：详设 §5.1（auth 域）、PRD §12.2（发送短信验证码）、plan KTD1。</p>
 */
@Service
public class SmsService {

    /** Redis 字符串模板（验证码存储）。 */
    private final StringRedisTemplate redisTemplate;

    /** 限频计数器（四维限频）。 */
    private final RateLimiter rateLimiter;

    /** Jackson 序列化器（验证码值 JSON 序列化）。 */
    private final ObjectMapper objectMapper;

    /** 内测白名单（逗号分隔解析结果）；<b>空集 = 不启用白名单（全放行）</b>。 */
    private final Set<String> whitelist;

    /**
     * 构造短信验证码服务：注入 Redis、限频计数器、Jackson 序列化器与内测白名单。
     *
     * @param redisTemplate Redis 字符串模板（验证码存储）
     * @param rateLimiter   限频计数器（四维限频）
     * @param objectMapper  Jackson 序列化器（验证码值 JSON 序列化）
     * @param whitelistRaw  内测白名单原文（{@code s2s.sms.whitelist}，逗号分隔；空串 = 不启用）
     */
    public SmsService(StringRedisTemplate redisTemplate, RateLimiter rateLimiter,
            ObjectMapper objectMapper,
            @Value("${s2s.sms.whitelist:}") String whitelistRaw) {
        this.redisTemplate = redisTemplate;
        this.rateLimiter = rateLimiter;
        this.objectMapper = objectMapper;
        this.whitelist = parseWhitelist(whitelistRaw);
    }

    /**
     * 发送短信验证码：内测白名单闸 → 四维限频 → 生成验证码 → 存 Redis → 返回有效期。
     *
     * <p>执行流程：
     * <ol>
     *   <li><b>内测白名单闸</b>：白名单非空且手机号不在其中 → {@code 40305}，
     *       <b>先于限频</b>（不占限频计数、不写 Redis）；</li>
     *   <li>四维限频（手机号 1m/1h/1d + IP 1h），超限抛 {@code BizException}
     *       （42905 + Retry-After）；</li>
     *   <li>生成验证码（dev 桩固定 {@code 888888}），到期时刻 = now + 300 秒；</li>
     *   <li>存 Redis {@code sms:{phone}}（值 {@link SmsCode} JSON，TTL 300 秒）；</li>
     *   <li>返回 {@link SendCodeResult}（expire_in = 300）。</li>
     * </ol>
     *
     * @param request 发送验证码请求（phone + scene）
     * @param ip      客户端 IP（IP 维限频用；由 controller 从请求取真实 IP 传入）
     * @return {@link SendCodeResult} 验证码有效期（秒）
     * @throws BizException 手机号不在内测白名单 → {@code 40305}；限频超限 → {@code 42905}
     */
    public SendCodeResult sendCode(SendCodeRequest request, String ip) {
        ensureWhitelisted(request.phone());
        rateLimit(request.phone(), ip);

        SmsCode smsCode = new SmsCode(SmsCodePolicy.DEBUG_CODE,
                Instant.now().plusSeconds(SmsCodePolicy.CODE_TTL_SECONDS));
        redisTemplate.opsForValue().set(smsKey(request.phone()), toJson(smsCode),
                Duration.ofSeconds(SmsCodePolicy.CODE_TTL_SECONDS));

        return new SendCodeResult(SmsCodePolicy.CODE_TTL_SECONDS);
    }

    /**
     * 内测白名单闸：白名单非空且手机号不在其中即拒（2026-10-14 裁定，B 阶段临时收口）。
     *
     * <p>位置刻意在四维限频之前：被拒请求不消耗限频计数、不写 Redis，避免「白名单外的号
     * 把限频额度占掉」这类无谓副作用；也避免名单外号在 Redis 里留下 {@code sms:} 键。</p>
     *
     * @param phone 请求发码的手机号
     * @return void；白名单未启用或手机号命中时正常返回
     * @throws BizException 白名单已启用且手机号不在其中 → {@code 40305}（复用既有码，不新增）
     */
    private void ensureWhitelisted(String phone) {
        if (whitelist.isEmpty() || whitelist.contains(phone)) {
            return;
        }
        throw BizException.of(ErrorCode.NO_PERMISSION);
    }

    /**
     * 解析逗号分隔的内测白名单原文（去首尾空白、丢弃空项）。
     *
     * @param raw 配置原文 {@code s2s.sms.whitelist}；null/空白视为未启用
     * @return {@link Set} 手机号集合；<b>空集 = 未启用白名单（全放行）</b>
     */
    private static Set<String> parseWhitelist(String raw) {
        if (raw == null || raw.isBlank()) {
            return Set.of();
        }
        Set<String> parsed = new HashSet<>();
        for (String item : raw.split(",")) {
            String phone = item.trim();
            if (!phone.isEmpty()) {
                parsed.add(phone);
            }
        }
        return Set.copyOf(parsed);
    }

    /**
     * 四维限频：手机号 1min/1h/1d 三轨 + IP 1h 一轨，任一超限抛异常（42905）。
     *
     * @param phone 手机号（渠道级维度）
     * @param ip    客户端 IP（渠道级维度）
     */
    private void rateLimit(String phone, String ip) {
        List<RateLimiter.RateLimitEntry> entries = new ArrayList<>();
        LocalDate today = RateLimitKeys.today();
        for (RateLimitTrack.WindowRule rule : RateLimitTrack.SMS_PHONE.rules()) {
            entries.add(RateLimiter.entry(smsPhoneKey(phone, rule, today), rule, today));
        }
        for (RateLimitTrack.WindowRule rule : RateLimitTrack.SMS_IP.rules()) {
            entries.add(RateLimiter.entry(RateLimitKeys.smsIpHour(ip), rule, today));
        }
        rateLimiter.incrementAndCheck(entries);
    }

    /**
     * 按窗口档拼装手机号维短信限频键：1min/1h 滚动窗口与 1d 自然日窗口分别对应
     * {@link RateLimitKeys} 的 minute/hour/day 三方法，按 {@code windowSeconds} 区分
     * （不依赖 {@link RateLimitTrack.SMS_PHONE} 规则数组下标顺序，防顺序漂移）。
     *
     * @param phone 手机号
     * @param rule  窗口规则（取 windowSeconds 判窗口档）
     * @param today 当前自然日（1d 轨键尾日期片用）
     * @return {@link String} Redis 限频键
     */
    private String smsPhoneKey(String phone, RateLimitTrack.WindowRule rule, LocalDate today) {
        long windowSeconds = rule.windowSeconds();
        if (windowSeconds == RateLimitThresholds.WINDOW_MINUTE_SECONDS) {
            return RateLimitKeys.smsPhoneMinute(phone);
        }
        if (windowSeconds == RateLimitThresholds.WINDOW_HOUR_SECONDS) {
            return RateLimitKeys.smsPhoneHour(phone);
        }
        return RateLimitKeys.smsPhoneDay(phone, today);
    }

    /**
     * 拼装验证码存储键 {@code sms:{phone}}。
     *
     * @param phone 手机号
     * @return {@link String} 验证码存储键
     */
    private String smsKey(String phone) {
        return SmsCodePolicy.SMS_KEY_PREFIX + phone;
    }

    /**
     * 将验证码值序列化为 JSON 字符串（snake_case，对齐 KTD1）。
     *
     * @param smsCode 验证码值（{@link SmsCode}）
     * @return {@link String} JSON 文本
     * @throws IllegalStateException 序列化失败（服务端缺陷，由全局兜底映射 50001）
     */
    private String toJson(SmsCode smsCode) {
        try {
            return objectMapper.writeValueAsString(smsCode);
        } catch (JsonProcessingException exception) {
            throw new IllegalStateException("验证码序列化失败", exception);
        }
    }
}
