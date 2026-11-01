package com.s2s.server.realtime;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.constants.RealtimeLimits;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.data.redis.connection.Message;
import org.springframework.data.redis.connection.MessageListener;
import org.springframework.stereotype.Component;

/**
 * 实时事件订阅方（读 Redis 总线 → 只投本机连接）。
 *
 * <p><b>线程纪律是本类的核心约束</b>：{@code onMessage} 运行在 Redis 监听线程上，
 * 一旦阻塞（查库、同步 HTTP、锁等待）就会拖住整个实例的总线消费，所有用户一起变慢。
 * 因此这里只做「反序列化 + 本机 map 查找 + send」，不碰任何 IO 与业务 service。</p>
 *
 * <p>本机没有该用户的连接属于<b>正常情况</b>（用户连在别的实例），直接丢弃，
 * 不做任何补偿——补偿由客户端重连后的 HTTP 增量拉取完成。</p>
 */
@Component
public class RealtimeSubscriber implements MessageListener {

    /** 日志。 */
    private static final Logger log = LoggerFactory.getLogger(RealtimeSubscriber.class);

    /** 本机连接表。 */
    private final RealtimeSessionRegistry registry;

    /** JSON 序列化器。 */
    private final ObjectMapper objectMapper;

    /**
     * 构造订阅方。
     *
     * @param registry     本机连接表
     * @param objectMapper JSON 序列化器
     */
    public RealtimeSubscriber(RealtimeSessionRegistry registry, ObjectMapper objectMapper) {
        this.registry = registry;
        this.objectMapper = objectMapper;
    }

    /**
     * 收到一条总线事件：解析后投递给本机该用户的连接。
     *
     * @param message Redis 消息（UTF-8 JSON）
     * @param pattern 订阅模式（频道订阅时为 null）
     */
    @Override
    public void onMessage(Message message, byte[] pattern) {
        try {
            RealtimeEvent event = objectMapper.readValue(message.getBody(), RealtimeEvent.class);
            if (!RealtimeLimits.EVENT_MESSAGE_NEW.equals(event.type())
                    || event.userId() == null) {
                return;
            }
            RealtimeClientPayload payload = new RealtimeClientPayload(event.type(),
                    event.conversationId(), event.seq());
            registry.sendToUser(event.userId(), objectMapper.writeValueAsString(payload));
        } catch (Exception e) {
            // 单条脏数据不能打断订阅：记 WARN 后继续消费下一条
            log.warn("实时事件解析失败，已丢弃 err={}", e.getClass().getSimpleName());
        }
    }
}
