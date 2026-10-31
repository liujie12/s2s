package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.chat.dto.ApplyDecisionRequest;
import com.s2s.server.chat.dto.ApplyStateResponse;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import com.s2s.server.post.PostService;
import com.s2s.server.post.dto.PostChatAnchor;
import java.time.LocalDateTime;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link ContactApplyService} 申请链路测试（V30 / 计划 U6）。
 *
 * <p>覆盖计划 U6 的 Test scenarios：首次申请写卡、被拒冷却、待审批重申、审批同意写
 * 联系方式卡并升级渠道、非发起人/非发布者拒绝、非成员拒绝，以及取号闸门的
 * {@link ContactApplyService#hasApprovedAccess(Long, Long)} 判定。</p>
 */
class ContactApplyServiceTest {

    /** 会话发起人（申请人）。 */
    private static final Long INITIATOR_ID = 11L;

    /** 帖子发布者（审批人）。 */
    private static final Long OWNER_ID = 22L;

    /** 会话 ID。 */
    private static final Long CONVERSATION_ID = 900L;

    /** 帖子 ID。 */
    private static final Long POST_ID = 3001L;

    private final ChatService chatService = mock(ChatService.class);
    private final ConversationMapper conversationMapper = mock(ConversationMapper.class);
    private final ConversationMemberMapper memberMapper = mock(ConversationMemberMapper.class);
    private final ChatMessageWriter messageWriter = mock(ChatMessageWriter.class);
    private final ContactEventMapper contactEventMapper = mock(ContactEventMapper.class);
    private final PostService postService = mock(PostService.class);

    private ContactApplyService service;

    /**
     * 每个用例前装配服务，默认：成员存在、帖子需申请、申请卡写入返回一条消息。
     */
    @BeforeEach
    void setUp() {
        service = new ContactApplyService(chatService, conversationMapper, memberMapper,
                messageWriter, contactEventMapper, postService);
        when(memberMapper.selectMember(CONVERSATION_ID, INITIATOR_ID))
                .thenReturn(new ConversationMemberEntity());
        when(memberMapper.selectMember(CONVERSATION_ID, OWNER_ID))
                .thenReturn(new ConversationMemberEntity());
        when(postService.chatAnchor(POST_ID))
                .thenReturn(new PostChatAnchor(POST_ID, OWNER_ID, "active", true));
        when(messageWriter.appendLocked(any(), any(), any(), any(), any()))
                .thenReturn(new MessageEntity());
    }

    /**
     * 首次申请：状态转待审批并写一张申请卡。
     *
     * @return void；断言失败即发布者收不到申请卡（会话里没有任何提示）
     */
    @Test
    void firstApplyWritesApplyCard() {
        ConversationEntity conversation = conversation(ApplyStatus.NONE, INITIATOR_ID, OWNER_ID, null);
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        ApplyStateResponse response = service.apply(INITIATOR_ID, CONVERSATION_ID);

        verify(messageWriter).appendLocked(conversation, INITIATOR_ID, MessageType.APPLY, null, null);
        assertThat(response.applyStatus()).isEqualTo(ApplyStatus.PENDING.dbValue());
        assertThat(response.applyRequired()).isTrue();
        assertThat(response.canApply()).isFalse();
        assertThat(response.reapplyAt()).isNotNull();
    }

    /**
     * 待审批未满重申窗口：拒绝再次提交，不写第二张卡。
     *
     * @return void；断言失败即同一会话会出现多张申请卡
     */
    @Test
    void rejectsReapplyWhilePendingWindowOpen() {
        ConversationEntity conversation = conversation(ApplyStatus.PENDING, INITIATOR_ID, OWNER_ID,
                LocalDateTime.now().minusHours(1));
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        assertThatThrownBy(() -> service.apply(INITIATOR_ID, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(messageWriter, never()).appendLocked(any(), any(), any(), any(), any());
    }

    /**
     * 待审批超过重申窗口：允许再提交一次，复用同一张卡。
     *
     * @return void；断言失败即挂着无人处理的申请永远无法推进
     */
    @Test
    void allowsReapplyAfterPendingWindow() {
        ConversationEntity conversation = conversation(ApplyStatus.PENDING, INITIATOR_ID, OWNER_ID,
                LocalDateTime.now().minusHours(ChatLimits.APPLY_PENDING_REAPPLY_HOURS + 1));
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        service.apply(INITIATOR_ID, CONVERSATION_ID);

        verify(messageWriter, never()).appendLocked(any(), any(), any(), any(), any());
        verify(conversationMapper).updateById(any(ConversationEntity.class));
    }

    /**
     * 被拒未满冷却期：拒绝再次申请。
     *
     * @return void；断言失败即用户被拒后可立即反复申请骚扰发布者
     */
    @Test
    void rejectsReapplyDuringCooldown() {
        ConversationEntity conversation = conversation(ApplyStatus.REJECTED, INITIATOR_ID, OWNER_ID,
                LocalDateTime.now().minusDays(1));
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        assertThatThrownBy(() -> service.apply(INITIATOR_ID, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 被拒满冷却期：状态回到待审批，不新增卡片（R21）。
     *
     * @return void；断言失败即冷却后重新申请会冒出第二张卡
     */
    @Test
    void allowsReapplyAfterCooldownWithoutNewCard() {
        ConversationEntity conversation = conversation(ApplyStatus.REJECTED, INITIATOR_ID, OWNER_ID,
                LocalDateTime.now().minusDays(ChatLimits.APPLY_REJECT_COOLDOWN_DAYS + 1));
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        ApplyStateResponse response = service.apply(INITIATOR_ID, CONVERSATION_ID);

        verify(messageWriter, never()).appendLocked(any(), any(), any(), any(), any());
        assertThat(response.applyStatus()).isEqualTo(ApplyStatus.PENDING.dbValue());
    }

    /**
     * 已同意：重复提交是空操作，不再写卡。
     *
     * @return void；断言失败即已同意的人可以反复申请
     */
    @Test
    void approvedApplyIsNoop() {
        ConversationEntity conversation = conversation(ApplyStatus.APPROVED, INITIATOR_ID, OWNER_ID,
                null);
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        ApplyStateResponse response = service.apply(INITIATOR_ID, CONVERSATION_ID);

        assertThat(response.applyStatus()).isEqualTo(ApplyStatus.APPROVED.dbValue());
        verify(messageWriter, never()).appendLocked(any(), any(), any(), any(), any());
    }

    /**
     * 发布者不能给自己申请：参数非法。
     *
     * @return void；断言失败即发布者会收到自己发出的申请卡
     */
    @Test
    void ownerCannotApply() {
        ConversationEntity conversation = conversation(ApplyStatus.NONE, INITIATOR_ID, OWNER_ID, null);
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        assertThatThrownBy(() -> service.apply(OWNER_ID, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 帖子不需要申请：申请入口应被服务端拒绝。
     *
     * @return void；断言失败即未开启申请的帖子也能收到申请卡
     */
    @Test
    void rejectsApplyWhenPostDoesNotRequireIt() {
        when(postService.chatAnchor(POST_ID))
                .thenReturn(new PostChatAnchor(POST_ID, OWNER_ID, "active", false));
        ConversationEntity conversation = conversation(ApplyStatus.NONE, INITIATOR_ID, OWNER_ID, null);
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        assertThatThrownBy(() -> service.apply(INITIATOR_ID, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 同意申请：写入仅申请人可见的联系方式卡，并把联系事件渠道升级为「申请」。
     *
     * @return void；断言失败即申请人拿不到入口或指标渠道不升级（R22 / R31）
     */
    @Test
    void approveWritesContactCardAndUpgradesChannel() {
        ConversationEntity conversation = conversation(ApplyStatus.PENDING, INITIATOR_ID, OWNER_ID,
                LocalDateTime.now().minusHours(1));
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        ApplyStateResponse response =
                service.decide(OWNER_ID, CONVERSATION_ID, new ApplyDecisionRequest(true));

        verify(messageWriter).appendLocked(conversation, OWNER_ID, MessageType.CONTACT, null,
                INITIATOR_ID);
        verify(contactEventMapper).update(any(), any());
        assertThat(response.applyStatus()).isEqualTo(ApplyStatus.APPROVED.dbValue());
        assertThat(response.canViewContact()).isTrue();
    }

    /**
     * 拒绝申请：只改状态，不写联系方式卡。
     *
     * @return void；断言失败即被拒的人也能看到联系方式卡
     */
    @Test
    void rejectDoesNotWriteContactCard() {
        ConversationEntity conversation = conversation(ApplyStatus.PENDING, INITIATOR_ID, OWNER_ID,
                LocalDateTime.now().minusHours(1));
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        ApplyStateResponse response =
                service.decide(OWNER_ID, CONVERSATION_ID, new ApplyDecisionRequest(false));

        verify(messageWriter, never()).appendLocked(any(), any(), any(), any(), any());
        assertThat(response.applyStatus()).isEqualTo(ApplyStatus.REJECTED.dbValue());
    }

    /**
     * 卡片不在待审批：拒绝重复审批（防写出第二张联系方式卡）。
     *
     * @return void；断言失败即重复点「同意」会生成多张卡
     */
    @Test
    void decideRejectsNonPendingStatus() {
        ConversationEntity conversation = conversation(ApplyStatus.APPROVED, INITIATOR_ID, OWNER_ID,
                null);
        when(conversationMapper.selectByIdForUpdate(CONVERSATION_ID)).thenReturn(conversation);

        assertThatThrownBy(() ->
                service.decide(OWNER_ID, CONVERSATION_ID, new ApplyDecisionRequest(true)))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 非成员查询状态：与会话不存在同一响应，不泄露会话存在性。
     *
     * @return void；断言失败即第三方可探测他人会话
     */
    @Test
    void stateRejectsNonMember() {
        when(memberMapper.selectMember(CONVERSATION_ID, 99L)).thenReturn(null);

        assertThatThrownBy(() -> service.state(99L, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.CONVERSATION_NOT_FOUND);
                });
    }

    /**
     * 总开关关闭：申请被拒并返回维护文案，不写卡。
     *
     * @return void；断言失败即维护态下仍能发申请卡（R30）
     */
    @Test
    void applyRejectedWhenMessageSwitchOff() {
        doThrow(BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.MAINTENANCE))
                .when(chatService).requireMessageEnabled();

        assertThatThrownBy(() -> service.apply(INITIATOR_ID, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.MAINTENANCE);
                });
        verify(conversationMapper, never()).selectByIdForUpdate(any());
    }

    /**
     * 取号闸门：只有「该帖 + 该发起人」的会话处于已同意时放行。
     *
     * @return void；断言失败即未获同意的人可以取号（或已同意的人被误挡）
     */
    @Test
    void hasApprovedAccessOnlyForApprovedConversation() {
        ConversationEntity approved = conversation(ApplyStatus.APPROVED, INITIATOR_ID, OWNER_ID, null);
        when(conversationMapper.selectOne(any())).thenReturn(approved, (ConversationEntity) null);

        assertThat(service.hasApprovedAccess(POST_ID, INITIATOR_ID)).isTrue();
        assertThat(service.hasApprovedAccess(POST_ID, INITIATOR_ID)).isFalse();
    }

    /**
     * 构造会话实体（申请状态与两个时间点由用例指定）。
     *
     * @param status    申请状态
     * @param initiator 发起人 user_id
     * @param owner     发布者 user_id
     * @param applyTime 申请 / 审批时刻（可空）
     * @return {@link ConversationEntity} 测试会话
     */
    private ConversationEntity conversation(ApplyStatus status, Long initiator, Long owner,
            LocalDateTime applyTime) {
        ConversationEntity conversation = new ConversationEntity();
        conversation.setId(CONVERSATION_ID);
        conversation.setPostId(POST_ID);
        conversation.setInitiatorId(initiator);
        conversation.setOwnerId(owner);
        conversation.setApplyStatus(status.dbValue());
        conversation.setApplyAt(applyTime);
        conversation.setApplyDecidedAt(applyTime);
        conversation.setLastSeq(3);
        return conversation;
    }
}
