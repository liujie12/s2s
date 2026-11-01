package com.s2s.server.realtime;

import com.s2s.server.auth.JwtVerifier;
import com.s2s.server.common.error.BizException;
import java.util.Map;
import org.springframework.http.HttpStatus;
import org.springframework.http.server.ServerHttpRequest;
import org.springframework.http.server.ServerHttpResponse;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.WebSocketHandler;
import org.springframework.web.socket.server.HandshakeInterceptor;

/**
 * WebSocket 握手鉴权。
 *
 * <p><b>为什么不复用 {@code AuthInterceptor}</b>：Spring MVC 拦截器只作用于
 * {@code HandlerMethod}，WebSocket 升级请求由 {@code WebSocketHandlerMapping} 处理，
 * 根本不会进入 MVC 拦截器链。若不在握手段判身份，任何拿到地址的人都能连上并收自己的
 * 消息（虽然收不到别人的，但会白占连接与配额）。</p>
 *
 * <p>判定口径与 HTTP 完全一致：{@code Authorization: Bearer <token>}，交给
 * {@link JwtVerifier}（含黑名单），失败一律 401——<b>不区分「没带 token」与「token
 * 无效」</b>，避免把实现细节回显给客户端。</p>
 *
 * <p>连接建立后的 token 过期不再校验（长连接不重复查 Redis 黑名单），由
 * 「客户端重连时重新握手 + 登出/封禁走主动断开」兜住。</p>
 */
@Component
public class RealtimeHandshakeInterceptor implements HandshakeInterceptor {

    /** 握手通过后写入 attributes 的用户 ID 键（本类唯一读写）。 */
    static final String USER_ID_ATTRIBUTE = "RT_USER_ID";

    /** Authorization 头名（与 HTTP 链同一口径）。 */
    private static final String AUTHORIZATION_HEADER = "Authorization";

    /** Bearer 前缀（含空格）。 */
    private static final String BEARER_PREFIX = "Bearer ";

    /** JWT 验签器（与 HTTP 链共用同一实例，黑名单口径天然一致）。 */
    private final JwtVerifier jwtVerifier;

    /**
     * 构造握手拦截器。
     *
     * @param jwtVerifier JWT 验签与黑名单查询组件
     */
    public RealtimeHandshakeInterceptor(JwtVerifier jwtVerifier) {
        this.jwtVerifier = jwtVerifier;
    }

    /**
     * 握手前校验 Bearer Token，通过则把 user_id 写入会话属性。
     *
     * @param request    升级请求（读 Authorization 头）
     * @param response   握手响应（失败时写 401）
     * @param wsHandler  目标处理器（未使用）
     * @param attributes 握手属性（通过时写入 user_id）
     * @return boolean {@code true} 允许升级；{@code false} 一律 401
     */
    @Override
    public boolean beforeHandshake(ServerHttpRequest request, ServerHttpResponse response,
            WebSocketHandler wsHandler, Map<String, Object> attributes) {
        String header = request.getHeaders().getFirst(AUTHORIZATION_HEADER);
        if (header == null || header.isBlank() || !header.startsWith(BEARER_PREFIX)) {
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return false;
        }
        String token = header.substring(BEARER_PREFIX.length()).trim();
        if (token.isEmpty()) {
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return false;
        }
        try {
            Long userId = jwtVerifier.verifyAndGetUserId(token);
            attributes.put(USER_ID_ATTRIBUTE, userId);
            return true;
        } catch (BizException e) {
            // 签名错 / 过期 / 黑名单命中 / Redis 故障：握手阶段统一 401，不外泄具体原因
            response.setStatusCode(HttpStatus.UNAUTHORIZED);
            return false;
        }
    }

    /**
     * 握手后回调（无需处理）。
     *
     * @param request    升级请求
     * @param response   握手响应
     * @param wsHandler  目标处理器
     * @param exception  握手异常（成功时为 null）
     */
    @Override
    public void afterHandshake(ServerHttpRequest request, ServerHttpResponse response,
            WebSocketHandler wsHandler, Exception exception) {
        // 无后置动作
    }

    /**
     * 从会话属性读取握手阶段写入的用户 ID。
     *
     * @param attributes 会话属性
     * @return {@link Long} user_id；缺失或类型不符时为 null
     */
    static Long userIdOf(Map<String, Object> attributes) {
        Object value = attributes.get(USER_ID_ATTRIBUTE);
        return value instanceof Long userId ? userId : null;
    }
}
