package com.s2s.server.realtime;

import com.s2s.server.common.constants.RealtimeLimits;
import java.io.IOException;
import java.util.Deque;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedDeque;
import java.util.concurrent.atomic.AtomicInteger;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;

/**
 * 本机连接表（<b>实例内状态</b>，不跨进程共享）。
 *
 * <p>为什么不做全局路由表：全局表需要「实例 → 连接」映射与实例宕机清理，代价和故障面
 * 都更大。这里让每个实例只认识自己的连接，跨实例由 Redis 总线 fan-out 兜住——
 * 代价是每条事件广播 N 份（N＝实例数），收益是<b>没有粘性会话、扩容即加副本</b>。</p>
 *
 * <p>并发纪律：
 * <ul>
 *   <li>同一用户的连接集合用 {@link ConcurrentLinkedDeque}，注册/摘除在 deque 锁内完成；</li>
 *   <li>发送走 {@link ConcurrentWebSocketSessionDecorator}——同一个 session 不允许并发写，
 *       且超过发送时长/缓冲上限即断开，避免一个弱网客户端把投递线程拖死；</li>
 *   <li>投递失败只摘除该连接，不抛出——总线回调线程上任何异常都不该影响其它用户。</li>
 * </ul></p>
 */
@Component
public class RealtimeSessionRegistry {

    /** 日志（不打印 token / 正文，只打用户与连接数）。 */
    private static final Logger log = LoggerFactory.getLogger(RealtimeSessionRegistry.class);

    /** 会话属性键：并发装饰器（心跳应答与推送共用同一把写锁，避免并发写同一 session）。 */
    private static final String GUARDED_ATTRIBUTE = "RT_GUARDED_SESSION";

    /** user_id → 本机连接队列（队首最旧，用于超限时踢旧）。 */
    private final Map<Long, Deque<WebSocketSession>> sessions = new ConcurrentHashMap<>();

    /** 本机连接总数（避免每次遍历统计）。 */
    private final AtomicInteger total = new AtomicInteger();

    /**
     * 注册一条新连接。
     *
     * <p>实例已满则关闭该连接并返回 {@code false}；同一用户超过
     * {@link RealtimeLimits#MAX_SESSIONS_PER_USER} 时踢掉最早建立的连接（多端替换）。</p>
     *
     * @param userId  已通过握手鉴权的用户 ID
     * @param session 容器创建的原始会话
     * @return boolean {@code true} 已登记；{@code false} 因实例满被拒绝
     */
    public boolean register(Long userId, WebSocketSession session) {
        if (total.get() >= RealtimeLimits.MAX_SESSIONS_PER_INSTANCE) {
            closeQuietly(session, RealtimeLimits.CLOSE_INSTANCE_FULL);
            log.warn("实时连接被拒：实例连接数已达上限 {}（user={}）",
                    RealtimeLimits.MAX_SESSIONS_PER_INSTANCE, userId);
            return false;
        }
        WebSocketSession guarded = new ConcurrentWebSocketSessionDecorator(session,
                (int) RealtimeLimits.SEND_TIME_LIMIT_MILLIS,
                RealtimeLimits.SEND_BUFFER_LIMIT_BYTES);
        // 回填到会话属性：心跳应答等 handler 侧发送也走同一把写锁
        session.getAttributes().put(GUARDED_ATTRIBUTE, guarded);
        Deque<WebSocketSession> deque =
                sessions.computeIfAbsent(userId, key -> new ConcurrentLinkedDeque<>());
        synchronized (deque) {
            while (deque.size() >= RealtimeLimits.MAX_SESSIONS_PER_USER) {
                WebSocketSession oldest = deque.pollFirst();
                if (oldest != null) {
                    // 替换旧端：先从表里摘除并递减，新连接随后等量加回，总数不变
                    total.decrementAndGet();
                    closeQuietly(oldest, RealtimeLimits.CLOSE_SESSION_REPLACED);
                }
            }
            deque.addLast(guarded);
        }
        total.incrementAndGet();
        return true;
    }

    /**
     * 按会话 ID 摘除连接（容器关闭回调与发送失败清理共用）。
     *
     * <p>按 ID 匹配而非引用匹配：登记时存的是并发装饰器，容器回调给的是原始会话对象，
     * 两者引用不同但 ID 相同。</p>
     *
     * @param userId    用户 ID
     * @param sessionId 会话 ID（{@link WebSocketSession#getId()}）
     */
    public void remove(Long userId, String sessionId) {
        Deque<WebSocketSession> deque = sessions.get(userId);
        if (deque == null) {
            return;
        }
        synchronized (deque) {
            WebSocketSession matched = null;
            for (WebSocketSession session : deque) {
                if (session.getId().equals(sessionId)) {
                    matched = session;
                    break;
                }
            }
            if (matched != null && deque.remove(matched)) {
                total.decrementAndGet();
            }
        }
        if (deque.isEmpty()) {
            sessions.remove(userId, deque);
        }
    }

    /**
     * 向该用户在本机的全部连接投递一条文本帧。
     *
     * <p>调用方是 Redis 订阅线程：本方法<b>只做内存操作与发送</b>，不查库、不做同步 IO，
     * 保证一条慢连接不会阻塞总线消费。</p>
     *
     * @param userId  接收方 user_id
     * @param payload 已序列化的客户端载荷
     */
    public void sendToUser(Long userId, String payload) {
        Deque<WebSocketSession> deque = sessions.get(userId);
        if (deque == null || deque.isEmpty()) {
            // 本机没有该用户：正常情况（用户连在别的实例），不做任何补偿
            return;
        }
        for (WebSocketSession session : deque) {
            if (!session.isOpen()) {
                remove(userId, session.getId());
                continue;
            }
            try {
                session.sendMessage(new TextMessage(payload));
            } catch (IOException | IllegalStateException e) {
                // 发送失败/超时：摘除该连接即可，等价于客户端需要重连补齐
                log.debug("实时投递失败，摘除连接 user={} session={}", userId, session.getId());
                remove(userId, session.getId());
                closeQuietly(session, CloseStatus.SERVER_ERROR.getCode());
            }
        }
    }

    /**
     * 向单条会话发送文本帧（心跳应答等 handler 侧发送）。
     *
     * <p>复用注册时创建的并发装饰器：同一 session 上的心跳应答与总线投递必须串行写，
     * 否则 Tomcat 会抛「remote endpoint in state」类并发写异常。</p>
     *
     * @param session 容器回调给 handler 的原始会话
     * @param payload 待发送文本
     */
    public void sendText(WebSocketSession session, String payload) {
        Object guarded = session.getAttributes().get(GUARDED_ATTRIBUTE);
        WebSocketSession target = guarded instanceof WebSocketSession value ? value : session;
        try {
            if (target.isOpen()) {
                target.sendMessage(new TextMessage(payload));
            }
        } catch (IOException | IllegalStateException e) {
            log.debug("实时帧发送失败 session={}", session.getId());
            closeQuietly(target, CloseStatus.SERVER_ERROR.getCode());
        }
    }

    /**
     * 本机当前连接数（观测与测试用）。
     *
     * @return int 连接总数
     */
    public int connectionCount() {
        return total.get();
    }

    /**
     * 静默关闭连接：关闭本身失败不影响调用方。
     *
     * @param session 目标会话
     * @param code    WebSocket 关闭码
     */
    private void closeQuietly(WebSocketSession session, int code) {
        try {
            if (session.isOpen()) {
                session.close(new CloseStatus(code, "realtime"));
            }
        } catch (IOException | RuntimeException e) {
            log.debug("关闭实时连接失败 session={}", session.getId());
        }
    }
}
