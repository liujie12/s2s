package com.s2s.server.realtime;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.constants.RealtimeLimits;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.ApplicationEventPublisher;
import org.springframework.data.redis.core.StringRedisTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.event.TransactionPhase;
import org.springframework.transaction.event.TransactionalEventListener;

/**
 * 实时事件发布方（写 Redis 总线）。
 *
 * <p><b>提交后才发</b>：业务方在事务内只调 {@link #publishMessageNew}，真正写总线发生在
 * {@code AFTER_COMMIT}。这样事务回滚时不会把「不存在的消息」推给客户端——长连接比 HTTP
 * 更难撤回，宁可晚几毫秒。</p>
 *
 * <p><b>失败不抛</b>：总线不可用时只记 WARN（消息已落库，客户端可通过 HTTP 拉取补齐），
 * 绝不因为实时旁路把发送接口打成 500。这是与 R14a「前台拉取兜底」一致的降级口径。</p>
 */
@Service
public class RealtimePublisher {

    /** 日志：只记会话与用户，不记正文（安全红线）。 */
    private static final Logger log = LoggerFactory.getLogger(RealtimePublisher.class);

    /** Spring 事件总线（事务同步用）。 */
    private final ApplicationEventPublisher eventPublisher;

    /** Redis 客户端（发布订阅的写端）。 */
    private final StringRedisTemplate redisTemplate;

    /** JSON 序列化（与 HTTP 响应共用同一 ObjectMapper 配置）。 */
    private final ObjectMapper objectMapper;

    /**
     * 构造发布方。
     *
     * @param eventPublisher Spring 事件总线
     * @param redisTemplate  Redis 客户端
     * @param objectMapper   JSON 序列化器
     */
    public RealtimePublisher(ApplicationEventPublisher eventPublisher,
            StringRedisTemplate redisTemplate, ObjectMapper objectMapper) {
        this.eventPublisher = eventPublisher;
        this.redisTemplate = redisTemplate;
        this.objectMapper = objectMapper;
    }

    /**
     * 声明「会话里产生了新消息」，实际写总线在事务提交后。
     *
     * <p>必须在业务事务内调用；无事务时（如单测直调）由
     * {@code fallbackExecution = true} 立即执行，行为等价。</p>
     *
     * @param receiverId     接收方 user_id
     * @param conversationId 会话 ID
     * @param seq            新消息序号
     * @param senderId       发送方 user_id
     */
    public void publishMessageNew(Long receiverId, Long conversationId, int seq, Long senderId) {
        eventPublisher.publishEvent(new RealtimeEvent(RealtimeLimits.EVENT_MESSAGE_NEW,
                receiverId, conversationId, seq, senderId, null));
    }

    /**
     * 声明「对方已把会话读到某个水位」，实际写总线在事务提交后。
     *
     * <p>用于把发送方气泡上的「未读」实时改为「已读」。水位只增不减，客户端也会去重。</p>
     *
     * @param receiverId     接收方 user_id（会话消息的发送方）
     * @param conversationId 会话 ID
     * @param readSeq        已读水位
     */
    public void publishConversationRead(Long receiverId, Long conversationId, int readSeq) {
        eventPublisher.publishEvent(new RealtimeEvent(RealtimeLimits.EVENT_CONVERSATION_READ,
                receiverId, conversationId, null, null, readSeq));
    }

    /**
     * 事务提交后把事件写到 Redis 总线。
     *
     * @param event 已提交事务对应的实时事件
     */
    @TransactionalEventListener(phase = TransactionPhase.AFTER_COMMIT, fallbackExecution = true)
    public void onCommitted(RealtimeEvent event) {
        try {
            redisTemplate.convertAndSend(RealtimeLimits.MESSAGE_CHANNEL,
                    objectMapper.writeValueAsString(event));
        } catch (JsonProcessingException e) {
            log.warn("实时事件序列化失败，跳过本次广播 conversation={}", event.conversationId());
        } catch (RuntimeException e) {
            // Redis 不可用：实时旁路降级，客户端靠重连/回前台拉取补齐
            log.warn("实时事件广播失败（总线不可用），conversation={} err={}",
                    event.conversationId(), e.getClass().getSimpleName());
        }
    }
}
