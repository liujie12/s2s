package com.s2s.server.common.ratelimit;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.time.Duration;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import org.springframework.stereotype.Component;
import org.springframework.web.method.HandlerMethod;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * 限频拦截器（[122] U4；详设 §3.1 横切链第三位；§3.4 限频）。
 *
 * <p>职责：读取 handler 上的 {@link RateLimit} 注解，解析声明的限频轨，
 * 拼装对应 Redis 键，调用 {@link RateLimiter} 执行原子计数与超限判定，
 * 超限则抛 {@code BizException.ofRetryAfter(...)}（由 GlobalExceptionHandler
 * 统一写 Retry-After 响应头——本类 <b>绝不</b>直写响应头，编码规范 §1.2
 * 「GlobalExceptionHandler 是唯一写 Retry-After 头的位置」）。
 *
 * <p>链序位置：AuthInterceptor 之后、IdempotencyInterceptor 之前——
 * 42907（游客详情限频）的判定依赖鉴权上下文（AuthContext 为空才计数），
 * 必须先鉴权再限流；限流又必须先于幂等（详设 §3.1「限流必先于幂等」——
 * 幂等 SETNX 是更重的操作，先挡掉超限请求节省 Redis 资源）。
 *
 * <p><b>42907 判定点（详设 §3.4 纪律 5 + 特殊性 2）</b>：
 * {@code GUEST_DETAIL_DEV / GUEST_DETAIL_IP} 两轨只在 AuthContext 为空时计数——
 * 已登录用户不消耗游客额度。如果 handler 的注解声明了 GUEST_DETAIL_* 轨，
 * 但当前请求已登录（AuthContext 非空），直接跳过游客轨，不计数、不超限。
 * 这是「42907 仅未登录请求生效」的实现方式，天然在鉴权之后（链序保证）。
 *
 * <p><b>设备头校验（KTD14）</b>：需要设备维度的轨（CONTACT_DEV、GUEST_DETAIL_DEV）
 * 在入键前经 {@link RateLimitKeys#isValidDeviceId(String)} 校验，
 * 不合法则 <b>跳过设备轨</b>（仅 IP 轨/账号轨照常计数）——防键空间污染，
 * 与幂等键的「格式错 → 40001」不同：设备 ID 是辅助维度，错了不拒绝请求，
 * 只是少一个维度的保护，降级路径更温和。
 *
 * <p><b>渠道级三轨的显式拒绝（[122] review #4 修复）</b>：{@code SMS_PHONE}/
 * {@code SMS_IP}/{@code LOGIN_FAIL} 三轨的维度是手机号（在请求体里，拦截器读不到），
 * 须由 auth 域业务代码直调 {@link RateLimiter}。若被经 {@code @RateLimit} 标注，
 * 本拦截器抛 {@link IllegalStateException}（快速失败）而非静默放行——静默放行会让
 * 限频无声失效，快速失败把误标注暴露在开发期。
 */
@Component
public class RateLimitInterceptor implements HandlerInterceptor {

    /** X-Device-Id 请求头名（契约三头之一，详设 §3.2）。 */
    private static final String DEVICE_ID_HEADER = "X-Device-Id";

    /** 限频计数器（核心逻辑承载）。 */
    private final RateLimiter rateLimiter;

    /**
     * 构造限频拦截器，注入计数器。
     *
     * @param rateLimiter 限频计数器（原子 INCR+EXPIRE + 超限判定）
     */
    public RateLimitInterceptor(RateLimiter rateLimiter) {
        this.rateLimiter = rateLimiter;
    }

    /**
     * preHandle：解析注解 → 拼装键 → 计数 → 超限则抛异常。
     *
     * <p>执行步骤：
     * <ol>
     *   <li>handler 非 HandlerMethod（如静态资源） → 直接放行；</li>
     *   <li>方法上无 @RateLimit 注解 → 直接放行；</li>
     *   <li>逐轨拼装键（注意 GUEST_DETAIL 轨只在游客态计数）；</li>
     *   <li>组装 RateLimitEntry 列表，调 RateLimiter.incrementAndCheck；</li>
     *   <li>超限 → 异常已由 limiter 抛出，此处不二次处理。</li>
     * </ol>
     *
     * @param request  当前 HTTP 请求（头/属性/IP 读取源）
     * @param response 当前 HTTP 响应（本类不写响应头，由 handler 接管）
     * @param handler  目标处理器（判断是否带 @RateLimit 注解）
     * @return boolean；{@code true} 放行（未超限 / 不限频接口）
     * @throws Exception 超限时抛 {@link com.s2s.server.common.error.BizException}
     *                   （ofRetryAfter，带剩余秒数）
     */
    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
            Object handler) throws Exception {
        if (!(handler instanceof HandlerMethod handlerMethod)) {
            return true;
        }
        RateLimit annotation = handlerMethod.getMethodAnnotation(RateLimit.class);
        if (annotation == null) {
            return true;
        }

        List<RateLimiter.RateLimitEntry> entries = new ArrayList<>();
        LocalDate today = RateLimitKeys.today();
        Long userId = AuthContext.currentUserId(request);
        String deviceId = request.getHeader(DEVICE_ID_HEADER);
        boolean validDeviceId = RateLimitKeys.isValidDeviceId(deviceId);
        String ip = getClientIp(request);

        for (RateLimitTrack track : annotation.value()) {
            buildEntriesForTrack(track, userId, deviceId, validDeviceId, ip, today, entries);
        }

        if (entries.isEmpty()) {
            // 所有轨都被跳过（如游客接口但已登录 → GUEST_DETAIL 两轨都跳过）
            return true;
        }

        rateLimiter.incrementAndCheck(entries);
        return true;
    }

    /**
     * 为指定轨拼装键并加入 entries 列表。
     * 本方法是单轨到键的映射中心，集中处理：
     * <ul>
     *   <li>渠道级三轨（SMS_PHONE/SMS_IP/LOGIN_FAIL）抛异常拒绝——维度是手机号，
     *       拦截器拿不到，须业务代码直调 RateLimiter（[122] review #4）；</li>
     *   <li>游客轨的鉴权判定（已登录 → 跳过）；</li>
     *   <li>设备轨的格式校验（不合法 → 跳过）；</li>
     *   <li>多窗口轨（SMS_PHONE 有 1m/1h/1d 三个窗口）逐一加 entries。</li>
     * </ul>
     *
     * @param track        限频轨标识
     * @param userId       当前用户 ID（可能为 null = 游客）
     * @param deviceId     设备 ID 头值（可能为 null）
     * @param validDeviceId 设备 ID 是否合法（KTD14 校验结果）
     * @param ip           客户端 IP
     * @param today        当前自然日
     * @param entries      待填充的条目列表（输出参数）
     */
    private void buildEntriesForTrack(RateLimitTrack track, Long userId, String deviceId,
            boolean validDeviceId, String ip, LocalDate today,
            List<RateLimiter.RateLimitEntry> entries) {
        RateLimitTrack.WindowRule[] rules = track.rules();
        switch (track) {
            case SMS_PHONE, SMS_IP, LOGIN_FAIL -> throw new IllegalStateException(
                    "渠道级轨 " + track + " 不能经 @RateLimit 声明（维度是手机号，拦截器读不到），"
                            + "须业务代码直调 RateLimiter（详设 §3.4 纪律 2）");
            case CONTACT_UID -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.contactUidDay(userId, today), rule, today));
                    }
                }
            }
            case CONTACT_DEV -> {
                if (validDeviceId) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.contactDevDay(deviceId, today), rule, today));
                    }
                }
                // 设备 ID 不合法 → 跳过设备轨（KTD14：防键空间污染，不拒绝请求）
            }
            case CONTACT_IP -> {
                for (RateLimitTrack.WindowRule rule : rules) {
                    entries.add(entry(RateLimitKeys.contactIpDay(ip, today), rule, today));
                }
            }
            case CONTACT_BURST -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.contactBurstMinute(userId), rule, today));
                    }
                }
            }
            case REPORT_UID -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.reportUidDay(userId, today), rule, today));
                    }
                }
            }
            case TRACK_UID -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.trackUidMinute(userId), rule, today));
                    }
                }
            }
            case GUEST_DETAIL_DEV -> {
                // 42907 轨：仅未登录时计数（鉴权后判定，链序保证）
                if (userId == null && validDeviceId) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.guestDetailDevDay(deviceId, today), rule, today));
                    }
                }
            }
            case GUEST_DETAIL_IP -> {
                if (userId == null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        entries.add(entry(RateLimitKeys.guestDetailIpDay(ip, today), rule, today));
                    }
                }
            }
        }
    }

    /**
     * 按窗口语义构造限频条目（[122] review #5 修复：分离键 TTL 与用户可见剩余秒）。
     *
     * <p>滚动窗口（{@code :1m}/{@code :1h}）：键 TTL 与剩余秒均为窗口秒数。
     * 自然日窗口（{@code :1d}）：键 TTL = 到次日零点秒数 + 2h 缓冲（26h 防跨日残留），
     * 但 Retry-After 必须是「到次日零点的真实剩余秒」——二者若混用，用户会被提示
     * 比真实重置时间多等 2h（review #5 缺陷）。故 {@link RateLimiter.RateLimitEntry}
     * 的 {@code ttlSeconds} 与 {@code retryAfterSeconds} 分开承载。</p>
     *
     * @param key   Redis 计数键
     * @param rule  窗口规则（阈值/窗口秒/超限码三元组）
     * @param today 当前自然日（自然日窗口算到零点秒数用）
     * @return {@link RateLimiter.RateLimitEntry} 五元组
     */
    private RateLimiter.RateLimitEntry entry(String key, RateLimitTrack.WindowRule rule, LocalDate today) {
        long windowSeconds = rule.windowSeconds();
        if (windowSeconds == RateLimitThresholds.WINDOW_DAY_SECONDS) {
            long secondsUntilEndOfDay = secondsUntilEndOfDay(today);
            // 键 TTL = 到零点 + 2h 缓冲；Retry-After = 到零点（不含缓冲）
            return new RateLimiter.RateLimitEntry(key, secondsUntilEndOfDay + 7200,
                    secondsUntilEndOfDay, rule.limit(), rule.overflowCode());
        }
        return new RateLimiter.RateLimitEntry(key, windowSeconds, windowSeconds,
                rule.limit(), rule.overflowCode());
    }

    /**
     * 计算自当前时刻到次日零点（Asia/Shanghai 时区）的剩余秒数——自然日窗口
     * 的「用户可见剩余秒」（Retry-After 真源），不含键 TTL 的 +2h 缓冲。
     *
     * @param today 当前自然日（Asia/Shanghai）
     * @return long 到次日零点的剩余秒数，恒 ≥0
     */
    private long secondsUntilEndOfDay(LocalDate today) {
        return Duration.between(
                LocalDateTime.now(RateLimitThresholds.ZONE),
                today.plusDays(1).atStartOfDay(RateLimitThresholds.ZONE)
        ).getSeconds();
    }

    /**
     * 取客户端 IP。{@code forward-headers-strategy: framework}（KTD2）下，
     * Spring 已把 {@code X-Forwarded-For} 解析进 {@code request.getRemoteAddr()}，
     * 故直接取 {@code getRemoteAddr()} 即为真实客户端 IP（无代理头时回退直连地址）。
     *
     * @param request 当前 HTTP 请求
     * @return {@link String} 客户端 IP 地址；永不返回 null（空串兜底）
     */
    private String getClientIp(HttpServletRequest request) {
        String ip = request.getRemoteAddr();
        return ip != null ? ip : "";
    }
}
