package com.s2s.server.common.ratelimit;

import com.s2s.server.common.constants.RateLimitThresholds;
import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.time.LocalDate;
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
            case SMS_PHONE -> {
                // SMS_PHONE 是渠道级，需要手机号 —— 手机号从哪来？
                // 注：短信发送接口的限流在 [123] 业务代码里直接调 RateLimiter
                // （因为手机号在请求体里，拦截器拿不到），本拦截器不处理 SMS_* 轨。
                // 此处保留 switch 分支完整性，实际调用不会到这里。
            }
            case SMS_IP -> {
                // 同上：渠道级 IP 轨由业务代码直接调，拦截器不处理。
            }
            case LOGIN_FAIL -> {
                // 登录失败计数由 auth service 直接调，拦截器不处理。
            }
            case CONTACT_UID -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.contactUidDay(userId, today);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, ttlForWindow(rule.windowSeconds(), today),
                                rule.limit(), rule.overflowCode()));
                    }
                }
            }
            case CONTACT_DEV -> {
                if (validDeviceId) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.contactDevDay(deviceId, today);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, ttlForWindow(rule.windowSeconds(), today),
                                rule.limit(), rule.overflowCode()));
                    }
                }
                // 设备 ID 不合法 → 跳过设备轨（KTD14：防键空间污染，不拒绝请求）
            }
            case CONTACT_IP -> {
                for (RateLimitTrack.WindowRule rule : rules) {
                    String key = RateLimitKeys.contactIpDay(ip, today);
                    entries.add(new RateLimiter.RateLimitEntry(
                            key, ttlForWindow(rule.windowSeconds(), today),
                            rule.limit(), rule.overflowCode()));
                }
            }
            case CONTACT_BURST -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.contactBurstMinute(userId);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, rule.windowSeconds(), rule.limit(), rule.overflowCode()));
                    }
                }
            }
            case REPORT_UID -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.reportUidDay(userId, today);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, ttlForWindow(rule.windowSeconds(), today),
                                rule.limit(), rule.overflowCode()));
                    }
                }
            }
            case TRACK_UID -> {
                if (userId != null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.trackUidMinute(userId);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, rule.windowSeconds(), rule.limit(), rule.overflowCode()));
                    }
                }
            }
            case GUEST_DETAIL_DEV -> {
                // 42907 轨：仅未登录时计数（鉴权后判定，链序保证）
                if (userId == null && validDeviceId) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.guestDetailDevDay(deviceId, today);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, ttlForWindow(rule.windowSeconds(), today),
                                rule.limit(), rule.overflowCode()));
                    }
                }
            }
            case GUEST_DETAIL_IP -> {
                if (userId == null) {
                    for (RateLimitTrack.WindowRule rule : rules) {
                        String key = RateLimitKeys.guestDetailIpDay(ip, today);
                        entries.add(new RateLimiter.RateLimitEntry(
                                key, ttlForWindow(rule.windowSeconds(), today),
                                rule.limit(), rule.overflowCode()));
                    }
                }
            }
        }
    }

    /**
     * 根据窗口秒数计算 TTL：自然日窗口（windowSeconds == 86400）的 TTL = 到次日零点秒数 + 2h 缓冲，
     * 滚动窗口（1m/1h/15min）的 TTL = 窗口秒数本身。
     *
     * <p>为什么自然日键不直接用 86400 秒 TTL：因为计数键在一天内的任意时刻创建，
     * 86400 秒后过期 = 第二天的同一时刻过期，这和「自然日归零」语义不符——
     * 用户可能在 23:59 发请求，计数键存活到次日 23:59，跨了两个自然日。
     * 正确做法是键尾嵌日期片 + TTL 设为「到次日零点 + 2h 缓冲」——
     * 零点后旧键自然过期，新日期的键从零开始。
     *
     * @param windowSeconds 窗口秒数（RateLimitThresholds 常量）
     * @param today         当前自然日（用于计算到零点的秒数）
     * @return long TTL 秒数
     */
    private long ttlForWindow(long windowSeconds, LocalDate today) {
        if (windowSeconds == RateLimitThresholds.WINDOW_DAY_SECONDS) {
            // 自然日窗口：到次日零点的秒数 + 2h 缓冲（KTD6：26h 防跨日残留）
            long secondsUntilEndOfDay = java.time.Duration.between(
                    java.time.LocalDateTime.now(RateLimitThresholds.ZONE),
                    today.plusDays(1).atStartOfDay(RateLimitThresholds.ZONE)
            ).getSeconds();
            return secondsUntilEndOfDay + 7200; // +2h 缓冲 = 26h 最大 TTL
        }
        return windowSeconds;
    }

    /**
     * 取客户端 IP（优先 X-Forwarded-For 最左，然后 X-Real-IP，最后 getRemoteAddr）。
     * 与 forward-headers-strategy: framework（KTD2）对齐——Spring 已处理 XFF，
     * getRemoteAddr() 返回的就是客户端真实 IP。
     * 保留此方法是为了在 Spring 未处理的降级场景下也能取到 IP（双重保险）。
     *
     * @param request 当前 HTTP 请求
     * @return {@link String} 客户端 IP 地址；永不返回 null（空串兜底）
     */
    private String getClientIp(HttpServletRequest request) {
        String ip = request.getRemoteAddr();
        return ip != null ? ip : "";
    }
}
