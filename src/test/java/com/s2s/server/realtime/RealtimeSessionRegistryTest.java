package com.s2s.server.realtime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.RealtimeLimits;
import java.util.HashMap;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;

/**
 * 本机连接表测试：登记、同用户踢旧、实例上限拒绝、投递与摘除。
 *
 * <p>这些用例守的是「并发与扩容」的两条底线：单用户连接不会无限增长、单实例连接
 * 不会无限增长；以及投递只发本机连接、摘除后计数归零（否则上限会提前触发）。</p>
 */
class RealtimeSessionRegistryTest {

    /** 被测对象（无外部依赖）。 */
    private final RealtimeSessionRegistry registry = new RealtimeSessionRegistry();

    /**
     * 正常登记后连接数加一，投递能把帧写到该连接。
     *
     * @return void；断言失败即投递链路断了
     */
    @Test
    void registersAndDelivers() throws Exception {
        WebSocketSession raw = session("s1");

        assertThat(registry.register(1L, raw)).isTrue();
        assertThat(registry.connectionCount()).isEqualTo(1);

        registry.sendToUser(1L, "{\"type\":\"message.new\"}");

        ArgumentCaptor<TextMessage> captor = ArgumentCaptor.forClass(TextMessage.class);
        verify(raw).sendMessage(captor.capture());
        assertThat(captor.getValue().getPayload()).isEqualTo("{\"type\":\"message.new\"}");
    }

    /**
     * 同一用户超过上限时踢掉最早建立的连接，总数不增长。
     *
     * @return void；断言失败即多端会把老端挤掉却没关闭，连接泄漏
     */
    @Test
    void evictsOldestSessionOfSameUser() throws Exception {
        WebSocketSession first = session("s1");
        registry.register(1L, first);
        for (int index = 2; index <= RealtimeLimits.MAX_SESSIONS_PER_USER; index++) {
            registry.register(1L, session("s" + index));
        }
        registry.register(1L, session("overflow"));

        assertThat(registry.connectionCount()).isEqualTo(RealtimeLimits.MAX_SESSIONS_PER_USER);
        ArgumentCaptor<CloseStatus> status = ArgumentCaptor.forClass(CloseStatus.class);
        verify(first).close(status.capture());
        assertThat(status.getValue().getCode())
                .isEqualTo(RealtimeLimits.CLOSE_SESSION_REPLACED);
    }

    /**
     * 实例连接数达到上限后拒绝新连接，并按实例满关闭码关闭。
     *
     * @return void；断言失败即单机可被长连接打满内存
     */
    @Test
    void rejectsWhenInstanceIsFull() throws Exception {
        for (int index = 0; index < RealtimeLimits.MAX_SESSIONS_PER_INSTANCE; index++) {
            registry.register((long) index, session("s" + index));
        }
        WebSocketSession rejected = session("overflow");

        assertThat(registry.register(999_999L, rejected)).isFalse();
        ArgumentCaptor<CloseStatus> status = ArgumentCaptor.forClass(CloseStatus.class);
        verify(rejected).close(status.capture());
        assertThat(status.getValue().getCode()).isEqualTo(RealtimeLimits.CLOSE_INSTANCE_FULL);
        assertThat(registry.connectionCount())
                .isEqualTo(RealtimeLimits.MAX_SESSIONS_PER_INSTANCE);
    }

    /**
     * 摘除后计数归零，且向无连接用户投递不抛异常。
     *
     * @return void；断言失败即计数器漂移或空投递抛错
     */
    @Test
    void removesAndIgnoresMissingUser() {
        WebSocketSession raw = session("s1");
        registry.register(1L, raw);

        registry.remove(1L, "s1");
        registry.sendToUser(1L, "{}");

        assertThat(registry.connectionCount()).isZero();
    }

    /**
     * 构造一个「已登录、可写」的会话替身。
     *
     * @param id 会话 ID
     * @return {@link WebSocketSession} 替身
     */
    private WebSocketSession session(String id) {
        WebSocketSession session = mock(WebSocketSession.class);
        when(session.getId()).thenReturn(id);
        when(session.isOpen()).thenReturn(true);
        Map<String, Object> attributes = new HashMap<>();
        when(session.getAttributes()).thenReturn(attributes);
        when(session.getUri()).thenReturn(null);
        return session;
    }
}
