package com.s2s.server.admin;

import com.s2s.server.auth.JwtVerifier;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * 后台鉴权拦截器（[153] B2-5）：仅拦 {@code /admin/**}（登录端点除外，见注册处）。
 *
 * <p>与 C 端 {@code AuthInterceptor} 的差异：**后台端点必须登录**（无 Token 一律 40101，
 * 不存在「游客态放行」——后台无匿名可访问面）；且只接受
 * {@code scope=admin} 的后台 Token（{@link JwtVerifier#verifyAdminToken(String)}）。</p>
 *
 * <p>通过后把「管理员 ID + 角色」写入 {@link AdminContext}，供 Controller/Service
 * 做 RBAC 判定（越权由服务层统一抛 {@code 40305}）。</p>
 */
@Component
public class AdminInterceptor implements HandlerInterceptor {

    /** Authorization 请求头名。 */
    private static final String AUTHORIZATION_HEADER = "Authorization";

    /** Bearer 前缀（含空格）。 */
    private static final String BEARER_PREFIX = "Bearer ";

    /** JWT 验签器（含后台 Token 变体与黑名单查询）。 */
    private final JwtVerifier jwtVerifier;

    /**
     * 构造后台鉴权拦截器。
     *
     * @param jwtVerifier JWT 验签与黑名单查询组件
     */
    public AdminInterceptor(JwtVerifier jwtVerifier) {
        this.jwtVerifier = jwtVerifier;
    }

    /**
     * preHandle：校验后台 Token，通过则写入 {@link AdminContext}。
     *
     * @param request  当前 HTTP 请求
     * @param response 当前 HTTP 响应（本拦截器不写响应）
     * @param handler  目标处理器（未使用）
     * @return boolean；恒 {@code true}（失败以异常终止）
     * @throws Exception 未登录 / Token 非法 → {@link BizException} 40101
     */
    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
            Object handler) throws Exception {
        String authHeader = request.getHeader(AUTHORIZATION_HEADER);
        if (authHeader == null || authHeader.isBlank() || !authHeader.startsWith(BEARER_PREFIX)) {
            // 后台无匿名面：缺头或非 Bearer 一律 40101
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        String token = authHeader.substring(BEARER_PREFIX.length());
        if (token.isBlank()) {
            throw BizException.of(ErrorCode.UNAUTHORIZED);
        }
        JwtVerifier.AdminPrincipal principal = jwtVerifier.verifyAdminToken(token);
        AdminContext.set(request, principal.adminId(), principal.role());
        return true;
    }
}
