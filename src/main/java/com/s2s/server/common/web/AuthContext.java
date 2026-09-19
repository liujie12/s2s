package com.s2s.server.common.web;

import jakarta.servlet.http.HttpServletRequest;

/**
 * 鉴权上下文的<b>唯一读写器</b>（[122] U3；详设 §3.1 鉴权段；编码规范 §1.2 唯一实现处清单）。
 *
 * <p>职责：以请求属性为载体，提供 userId 的写入与读取；跨组件（RateLimitInterceptor、
 * 业务 service、幂等键拼装等）统一从此类读取登录态，<b>禁止</b>各自从 request attribute
 * 或 MDC 直读（键名漂移、类型错配零容忍）。
 *
 * <p>设计取舍：
 * <ul>
 *   <li>载体选择 {@code request.setAttribute} 而非 {@code ThreadLocal}——Servlet 容器
 *       线程复用 + 异步请求派发场景下 ThreadLocal 易串号，request 属性与请求同生命周期，
 *       与 RequestIdFilter 的 MDC 清理（finally）互不干扰（清理 MDC 不碰属性）；</li>
 *   <li>userId 类型为 {@link Long}（与 user.id 主键类型一致），未登录态为 {@code null}，
 *       不用 boolean 标记 isLoggedIn（状态信息可直接从 userId 是否为 null 推导，防双源漂移）；</li>
 *   <li>静态方法而非实例：上下文无状态、操作纯读写，静态方法减少注入链，跨域调用方
 *       （common/ratelimit、common/idempotency）无需依赖 auth 域的 bean。</li>
 * </ul>
 *
 * <p><b>与 42907 的关系</b>：{@link #currentUserId(HttpServletRequest)} 返回非 null 即
 * 「已登录」，{@code RateLimitInterceptor} 据此跳过 guest_detail 轨（详设 §3.4
 * 纪律 5；链序保证鉴权先于限流，判定天然在鉴权之后）。
 */
public final class AuthContext {

    /**
     * 请求属性键：登录用户 ID（Long 类型）。键名常量在此唯一承载，
     * 写入方（[122] U3 {@code AuthInterceptor}）与读取方（限流/幂等/业务域）
     * 均经由 {@link AuthContext} 静态方法操作，禁直读直写。
     */
    private static final String USER_ID_ATTRIBUTE = "AUTH_USER_ID";

    /**
     * 工具类：禁止实例化。
     */
    private AuthContext() {
        throw new AssertionError("AuthContext 是工具类，不可实例化");
    }

    /**
     * 写入当前请求的登录用户 ID（由 {@code AuthInterceptor} 在鉴权通过后调用）。
     *
     * <p>同时把 userId 写入 MDC 的 {@link RequestIdFilter#MDC_USER_ID} 键——
     * 这是 MDC user_id 的<b>唯一写入点</b>（KTD5），RequestIdFilter 的 finally
     * 统一回收；已登录态每次请求写一次，未登录态不写（MDC 中该键缺省）。
     *
     * @param request 当前 HTTP 请求（属性写入目标）
     * @param userId  登录用户 ID（非 null、正数）
     * @throws IllegalArgumentException userId 为 null 或非正数时抛出（拦截器不应传非法值，
     *         抛异常是开发期守门，生产不应触发）
     */
    public static void setUserId(HttpServletRequest request, Long userId) {
        if (userId == null || userId <= 0) {
            throw new IllegalArgumentException("userId 必须为正数，收到: " + userId);
        }
        request.setAttribute(USER_ID_ATTRIBUTE, userId);
        org.slf4j.MDC.put(RequestIdFilter.MDC_USER_ID, String.valueOf(userId));
    }

    /**
     * 读取当前请求的登录用户 ID（跨组件统一读取入口）。
     *
     * @param request 当前 HTTP 请求（属性读取源）
     * @return {@link Long} 登录用户 ID；未登录（属性不存在或类型不符）返回 {@code null}
     */
    public static Long currentUserId(HttpServletRequest request) {
        Object value = request.getAttribute(USER_ID_ATTRIBUTE);
        if (value instanceof Long userId) {
            return userId;
        }
        return null;
    }
}
