package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.chat.dto.MessageSendRequest;
import com.s2s.server.chat.dto.MessageSendResponse;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.moderation.SensitiveWordChecker;
import com.s2s.server.contact.ContactChannel;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link ChatMessageService} 发送链路测试（V30 / 计划 U3）。
 *
 * <p>覆盖计划 U3 的 Test scenarios：未回复额度、回复后重置、敏感词拒发、维护态拒绝、
 * 首条写联系事件、非成员拒绝与摘要截断。「申请卡与联系方式卡不计入额度」是 SQL
 * 过滤语义，无测试库时用 {@link #unrepliedQuotaQueryCountsOnlyText()} 直读
 * {@code MessageMapper.xml} 守住；「同一幂等键只落一条」由幂等拦截器承载，
 * 服务层无重复写路径。</p>
 */
class ChatMessageServiceTest {

    /** 当前登录用户（发起人）。 */
    private static final Long USER_ID = 11L;

    /** 会话另一方（帖子发布者）。 */
    private static final Long OTHER_ID = 22L;

    /** 会话 ID。 */
    private static final Long CONVERSATION_ID = 900L;

    /** 帖子 ID。 */
    private static final Long POST_ID = 3001L;

    private final ChatService chatService = mock(ChatService.class);
    private final ConversationMapper conversationMapper = mock(ConversationMapper.class);
    private final ConversationMemberMapper memberMapper = mock(ConversationMemberMapper.class);
    private final MessageMapper messageMapper = mock(MessageMapper.class);
    private final ContactEventMapper contactEventMapper = mock(ContactEventMapper.class);
    private final SensitiveWordChecker sensitiveWordChecker = mock(SensitiveWordChecker.class);
    private final ChatMessageWriter messageWriter =
            new ChatMessageWriter(conversationMapper, messageMapper, contactEventMapper);
    private final ChatPushService chatPushService = mock(ChatPushService.class);

    private ChatMessageService messageService;

    /**
     * 每个用例前重建服务，默认：成员存在、行锁命中、未回复额度为 0。
     */
    @BeforeEach
    void setUp() {
        messageService = new ChatMessageService(chatService, conversationMapper, memberMapper,
                messageMapper, sensitiveWordChecker, messageWriter, chatPushService);
        when(memberMapper.selectMember(CONVERSATION_ID, USER_ID))
                .thenReturn(new ConversationMemberEntity());
        when(messageMapper.countUnrepliedText(CONVERSATION_ID, USER_ID)).thenReturn(0);
    }

    /**
     * 正常发送：序号在会话行锁内 +1，消息与会话尾部同步更新，非首条不写联系事件。
     *
     * @return void；断言失败即消息重号、列表摘要不更新或每次发送都写联系事件
     */
    @Test
    void sendsTextAndAdvancesSeq() {
        givenConversation(5);

        MessageSendResponse response =
                messageService.sendText(USER_ID, CONVERSATION_ID, new MessageSendRequest("你好"));

        assertThat(response.conversationId()).isEqualTo(CONVERSATION_ID);
        assertThat(response.seq()).isEqualTo(6);
        assertThat(response.messageId()).isEqualTo(100L);

        ArgumentCaptor<MessageEntity> messageCaptor = ArgumentCaptor.forClass(MessageEntity.class);
        verify(messageMapper).insert(messageCaptor.capture());
        assertThat(messageCaptor.getValue().getSeq()).isEqualTo(6);
        assertThat(messageCaptor.getValue().getSenderId()).isEqualTo(USER_ID);
        assertThat(messageCaptor.getValue().getType()).isEqualTo(MessageType.TEXT.dbValue());
        assertThat(messageCaptor.getValue().getContent()).isEqualTo("你好");

        ArgumentCaptor<ConversationEntity> patchCaptor =
                ArgumentCaptor.forClass(ConversationEntity.class);
        verify(conversationMapper).updateById(patchCaptor.capture());
        assertThat(patchCaptor.getValue().getLastSeq()).isEqualTo(6);
        assertThat(patchCaptor.getValue().getLastMessageType())
                .isEqualTo(MessageType.TEXT.dbValue());
        assertThat(patchCaptor.getValue().getLastMessagePreview()).isEqualTo("你好");

        verify(contactEventMapper, never()).insert(any(ContactEventEntity.class));
        // 推送只发给对方，且不在此处落站内通知（KTD6）
        verify(chatPushService).notifyNewMessage(OTHER_ID, CONVERSATION_ID);
    }

    /**
     * 对方回复后的计数为 0：额度放行，可以继续发送。
     *
     * @return void；断言失败即「对方回一句后我方仍被锁死」
     */
    @Test
    void allowsSendingWhenCounterResets() {
        givenConversation(8);
        when(messageMapper.countUnrepliedText(CONVERSATION_ID, USER_ID)).thenReturn(0);

        MessageSendResponse response =
                messageService.sendText(USER_ID, CONVERSATION_ID, new MessageSendRequest("在吗"));

        assertThat(response.seq()).isEqualTo(9);
    }

    /**
     * 未回复已达上限：拒发并返回等待文案，不写消息、不推进序号。
     *
     * @return void；断言失败即单方面连发可以无限刷屏
     */
    @Test
    void rejectsWhenUnrepliedQuotaReached() {
        when(messageMapper.countUnrepliedText(CONVERSATION_ID, USER_ID))
                .thenReturn(ChatLimits.UNREPLIED_TEXT_LIMIT);
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID))
                .thenReturn(conversation(5));

        assertThatThrownBy(() -> messageService.sendText(USER_ID, CONVERSATION_ID,
                new MessageSendRequest("再来一条")))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.UNREPLIED_LIMIT);
                });
        verify(messageMapper, never()).insert(any(MessageEntity.class));
        verify(conversationMapper, never()).updateById(any(ConversationEntity.class));
    }

    /**
     * 命中敏感词：返回 40901，消息不落库（正文原样留在客户端输入框）。
     *
     * @return void；断言失败即被拦正文已进库，无法向用户解释「没发出去」
     */
    @Test
    void rejectsSensitiveContentWithoutPersisting() {
        org.mockito.Mockito.doThrow(BizException.of(ErrorCode.SENSITIVE_WORD))
                .when(sensitiveWordChecker).check("违禁词");
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID))
                .thenReturn(conversation(5));

        assertThatThrownBy(() -> messageService.sendText(USER_ID, CONVERSATION_ID,
                new MessageSendRequest("违禁词")))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.SENSITIVE_WORD);
        verify(messageMapper, never()).insert(any(MessageEntity.class));
    }

    /**
     * 消息总开关关闭：拒发并返回维护文案，且不碰会话行（只读态不排他锁）。
     *
     * @return void；断言失败即维护态下仍能写入或读取路径被无谓加锁
     */
    @Test
    void rejectsWhenMessageSwitchOff() {
        org.mockito.Mockito.doThrow(BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.MAINTENANCE))
                .when(chatService).requireMessageEnabled();

        assertThatThrownBy(() -> messageService.sendText(USER_ID, CONVERSATION_ID,
                new MessageSendRequest("你好")))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.MAINTENANCE);
                });
        verify(memberMapper, never()).selectMember(any(), any());
        verify(conversationMapper, never()).selectByIdForUpdate(any());
    }

    /**
     * 非成员发送：与「会话不存在」同一响应，且不触发敏感词检测与行锁。
     *
     * @return void；断言失败即第三方可探测会话存在性或向其写入消息
     */
    @Test
    void rejectsNonMemberWithSameCopyAsMissingConversation() {
        when(memberMapper.selectMember(CONVERSATION_ID, USER_ID)).thenReturn(null);

        assertThatThrownBy(() -> messageService.sendText(USER_ID, CONVERSATION_ID,
                new MessageSendRequest("你好")))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.CONVERSATION_NOT_FOUND);
                });
        verify(sensitiveWordChecker, never()).check(any());
        verify(conversationMapper, never()).selectByIdForUpdate(any());
    }

    /**
     * 会话首条消息：写一条渠道为「会话」的联系事件，带会话 ID 与正确双方。
     *
     * @return void；断言失败即站内联系无法按渠道统计（R31 / 北极星辅助指标）
     */
    @Test
    void writesConversationContactEventForFirstMessage() {
        givenConversation(0);

        messageService.sendText(USER_ID, CONVERSATION_ID, new MessageSendRequest("第一条"));

        ArgumentCaptor<ContactEventEntity> captor =
                ArgumentCaptor.forClass(ContactEventEntity.class);
        verify(contactEventMapper).insert(captor.capture());
        ContactEventEntity event = captor.getValue();
        assertThat(event.getPostId()).isEqualTo(POST_ID);
        assertThat(event.getFromUserId()).isEqualTo(USER_ID);
        assertThat(event.getToUserId()).isEqualTo(OTHER_ID);
        assertThat(event.getConversationId()).isEqualTo(CONVERSATION_ID);
        assertThat(event.getChannelType()).isEqualTo(ContactChannel.CONVERSATION);
    }

    /**
     * 摘要按 {@link ChatLimits#LIST_PREVIEW_MAX_LENGTH} 截断，正文原样落库。
     *
     * @return void；断言失败即列表摘要顶破列宽（128）或正文被截断
     */
    @Test
    void truncatesPreviewButKeepsFullContent() {
        givenConversation(2);
        String content = "很".repeat(ChatLimits.LIST_PREVIEW_MAX_LENGTH) + "后面还有";

        messageService.sendText(USER_ID, CONVERSATION_ID, new MessageSendRequest(content));

        ArgumentCaptor<MessageEntity> messageCaptor = ArgumentCaptor.forClass(MessageEntity.class);
        verify(messageMapper).insert(messageCaptor.capture());
        assertThat(messageCaptor.getValue().getContent()).isEqualTo(content);

        ArgumentCaptor<ConversationEntity> patchCaptor =
                ArgumentCaptor.forClass(ConversationEntity.class);
        verify(conversationMapper).updateById(patchCaptor.capture());
        assertThat(patchCaptor.getValue().getLastMessagePreview())
                .hasSize(ChatLimits.LIST_PREVIEW_MAX_LENGTH);
    }

    /**
     * 未回复额度只数文本：SQL 必须带 {@code type = 'text'}，卡片不进计数。
     *
     * @return void；断言失败即一次申请 + 同意会占掉两条未回复额度
     * @throws IOException Mapper XML 不可读时抛出
     */
    @Test
    void unrepliedQuotaQueryCountsOnlyText() throws IOException {
        String xml = Files.readString(
                Path.of("src", "main", "resources", "mapper", "MessageMapper.xml"),
                StandardCharsets.UTF_8);

        assertThat(xml)
                .as("计数只统计 text，申请卡与联系方式卡不计入未回复额度（R26）")
                .contains("AND type = 'text'")
                .contains("countUnrepliedText");
    }

    /**
     * 准备一例会话说：按给定 {@code last_seq} 返回行锁结果，并让消息插入回填 ID。
     *
     * @param lastSeq 会话当前序号水位
     */
    private void givenConversation(int lastSeq) {
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID))
                .thenReturn(conversation(lastSeq));
        doAnswer(invocation -> {
            MessageEntity inserted = invocation.getArgument(0);
            inserted.setId(100L);
            return 1;
        }).when(messageMapper).insert(any(MessageEntity.class));
    }

    /**
     * 构造会话实体（含帖子与双方 ID，供联系事件取值）。
     *
     * @param lastSeq 会话当前序号水位
     * @return {@link ConversationEntity} 未加锁的测试数据
     */
    private ConversationEntity conversation(int lastSeq) {
        ConversationEntity conversation = new ConversationEntity();
        conversation.setId(CONVERSATION_ID);
        conversation.setPostId(POST_ID);
        conversation.setInitiatorId(USER_ID);
        conversation.setOwnerId(OTHER_ID);
        conversation.setLastSeq(lastSeq);
        return conversation;
    }
}
