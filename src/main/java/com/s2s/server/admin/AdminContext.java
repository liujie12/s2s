package com.s2s.server.admin;

import com.s2s.server.common.audit.OperatorRole;
import jakarta.servlet.http.HttpServletRequest;

/**
 * 后台鉴权上下文的**唯一读写器**（[153] B2-5；形态对齐 {@code common.web.AuthContext}）。
 *
 * <p>职责：以请求属性承载「当前后台操作人 = adminId + 角色」，供后台 Controller/Service
 * 读取与 RBAC 判定；<b>禁</b>各处直读 request attribute。</p>
 *
 * <p>与 C 端 {@code AuthContext} **分离**：后台身份不写 C 端 userId 槽，
 * 避免「后台 Token 被当作 C 端登录态」这类串号（《决策登记表》2026-10-12：
 * 后台 Token 与 C 端 Token 分离，同密钥 + {@code scope=admin} 声明）。</p>
 */
public final class AdminContext {

    /** 请求属性键：管理员 ID。 */
    private static final String ADMIN_ID_ATTRIBUTE = "AUTH_ADMIN_ID";

    /** 请求属性键：管理员角色（{@link OperatorRole}）。 */
    private static final String ADMIN_ROLE_ATTRIBUTE = "AUTH_ADMIN_ROLE";

    /**
     * 工具类：禁止实例化。
     */
    private AdminContext() {
        throw new AssertionError("AdminContext 是工具类，不可实例化");
    }

    /**
     * 写入当前请求的后台操作人（由 {@code AdminInterceptor} 鉴权通过后调用）。
     *
     * @param request 当前 HTTP 请求
     * @param adminId 管理员 ID（非 null、正数）
     * @param role    管理员角色（必须是后台四角色之一）
     * @throws IllegalArgumentException adminId 非法或角色非后台角色时抛出（开发期守门）
     */
    public static void set(HttpServletRequest request, Long adminId, OperatorRole role) {
        if (adminId == null || adminId <= 0) {
            throw new IllegalArgumentException("adminId 必须为正数，收到: " + adminId);
        }
        if (role == null || !role.isAdminRole()) {
            throw new IllegalArgumentException("非后台角色不可入上下文: " + role);
        }
        request.setAttribute(ADMIN_ID_ATTRIBUTE, adminId);
        request.setAttribute(ADMIN_ROLE_ATTRIBUTE, role);
    }

    /**
     * 读取当前后台操作人 ID。
     *
     * @param request 当前 HTTP 请求
     * @return {@link Long} 管理员 ID；未鉴权返回 {@code null}
     */
    public static Long currentAdminId(HttpServletRequest request) {
        Object value = request.getAttribute(ADMIN_ID_ATTRIBUTE);
        return value instanceof Long adminId ? adminId : null;
    }

    /**
     * 读取当前后台操作人角色。
     *
     * @param request 当前 HTTP 请求
     * @return {@link OperatorRole} 角色；未鉴权返回 {@code null}
     */
    public static OperatorRole currentRole(HttpServletRequest request) {
        Object value = request.getAttribute(ADMIN_ROLE_ATTRIBUTE);
        return value instanceof OperatorRole role ? role : null;
    }
}
