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
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.web.AuthContext;
import org.junit.jupiter.api.Test;
import org.springframework.mock.web.MockHttpServletRequest;

/**
 * {@link ChatController} 入口测试（V30 / 计划 U2）。
 *
 * <p>只守两条入口纪律：未登录一律 {@code 40101}（不进入业务，也不消耗额度），
 * 登录后把用户 ID 与请求原样交给 service。</p>
 */
class ChatControllerTest {

    /** 测试用登录用户 ID。 */
    private static final Long USER_ID = 42L;

    /** 测试用帖子 ID。 */
    private static final Long POST_ID = 1001L;

    private final ChatService chatService = mock(ChatService.class);
    private final ChatController controller = new ChatController(chatService);

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
}
