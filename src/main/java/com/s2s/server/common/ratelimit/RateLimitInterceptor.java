package com.s2s.server.common.ratelimit;

import com.s2s.server.common.web.AuthContext;
import com.s2s.server.common.web.ClientIp;
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
 * <p><b>「轨 → 计数条目」的换算不在本类</b>：已上浮至 {@link RateLimitEntries}
 * （[128] 起因：contact 域的复合次序需直调 {@link RateLimiter}，第 2 处消费即抽提，
 * 编码规范 §1.1）。本类只负责「读注解 → 取维度 → 汇总条目 → 交给计数器」。</p>
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
        String ip = ClientIp.of(request);
        // 维度打包（设备头合法性在 RateLimitEntries.RateLimitDimensions#of 里派生，
        // 避免「传了 deviceId 却漏算 valid 标记」的偏差）。
        RateLimitEntries.RateLimitDimensions dimensions =
                RateLimitEntries.RateLimitDimensions.of(userId, deviceId, ip, today);

        for (RateLimitTrack track : annotation.value()) {
            entries.addAll(RateLimitEntries.forTrack(track, dimensions));
        }

        if (entries.isEmpty()) {
            // 所有轨都被跳过（如游客接口但已登录 → GUEST_DETAIL 两轨都跳过）
            return true;
        }

        rateLimiter.incrementAndCheck(entries);
        return true;
    }
}
