package com.s2s.server.realtime;

import com.s2s.server.common.constants.RealtimeLimits;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.TextWebSocketHandler;

/**
 * 实时通道握手后的连接生命周期处理。
 *
 * <p>本类只做四件事：登记、心跳应答、摘除、异常摘除。<b>不承载业务</b>——
 * 消息产生由 {@link RealtimePublisher} 走总线，业务正文由客户端按 {@code seq}
 * 走 HTTP 增量拉取。这样长连接层不依赖 MyBatis / 业务 service，扩容与重启都无状态。</p>
 *
 * <p>协议极简：客户端每 25s 发文本帧 {@code ping}，服务端回 {@code pong}；
 * 其它任何帧（含超长帧）都不解读，超长直接按协议错误断开。</p>
 */
@Component
public class RealtimeWebSocketHandler extends TextWebSocketHandler {

    /** 日志（不打 token / 正文）。 */
    private static final Logger log = LoggerFactory.getLogger(RealtimeWebSocketHandler.class);

    /** 本机连接表。 */
    private final RealtimeSessionRegistry registry;

    /**
     * 构造处理器。
     *
     * @param registry 本机连接表
     */
    public RealtimeWebSocketHandler(RealtimeSessionRegistry registry) {
        this.registry = registry;
    }

    /**
     * 连接建立：取出握手阶段写入的 user_id 并登记。
     *
     * @param session 新建立的会话
     */
    @Override
    public void afterConnectionEstablished(WebSocketSession session) {
        Long userId = RealtimeHandshakeInterceptor.userIdOf(session.getAttributes());
        if (userId == null) {
            // 理论上握手已拦截；防御性关闭，避免匿名连接占位
            closeQuietly(session, RealtimeLimits.CLOSE_PROTOCOL_ERROR);
            return;
        }
        if (registry.register(userId, session)) {
            // 每次建连留一条 INFO：排查「客户端是否真的连上」时，这是最直接的证据
            log.info("实时连接建立 user={} 本机连接数={}", userId, registry.connectionCount());
        }
    }

    /**
     * 收到客户端文本帧：只应答心跳，其余忽略；超长帧直接断开。
     *
     * @param session 会话
     * @param message 文本帧
     */
    @Override
    protected void handleTextMessage(WebSocketSession session, TextMessage message) {
        String payload = message.getPayload();
        if (payload == null || payload.length() > RealtimeLimits.MAX_CLIENT_FRAME_CHARS) {
            closeQuietly(session, RealtimeLimits.CLOSE_PROTOCOL_ERROR);
            return;
        }
        if (RealtimeLimits.PING_FRAME.equals(payload.trim())) {
            registry.sendText(session, RealtimeLimits.PONG_FRAME);
        }
    }

    /**
     * 连接关闭：从本机表摘除。
     *
     * @param session     会话
     * @param closeStatus 关闭原因
     */
    @Override
    public void afterConnectionClosed(WebSocketSession session, CloseStatus closeStatus) {
        Long userId = RealtimeHandshakeInterceptor.userIdOf(session.getAttributes());
        if (userId != null) {
            registry.remove(userId, session.getId());
        }
        log.debug("实时连接关闭 user={} code={}", userId, closeStatus.getCode());
    }

    /**
     * 传输异常：摘除并关闭（容器随后也会回调 afterConnectionClosed，摘除是幂等的）。
     *
     * @param session   会话
     * @param exception 异常
     */
    @Override
    public void handleTransportError(WebSocketSession session, Throwable exception) {
        Long userId = RealtimeHandshakeInterceptor.userIdOf(session.getAttributes());
        if (userId != null) {
            registry.remove(userId, session.getId());
        }
        closeQuietly(session, CloseStatus.SERVER_ERROR.getCode());
    }

    /**
     * 静默关闭会话。
     *
     * @param session 会话
     * @param code    关闭码
     */
    private void closeQuietly(WebSocketSession session, int code) {
        try {
            if (session.isOpen()) {
                session.close(new CloseStatus(code, "realtime"));
            }
        } catch (Exception e) {
            log.debug("关闭会话失败 session={}", session.getId());
        }
    }
}
