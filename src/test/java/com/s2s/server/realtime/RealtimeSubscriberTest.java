package com.s2s.server.realtime;

import static java.nio.charset.StandardCharsets.UTF_8;
import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.data.redis.connection.Message;

/**
 * 总线订阅测试：正常事件投给目标用户、脏数据不打断消费、身份字段不出网关。
 */
class RealtimeSubscriberTest {

    /** 本机连接表替身。 */
    private final RealtimeSessionRegistry registry = mock(RealtimeSessionRegistry.class);

    /** 被测对象（真实 ObjectMapper，覆盖字段映射）。 */
    private final RealtimeSubscriber subscriber =
            new RealtimeSubscriber(registry, new ObjectMapper());

    /**
     * 正常事件：按 user_id 投递，载荷只含会话与序号。
     *
     * @return void；断言失败即路由错人或把身份字段下发到了客户端
     */
    @Test
    void deliversToTargetUserWithoutIdentityFields() {
        Message message = mock(Message.class);
        when(message.getBody()).thenReturn(("{\"type\":\"message.new\",\"userId\":7,"
                + "\"conversationId\":9,\"seq\":12,\"senderId\":8}").getBytes(UTF_8));

        subscriber.onMessage(message, null);

        ArgumentCaptor<String> payload = ArgumentCaptor.forClass(String.class);
        verify(registry).sendToUser(eq(7L), payload.capture());
        assertThat(payload.getValue())
                .contains("\"conversationId\":9")
                .contains("\"seq\":12")
                .doesNotContain("userId")
                .doesNotContain("senderId");
    }

    /**
     * 脏数据：只记日志，不影响后续消费，也不投递。
     *
     * @return void；断言失败即一条坏消息能让整个订阅线程异常退出
     */
    @Test
    void ignoresMalformedEvent() {
        Message message = mock(Message.class);
        when(message.getBody()).thenReturn("not-json".getBytes(UTF_8));

        subscriber.onMessage(message, null);

        verifyNoInteractions(registry);
    }
}
