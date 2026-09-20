package com.s2s.server.auth;

import com.s2s.server.common.web.AuthContext;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.servlet.HandlerInterceptor;

/**
 * 鉴权拦截器（[122] U3；详设 §3.1 横切链第二位；KTD3/KTD7）。
 *
 * <p>职责：解析 {@code Authorization: Bearer <token>} 头，调用 {@link JwtVerifier}
 * 验签并查黑名单，通过后把 userId 写入 {@link AuthContext}（请求属性 + MDC user_id）。
 *
 * <p>三条核心规则（详设 §3.1 鉴权段 + KTD3）：
 * <ol>
 *   <li><b>无 Authorization 头 → 放行，游客态</b>：上下文为空，后续限流/业务层据此
 *       判定是否为游客；不抛 401（未登录不是错）。</li>
 *   <li><b>带 Token 但无效 → 40101，不放行</b>：签名错、过期、黑名单命中全部归 40101，
 *       由 {@link JwtVerifier} 内部抛 {@code BizException(UNAUTHORIZED)}，
 *       异常直接上抛由 GlobalExceptionHandler 统一映射。</li>
 *   <li><b>Redis 黑名单查询故障 → 50001</b>：绝不降级放行（KTD7 红线）；
 *       JwtVerifier 内部已转 {@code BizException(INTERNAL_ERROR)}，此处不二次处理。</li>
 * </ol>
 *
 * <p><b>KTD3：匿名接口带无效 Token 的处理</b>——本拦截器对所有路径生效（WebCrosscutConfig
 * 注册时不做路径排除），只要请求头带 Token 就尝试验证，验证失败即 40101，
 * 「是否是匿名接口」不影响鉴权判定结果——匿名接口是业务层语义，不是横切链语义
 * （详设 §3.1：Token 无效 = 请求身份无效，不管请求的是什么资源）。
 *
 * <p>链序位置：RequestIdFilter（已注入 request_id/MDC）之后、RateLimitInterceptor
 * 之前——鉴权结果是 42907（游客详情限流）的判定输入，必须先于限流。
 *
 * <p>本类仅做骨架：Token 签发/续期/登出不在本条目范围（随 [123] auth 业务落地），
 * 此处只做「验签 + 黑名单 + 上下文写入」三件事。
 */
@Component
public class AuthInterceptor implements HandlerInterceptor {

    /** Authorization 请求头名。 */
    private static final String AUTHORIZATION_HEADER = "Authorization";

    /** Bearer 前缀（含空格）。 */
    private static final String BEARER_PREFIX = "Bearer ";

    /** JWT 验签器（含黑名单查询，构造注入）。 */
    private final JwtVerifier jwtVerifier;

    /**
     * 构造鉴权拦截器，注入 JWT 验签器。
     *
     * @param jwtVerifier JWT 验签与黑名单查询组件
     */
    public AuthInterceptor(JwtVerifier jwtVerifier) {
        this.jwtVerifier = jwtVerifier;
    }

    /**
     * preHandle：解析 Authorization 头，验签查黑名单，通过则写入 AuthContext。
     *
     * <p>流程：
     * <ol>
     *   <li>读 Authorization 头，缺头 → {@code return true}（放行，游客态）；</li>
     *   <li>头不以 "Bearer " 开头 → 格式非法，40101（向上抛 BizException）；</li>
     *   <li>剥离前缀调 {@link JwtVerifier#verifyAndGetUserId(String)} 验签查黑名单；</li>
     *   <li>通过 → {@link AuthContext#setUserId(HttpServletRequest, Long)} 写入上下文；</li>
     *   <li>失败 → 异常已由 verifier 包装为 BizException，直接上抛。</li>
     * </ol>
     *
     * @param request  当前 HTTP 请求（头读取源、属性写入目标）
     * @param response 当前 HTTP 响应（本拦截器不写响应，异常路径由 handler 接管）
     * @param handler  目标处理器（未使用）
     * @return boolean；{@code true} 放行，{@code false} 终止（本拦截器用异常终止，不用 false）
     * @throws Exception 鉴权失败时抛 {@link com.s2s.server.common.error.BizException}
     *                   （40101 或 50001），由 GlobalExceptionHandler 统一映射
     */
    @Override
    public boolean preHandle(HttpServletRequest request, HttpServletResponse response,
            Object handler) throws Exception {
        String authHeader = request.getHeader(AUTHORIZATION_HEADER);
        if (authHeader == null || authHeader.isBlank()) {
            // 无 Token：游客态放行，上下文为空（AuthContext.currentUserId 返回 null）
            return true;
        }
        if (!authHeader.startsWith(BEARER_PREFIX)) {
            // 格式错：非 Bearer 方案，按无效 Token 处理（40101）
            throw com.s2s.server.common.error.BizException.of(
                    com.s2s.server.common.error.ErrorCode.UNAUTHORIZED);
        }
        String token = authHeader.substring(BEARER_PREFIX.length());
        if (token.isBlank()) {
            // Bearer 后为空，格式不合法
            throw com.s2s.server.common.error.BizException.of(
                    com.s2s.server.common.error.ErrorCode.UNAUTHORIZED);
        }
        Long userId = jwtVerifier.verifyAndGetUserId(token);
        AuthContext.setUserId(request, userId);
        return true;
    }
}
