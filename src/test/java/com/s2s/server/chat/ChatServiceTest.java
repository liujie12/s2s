package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.config.AdminConfigKeys;
import com.s2s.server.chat.dto.ConversationCreateRequest;
import com.s2s.server.chat.dto.ConversationCreateResponse;
import com.s2s.server.chat.dto.ConversationRemoveResponse;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.common.config.SystemConfigService;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimiter;
import com.s2s.server.post.PostService;
import com.s2s.server.post.dto.PostChatAnchor;
import java.time.LocalDateTime;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link ChatService} 开会话链路测试（V30 / 计划 U2）。
 *
 * <p>覆盖计划 U2 的 Test scenarios：新建、复用、隐藏会话恢复、每日额度超限、
 * 维护态拒绝、帖子不可见、自聊拒绝、并发双击复用。所有依赖均为 mock，
 * 只验「门禁次序与落库意图」，真实 SQL 由 U4 的查询用例与迁移门禁覆盖。</p>
 */
class ChatServiceTest {

    /** 当前登录用户（发起人）。 */
    private static final Long INITIATOR_ID = 11L;

    /** 帖子发布者。 */
    private static final Long OWNER_ID = 22L;

    /** 帖子 ID。 */
    private static final Long POST_ID = 3001L;

    private final ConversationMapper conversationMapper = mock(ConversationMapper.class);
    private final ConversationMemberMapper memberMapper = mock(ConversationMemberMapper.class);
    private final PostService postService = mock(PostService.class);
    private final SystemConfigService systemConfigService = mock(SystemConfigService.class);
    private final RateLimiter rateLimiter = mock(RateLimiter.class);

    private ChatService chatService;

    /**
     * 每个用例前重建服务并默认开启消息总开关。
     */
    @BeforeEach
    void setUp() {
        chatService = new ChatService(conversationMapper, memberMapper, postService,
                systemConfigService, rateLimiter);
        when(systemConfigService.isOnOrAbsent(AdminConfigKeys.MESSAGE_ENABLED)).thenReturn(true);
        when(postService.chatAnchor(POST_ID))
                .thenReturn(new PostChatAnchor(POST_ID, OWNER_ID, "active", false));
    }

