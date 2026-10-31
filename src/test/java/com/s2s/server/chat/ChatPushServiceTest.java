package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.config.AdminConfigKeys;
import com.s2s.server.auth.SettingService;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.notify.PushDispatchResult;
import com.s2s.server.notify.PushDispatchService;
import com.s2s.server.notify.PushMessage;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link ChatPushService} 单元测试（V30 / 计划 U9）。
 *
 * <p>覆盖计划 U9 的 Test scenarios：首条推送一次、未读期间后续不推、关闭「消息通知」
 * 与总开关关闭时不推、载荷不含正文且带会话落点。</p>
 */
class ChatPushServiceTest {

    /** 接收者 user_id。 */
    private static final Long RECEIVER_ID = 22L;

    /** 会话 ID。 */
    private static final Long CONVERSATION_ID = 900L;

    private final SystemConfigService systemConfigService = mock(SystemConfigService.class);
    private final SettingService settingService = mock(SettingService.class);
    private final ConversationMemberMapper memberMapper = mock(ConversationMemberMapper.class);
    private final PushDispatchService pushDispatchService = mock(PushDispatchService.class);

    private ChatPushService service;

    /**
     * 每个用例前装配服务，默认：总开关开、消息通知开、抢到首条推送权。
     */
    @BeforeEach
    void setUp() {
        service = new ChatPushService(systemConfigService, settingService, memberMapper,
                pushDispatchService);
        when(systemConfigService.isOnOrAbsent(AdminConfigKeys.MESSAGE_ENABLED)).thenReturn(true);
        when(settingService.isMessageNotifyEnabled(RECEIVER_ID)).thenReturn(true);
        when(memberMapper.markPushed(CONVERSATION_ID, RECEIVER_ID)).thenReturn(1);
        when(pushDispatchService.pushOnly(anyLong(), any()))
                .thenReturn(new PushDispatchResult(false, true, 1, 1));
    }

    /**
     * 首条新消息：抢到标记后推送一次，载荷带会话落点且不含正文。
     *
     * @return void；断言失败即接收方收不到提醒或推送里出现正文
     */
    @Test
    void notifiesFirstUnreadMessageWithConversationLanding() {
        service.notifyNewMessage(RECEIVER_ID, CONVERSATION_ID);

        ArgumentCaptor<PushMessage> captor = ArgumentCaptor.forClass(PushMessage.class);
        verify(pushDispatchService).pushOnly(anyLong(), captor.capture());
        PushMessage message = captor.getValue();
        assertThat(message.targetId()).isEqualTo(CONVERSATION_ID);
        assertThat(message.landingType()).isEqualTo(PushMessage.LANDING_CONVERSATION);
        assertThat(message.title()).isEqualTo(ChatCopy.PUSH_TITLE);
        assertThat(message.summary()).isEqualTo(ChatCopy.PUSH_SUMMARY);
    }

    /**
     * 未读期间第二条：抢不到标记即不再推送（KTD7）。
     *
     * @return void；断言失败即同一会话未读期间被连续打扰
     */
    @Test
    void skipsWhenAlreadyPushedDuringUnread() {
        when(memberMapper.markPushed(CONVERSATION_ID, RECEIVER_ID)).thenReturn(0);

        service.notifyNewMessage(RECEIVER_ID, CONVERSATION_ID);

        verify(pushDispatchService, never()).pushOnly(anyLong(), any());
    }

    /**
     * 接收方关闭「消息通知」：不推送，也不占用「已推送」标记。
     *
     * @return void；断言失败即用户关闭后仍被推送
     */
    @Test
    void skipsWhenMessageNotifyDisabled() {
        when(settingService.isMessageNotifyEnabled(RECEIVER_ID)).thenReturn(false);

        service.notifyNewMessage(RECEIVER_ID, CONVERSATION_ID);

        verify(memberMapper, never()).markPushed(anyLong(), anyLong());
        verify(pushDispatchService, never()).pushOnly(anyLong(), any());
    }

    /**
     * 消息功能总开关关闭：不推送（存量只读，R30）。
     *
     * @return void
     */
    @Test
    void skipsWhenMessageSwitchOff() {
        when(systemConfigService.isOnOrAbsent(AdminConfigKeys.MESSAGE_ENABLED)).thenReturn(false);

        service.notifyNewMessage(RECEIVER_ID, CONVERSATION_ID);

        verify(memberMapper, never()).markPushed(anyLong(), anyLong());
        verify(pushDispatchService, never()).pushOnly(anyLong(), any());
    }
}
