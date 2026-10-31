package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.chat.dto.UnreadSummaryResponse;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.notify.NotifyService;
import java.time.LocalDateTime;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link UnreadSummaryService} 汇总口径测试（V30 / 计划 U5）。
 *
 * <p>覆盖计划 U5 的 Test scenarios：两项相加等于总数、服务号只读通知未读、
 * 无数据时三个零值，以及隐藏窗口作为会话未读的查询下界（R5 / KTD8）。</p>
 */
class UnreadSummaryServiceTest {

    /** 当前登录用户。 */
    private static final Long USER_ID = 11L;

    private final MessageMapper messageMapper = mock(MessageMapper.class);
    private final NotifyService notifyService = mock(NotifyService.class);
    private final UnreadSummaryService service =
            new UnreadSummaryService(messageMapper, notifyService);

    /**
     * 总数 = 会话未读 + 通知未读，且两个分项原样下发。
     *
     * @return void；断言失败即三处角标可能各自求和得到不同数字
     */
    @Test
    void totalIsSumOfBothSources() {
        when(messageMapper.countUnreadForUser(eq(USER_ID), any())).thenReturn(4L);
        when(notifyService.countUnread(USER_ID)).thenReturn(6L);

        UnreadSummaryResponse response = service.summary(USER_ID);

        assertThat(response.conversationUnread()).isEqualTo(4L);
        assertThat(response.notificationUnread()).isEqualTo(6L);
        assertThat(response.total()).isEqualTo(10L);
    }

    /**
     * 无任何会话与通知：三个零值，而不是 null 或缺失字段。
     *
     * @return void；断言失败即空态前端可能渲染出「null+」这类角标
     */
    @Test
    void returnsZerosWhenNothingUnread() {
        when(messageMapper.countUnreadForUser(eq(USER_ID), any())).thenReturn(0L);
        when(notifyService.countUnread(USER_ID)).thenReturn(0L);

        UnreadSummaryResponse response = service.summary(USER_ID);

        assertThat(response.total()).isZero();
        assertThat(response.conversationUnread()).isZero();
        assertThat(response.notificationUnread()).isZero();
    }

    /**
     * 会话未读以 90 天隐藏为下界：列表看不到的会话不点亮角标。
     *
     * @return void；断言失败即隐藏会话留下无法消除的红点
     */
    @Test
    void excludesHiddenConversationsByLowerBound() {
        when(messageMapper.countUnreadForUser(eq(USER_ID), any())).thenReturn(2L);
        when(notifyService.countUnread(USER_ID)).thenReturn(0L);

        service.summary(USER_ID);

        ArgumentCaptor<LocalDateTime> captor = ArgumentCaptor.forClass(LocalDateTime.class);
        verify(messageMapper).countUnreadForUser(eq(USER_ID), captor.capture());
        LocalDateTime expected = LocalDateTime.now()
                .minusDays(ChatLimits.CONVERSATION_HIDE_AFTER_DAYS);
        assertThat(captor.getValue()).isBetween(expected.minusMinutes(1), expected.plusMinutes(1));
    }
}
