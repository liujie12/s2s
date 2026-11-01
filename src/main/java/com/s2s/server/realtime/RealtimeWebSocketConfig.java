package com.s2s.server.realtime;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;

/**
 * 实时通道端点注册（{@code /ws}）。
 *
 * <p>路径取根路径而非 {@code /api/v1/ws}：生产实际调用链是「前端 baseUrl =
 * {@code https://<域名>}（不带 /api/v1）→ Caddy 纯反代 → Spring 根路径」，
 * 与既有 HTTP 接口完全一致。Caddy v2 对 WebSocket 升级自动透传，无需额外配置。</p>
 *
 * <p>不放行匿名：{@link RealtimeHandshakeInterceptor} 在升级阶段校验 Bearer Token，
 * 未通过直接 401，连接不会进入业务层。</p>
 */
@Configuration
@EnableWebSocket
public class RealtimeWebSocketConfig implements WebSocketConfigurer {

    /** 连接生命周期处理器。 */
    private final RealtimeWebSocketHandler handler;

    /** 握手鉴权拦截器。 */
    private final RealtimeHandshakeInterceptor handshakeInterceptor;

    /**
     * 构造端点注册配置。
     *
     * @param handler             连接生命周期处理器
     * @param handshakeInterceptor 握手鉴权拦截器
     */
    public RealtimeWebSocketConfig(RealtimeWebSocketHandler handler,
            RealtimeHandshakeInterceptor handshakeInterceptor) {
        this.handler = handler;
        this.handshakeInterceptor = handshakeInterceptor;
    }

    /**
     * 注册 {@code /ws} 端点与握手拦截器。
     *
     * <p>允许任意 Origin：客户端是移动端原生连接，不带 Origin；鉴权由 token 承担，
     * 不依赖浏览器同源策略（与 Servlet 侧的 CSRF 面无关）。</p>
     *
     * @param registry Spring WebSocket 注册器
     */
    @Override
    public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
        registry.addHandler(handler, "/ws")
                .addInterceptors(handshakeInterceptor)
                .setAllowedOriginPatterns("*");
    }
}
