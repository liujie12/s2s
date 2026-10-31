package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.chat.dto.ConversationCreateRequest;
import com.s2s.server.chat.dto.ConversationCreateResponse;
import com.s2s.server.chat.dto.MessageSendRequest;
import com.s2s.server.chat.dto.MessageSendResponse;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import java.time.Instant;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

/**
 * {@link ChatController} 入口测试（V30 / 计划 U2 / U3）。
 *
 * <p>只守入口纪律：未登录一律 {@code 40101}（不进入业务，也不消耗额度），
 * 登录后把用户 ID、路径参数与请求原样交给 service。</p>
 */
class ChatControllerTest {

    /** 测试用登录用户 ID。 */
    private static final Long USER_ID = 42L;

    /** 测试用帖子 ID。 */
    private static final Long POST_ID = 1001L;

    /** 测试用会话 ID。 */
    private static final Long CONVERSATION_ID = 900L;

    private final ChatService chatService = mock(ChatService.class);
    private final ChatMessageService chatMessageService = mock(ChatMessageService.class);
    private final ChatController controller =
            new ChatController(chatService, chatMessageService);

    /**
     * 未登录开会话 → {@code 40101}，且不触达 service。
     *
     * @return void；断言失败即游客可开会话（会话双方无从确定）
     */
    @Test
    void openConversationRequiresLogin() {
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThatThrownBy(() ->
                controller.openConversation(new ConversationCreateRequest(POST_ID), request))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
        verify(chatService, never()).openConversation(any(), any());
    }

    /**
     * 已登录 → 委托 service 并透传登录用户与帖子 ID。
     *
     * @return void；断言失败即会话发起人可能被请求体篡改
     */
    @Test
    void openConversationDelegatesWithLoginUser() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        AuthContext.setUserId(request, USER_ID);
        when(chatService.openConversation(eq(USER_ID), any()))
                .thenReturn(new ConversationCreateResponse(900L, true));

        ConversationCreateResponse response =
                controller.openConversation(new ConversationCreateRequest(POST_ID), request);

        assertThat(response.conversationId()).isEqualTo(900L);
        verify(chatService).openConversation(eq(USER_ID), any());
    }

    /**
     * 未登录发消息 → {@code 40101}，且不触达消息服务。
     *
     * @return void；断言失败即游客可向会话写入消息
     */
    @Test
    void sendMessageRequiresLogin() {
        MockHttpServletRequest request = new MockHttpServletRequest();

        assertThatThrownBy(() -> controller.sendMessage(CONVERSATION_ID,
                new MessageSendRequest("你好"), request))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.UNAUTHORIZED);
        verify(chatMessageService, never()).sendText(any(), any(), any());
    }

    /**
     * 已登录 → 透传登录用户、路径会话 ID 与正文。
     *
     * @return void；断言失败即发送者或被写会话可被请求体篡改
     */
    @Test
    void sendMessageDelegatesWithLoginUserAndPathId() {
        MockHttpServletRequest request = new MockHttpServletRequest();
        AuthContext.setUserId(request, USER_ID);
        MessageSendRequest body = new MessageSendRequest("你好");
        when(chatMessageService.sendText(eq(USER_ID), eq(CONVERSATION_ID), any()))
                .thenReturn(new MessageSendResponse(100L, CONVERSATION_ID, 1, Instant.now()));

        MessageSendResponse response = controller.sendMessage(CONVERSATION_ID, body, request);

        assertThat(response.seq()).isEqualTo(1);
        verify(chatMessageService).sendText(USER_ID, CONVERSATION_ID, body);
    }
}