    /**
     * 首次发起：新建会话并写入双方成员行。
     *
     * @return void；断言失败即成员缺行（对方将永远查不到该会话）
     */
    @Test
    void createsConversationWithBothMembers() {
        when(conversationMapper.selectOne(any())).thenReturn(null);
        doAnswer(invocation -> {
            ConversationEntity inserted = invocation.getArgument(0);
            inserted.setId(900L);
            return 1;
        }).when(conversationMapper).insert(any(ConversationEntity.class));

        ConversationCreateResponse response =
                chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID));

        assertThat(response.conversationId()).isEqualTo(900L);
        assertThat(response.created()).isTrue();
        ArgumentCaptor<ConversationMemberEntity> memberCaptor =
                ArgumentCaptor.forClass(ConversationMemberEntity.class);
        verify(memberMapper, times(2)).insert(memberCaptor.capture());
        assertThat(memberCaptor.getAllValues()).extracting(ConversationMemberEntity::getUserId)
                .containsExactly(INITIATOR_ID, OWNER_ID);
        verify(rateLimiter).incrementAndCheck(any());
    }

    /**
     * 再次发起同一帖子：复用既有会话，不新建、不消耗额度。
     *
     * @return void；断言失败即同一帖子会冒出第二条会话或白扣额度
     */
    @Test
    void reusesExistingConversationWithoutQuota() {
        ConversationEntity existing = new ConversationEntity();
        existing.setId(901L);
        existing.setPostId(POST_ID);
        existing.setInitiatorId(INITIATOR_ID);
        existing.setOwnerId(OWNER_ID);
        existing.setLastMessageAt(LocalDateTime.now());
        when(conversationMapper.selectOne(any())).thenReturn(existing);

        ConversationCreateResponse response =
                chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID));

        assertThat(response.conversationId()).isEqualTo(901L);
        assertThat(response.created()).isFalse();
        verify(conversationMapper, never()).insert(any(ConversationEntity.class));
        verify(rateLimiter, never()).incrementAndCheck(any());
        // V33：重新发起同一会话时清空本人被删标记，会话回到列表
        verify(memberMapper).restoreVisibility(901L, INITIATOR_ID);
    }

    /**
     * 90 天无往来的会话再次发起：刷新最后往来时间恢复可见。
     *
     * @return void；断言失败即隐藏会话无法恢复（用户点了「发消息」却仍在列表外）
     */
    @Test
    void restoresHiddenConversationVisibility() {
        ConversationEntity hidden = new ConversationEntity();
        hidden.setId(902L);
        hidden.setPostId(POST_ID);
        hidden.setInitiatorId(INITIATOR_ID);
        hidden.setOwnerId(OWNER_ID);
        hidden.setLastMessageAt(LocalDateTime.now().minusDays(
                ChatLimits.CONVERSATION_HIDE_AFTER_DAYS + 1));
        when(conversationMapper.selectOne(any())).thenReturn(hidden);

        chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID));

        ArgumentCaptor<ConversationEntity> captor =
                ArgumentCaptor.forClass(ConversationEntity.class);
        verify(conversationMapper).updateById(captor.capture());
        assertThat(captor.getValue().getLastMessageAt())
                .isAfter(LocalDateTime.now().minusMinutes(1));
    }

    /**
     * 当日第 31 次发起：返回 42902 与会话域专用文案。
     *
     * @return void；断言失败即用户看到「查看联系方式次数已达上限」这类错位提示
     */
    @Test
    void rejectsWhenDailyQuotaExceededWithDedicatedCopy() {
        when(conversationMapper.selectOne(any())).thenReturn(null);
        doAnswer(invocation -> {
            ConversationEntity inserted = invocation.getArgument(0);
            inserted.setId(903L);
            return 1;
        }).when(conversationMapper).insert(any(ConversationEntity.class));
        when(rateLimiter.incrementAndCheck(any()))
                .thenThrow(BizException.ofRetryAfter(ErrorCode.CONTACT_LIMIT, 3600));

        assertThatThrownBy(() ->
                chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID)))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.CONTACT_LIMIT);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.NEW_CONVERSATION_LIMIT);
                    assertThat(exception.getRetryAfterSeconds()).isEqualTo(3600L);
                });
    }

    /**
     * 消息总开关关闭：创建被拒并返回维护文案。
     *
     * @return void；断言失败即维护态下仍能开会话
     */
    @Test
    void rejectsWhenMessageSwitchOff() {
        when(systemConfigService.isOnOrAbsent(AdminConfigKeys.MESSAGE_ENABLED)).thenReturn(false);

        assertThatThrownBy(() ->
                chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID)))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.MAINTENANCE);
                });
        verify(conversationMapper, never()).insert(any(ConversationEntity.class));
    }

    /**
     * 帖子草稿（对他人不可见）：返回 41001，且不落会话。
     *
     * @return void；断言失败即未发布的帖子可被陌生人开会话
     */
    @Test
    void rejectsInvisiblePost() {
        when(postService.chatAnchor(POST_ID))
                .thenReturn(new PostChatAnchor(POST_ID, OWNER_ID, "draft", false));

        assertThatThrownBy(() ->
                chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID)))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
    }

    /**
     * 与自己的帖子开会话：参数错误。
     *
     * @return void；断言失败即自聊会话可创建（未读与已读会同时指向同一人）
     */
    @Test
    void rejectsSelfConversation() {
        assertThatThrownBy(() ->
                chatService.openConversation(OWNER_ID, new ConversationCreateRequest(POST_ID)))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 并发双击：唯一键拒绝后复用另一请求刚建的会话，不报 50001。
     *
     * @return void；断言失败即双击会看到服务端错误
     */
    @Test
    void reusesConversationWhenConcurrentInsertLosesRace() {
        ConversationEntity raced = new ConversationEntity();
        raced.setId(904L);
        raced.setLastMessageAt(LocalDateTime.now());
        when(conversationMapper.selectOne(any())).thenReturn(null, raced);
        when(conversationMapper.insert(any(ConversationEntity.class)))
                .thenThrow(new org.springframework.dao.DuplicateKeyException("uk_post_initiator"));

        ConversationCreateResponse response =
                chatService.openConversation(INITIATOR_ID, new ConversationCreateRequest(POST_ID));

        assertThat(response.conversationId()).isEqualTo(904L);
        assertThat(response.created()).isFalse();
    }

    /**
     * 删除会话（V33）：只置本人成员行的 deleted_at，并把已读水位推到当前最大序号。
     *
     * @return void；断言失败即删除后未读仍亮着，或动到对方成员行
     */
    @Test
    void removeConversationHidesOnlyCurrentUserRow() {
        ConversationMemberEntity member = new ConversationMemberEntity();
        member.setConversationId(905L);
        member.setUserId(INITIATOR_ID);
        ConversationEntity conversation = new ConversationEntity();
        conversation.setId(905L);
        conversation.setLastSeq(7);
        when(memberMapper.selectMember(905L, INITIATOR_ID)).thenReturn(member);
        when(conversationMapper.selectById(905L)).thenReturn(conversation);

        ConversationRemoveResponse response = chatService.removeConversation(INITIATOR_ID, 905L);

        assertThat(response.conversationId()).isEqualTo(905L);
        verify(memberMapper).hideConversation(905L, INITIATOR_ID, 7);
        // 对方成员行不参与任何写入
        verify(memberMapper, never()).hideConversation(905L, OWNER_ID, 7);
    }

    /**
     * 删除会话（V33）：非成员与不存在同一响应，不泄露会话存在性（R32）。
     *
     * @return void；断言失败即陌生人可探测会话是否存在
     */
    @Test
    void removeConversationRejectsNonMember() {
        when(memberMapper.selectMember(905L, INITIATOR_ID)).thenReturn(null);

        assertThatThrownBy(() -> chatService.removeConversation(INITIATOR_ID, 905L))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage())
                            .isEqualTo(ChatCopy.CONVERSATION_NOT_FOUND);
                });
        verify(memberMapper, never()).hideConversation(any(), any(), anyInt());
    }
}
