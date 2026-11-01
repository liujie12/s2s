package com.s2s.server.realtime;

import com.s2s.server.common.constants.RealtimeLimits;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.data.redis.listener.ChannelTopic;
import org.springframework.data.redis.listener.RedisMessageListenerContainer;

/**
 * 实时总线订阅装配。
 *
 * <p>为什么用 Pub/Sub 而不是 Redis Stream：实时事件是「加速器」，丢一条不丢消息
 * （客户端靠 {@code after_seq} 补齐），不需要消费组、ACK 与堆积清理；
 * 换来的是最短的投递延迟与最少的运维面。</p>
 *
 * <p>扩容路径：实例数增加时无需改任何代码——每个实例都订阅同一频道，收到后只投本机
 * 连接。规模再上一个量级时，可按 {@code user_id} 哈希分片到多个频道并让实例
 * 一致性哈希订阅，本类只需换 topic 计算方式。</p>
 */
@Configuration
public class RealtimeRedisConfig {

    /**
     * 总线监听容器：订阅实时事件频道并交给订阅方处理。
     *
     * @param connectionFactory Redis 连接工厂（Spring Boot 自动装配）
     * @param subscriber        事件订阅方
     * @return {@link RedisMessageListenerContainer} 由容器管理生命周期
     */
    @Bean
    public RedisMessageListenerContainer realtimeMessageListenerContainer(
            RedisConnectionFactory connectionFactory, RealtimeSubscriber subscriber) {
        RedisMessageListenerContainer container = new RedisMessageListenerContainer();
        container.setConnectionFactory(connectionFactory);
        container.addMessageListener(subscriber, new ChannelTopic(RealtimeLimits.MESSAGE_CHANNEL));
        return container;
    }
}
