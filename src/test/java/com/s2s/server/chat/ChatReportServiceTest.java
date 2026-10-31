package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.chat.dto.ConversationBody;
import com.s2s.server.chat.dto.ConversationReportRequest;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.ContactService;
import com.s2s.server.contact.ReportReason;
import com.s2s.server.contact.dto.ReportResult;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link ChatReportService} 单元测试（V30 / 计划 U7）。
 *
 * <p>覆盖计划 U7 的 Test scenarios：发起人举报发布者、发布者举报发起人、下架帖仍可举报
 * （本类不做可见性判定）、误拦反馈带原文摘要、非成员拒绝，以及后台复核取正文的正序口径。</p>
 */
class ChatReportServiceTest {

    /** 会话发起人。 */
    private static final Long INITIATOR_ID = 11L;

    /** 帖子发布者。 */
    private static final Long OWNER_ID = 22L;

    /** 会话 ID。 */
    private static final Long CONVERSATION_ID = 900L;

    /** 帖子 ID。 */
    private static final Long POST_ID = 3001L;

    private final ConversationMapper conversationMapper = mock(ConversationMapper.class);
    private final ConversationMemberMapper memberMapper = mock(ConversationMemberMapper.class);
    private final MessageMapper messageMapper = mock(MessageMapper.class);
    private final ContactService contactService = mock(ContactService.class);

    private ChatReportService service;

    /**
     * 每个用例前装配服务：默认双方均为会话成员。
     */
    @BeforeEach
    void setUp() {
        service = new ChatReportService(conversationMapper, memberMapper, messageMapper,
                contactService);
        when(memberMapper.selectMember(CONVERSATION_ID, INITIATOR_ID))
                .thenReturn(new ConversationMemberEntity());
        when(memberMapper.selectMember(CONVERSATION_ID, OWNER_ID))
                .thenReturn(new ConversationMemberEntity());
        when(contactService.reportInConversation(any(), any(), any(), any(), any(), any()))
                .thenReturn(new ReportResult(77L, "pending"));
    }

    /**
     * 发起人举报发布者：被举报人取对方成员（发布者），帖子取会话锚点。
     *
     * @return void；断言失败即被举报人可能是举报人自己
     */
    @Test
    void initiatorReportsOwner() {
        when(conversationMapper.selectById(CONVERSATION_ID)).thenReturn(conversation());

        ReportResult result = service.report(INITIATOR_ID, CONVERSATION_ID,
                new ConversationReportRequest("harassment", "骚扰", null, null));

        assertThat(result.reportId()).isEqualTo(77L);
        verify(contactService).reportInConversation(INITIATOR_ID, POST_ID, OWNER_ID,
                "harassment", "骚扰", null);
    }

    /**
     * 发布者举报发起人：被举报人是发起人，而不是帖子作者本人。
     *
     * @return void；断言失败即发布者举报后落库对象错成自己
     */
    @Test
    void ownerReportsInitiator() {
        when(conversationMapper.selectById(CONVERSATION_ID)).thenReturn(conversation());

        service.report(OWNER_ID, CONVERSATION_ID,
                new ConversationReportRequest("fraud", null, List.of("m1"), null));

        verify(contactService).reportInConversation(OWNER_ID, POST_ID, INITIATOR_ID,
                "fraud", null, List.of("m1"));
    }

    /**
     * 误拦反馈：原因取新增值，描述里带上被拦原文摘要（R28）。
     *
     * @return void；断言失败即后台复核时看不到被拦的是什么内容
     */
    @Test
    void misblockCarriesBlockedTextInDescription() {
        when(conversationMapper.selectById(CONVERSATION_ID)).thenReturn(conversation());

        service.report(INITIATOR_ID, CONVERSATION_ID,
                new ConversationReportRequest(ReportReason.MISBLOCK.dbValue(), "正常询问房源",
                        null, "这房子还在吗"));

        ArgumentCaptor<String> description = ArgumentCaptor.forClass(String.class);
        verify(contactService).reportInConversation(any(), any(), any(),
                any(), description.capture(), any());
        assertThat(description.getValue())
                .contains("正常询问房源")
                .contains("这房子还在吗");
    }

    /**
     * 非成员举报 → 40305（与「会话不存在」同一响应），且不触达 contact 域。
     *
     * @return void；断言失败即第三方可对他人会话提交举报
     */
    @Test
    void nonMemberRejected() {
        Long outsider = 99L;

        assertThatThrownBy(() -> service.report(outsider, CONVERSATION_ID,
                new ConversationReportRequest("harassment", null, null, null)))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.CONVERSATION_NOT_FOUND);
                });
        verify(contactService, never()).reportInConversation(any(), any(), any(), any(), any(), any());
    }

    /**
     * 原因非法 → 40001（落库前拦住，避免 ENUM 约束变成 50001）。
     *
     * @return void
     */
    @Test
    void invalidReasonRejected() {
        when(conversationMapper.selectById(CONVERSATION_ID)).thenReturn(conversation());

        assertThatThrownBy(() -> service.report(INITIATOR_ID, CONVERSATION_ID,
                new ConversationReportRequest("not_a_reason", null, null, null)))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(contactService, never()).reportInConversation(any(), any(), any(), any(), any(), any());
    }

    /**
     * 后台复核：按举报双方定位会话，消息翻成正序返回。
     *
     * @return void；断言失败即复核看到的正文顺序与双方阅读顺序相反
     */
    @Test
    void bodyForReportReturnsMessagesInAscendingSeq() {
        when(conversationMapper.selectOne(any())).thenReturn(conversation());
        when(messageMapper.selectRecentByConversation(CONVERSATION_ID,
                ChatLimits.MESSAGE_PAGE_MAX_SIZE))
                .thenReturn(List.of(message(2, "第二条"), message(1, "第一条")));

        ConversationBody body = service.bodyForReport(POST_ID, INITIATOR_ID, OWNER_ID);

        assertThat(body.conversationId()).isEqualTo(CONVERSATION_ID);
        assertThat(body.messages()).extracting(item -> item.seq()).containsExactly(1, 2);
    }

    /**
     * 举报双方之间没有会话 → 41001（帖子下架不影响已有会话，此路径只处理「从未聊过」）。
     *
     * @return void
     */
    @Test
    void bodyForReportWithoutConversationIsGone() {
        when(conversationMapper.selectOne(any())).thenReturn(null);

        assertThatThrownBy(() -> service.bodyForReport(POST_ID, INITIATOR_ID, OWNER_ID))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(messageMapper, never()).selectRecentByConversation(anyLong(), anyInt());
    }

    /**
     * 构造测试会话。
     *
     * @return {@link ConversationEntity} 发起人 11 / 发布者 22 / 帖子 3001
     */
    private ConversationEntity conversation() {
        ConversationEntity conversation = new ConversationEntity();
        conversation.setId(CONVERSATION_ID);
        conversation.setPostId(POST_ID);
        conversation.setInitiatorId(INITIATOR_ID);
        conversation.setOwnerId(OWNER_ID);
        return conversation;
    }

    /**
     * 构造测试消息。
     *
     * @param seq     会话内序号
     * @param content 正文
     * @return {@link MessageEntity} 测试消息
     */
    private MessageEntity message(int seq, String content) {
        MessageEntity message = new MessageEntity();
        message.setId((long) seq);
        message.setConversationId(CONVERSATION_ID);
        message.setSeq(seq);
        message.setSenderId(INITIATOR_ID);
        message.setType("text");
        message.setContent(content);
        message.setCreatedAt(LocalDateTime.of(2026, 10, 31, 10, seq));
        return message;
    }
}
