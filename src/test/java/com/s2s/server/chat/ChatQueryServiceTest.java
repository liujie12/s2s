package com.s2s.server.chat;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.chat.dto.ConversationItem;
import com.s2s.server.chat.dto.ConversationPageResponse;
import com.s2s.server.chat.dto.MessagePageResponse;
import com.s2s.server.chat.dto.ReadResult;
import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.ConversationMemberEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.ConversationMemberMapper;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.MediaService;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link ChatQueryService} 读取链路测试（V30 / 计划 U4）。
 *
 * <p>覆盖计划 U4 的 Test scenarios：分页钳制、下架标记、90 天隐藏下界、增量游标、
 * 置已读推进到最大序号、非成员拒绝。「联系方式卡对非目标用户不可见」是 SQL 过滤
 * 语义，无测试库时用 {@link #messageQueryFiltersInvisibleCards()} 直读
 * {@code MessageMapper.xml} 守住。</p>
 */
class ChatQueryServiceTest {

    /** 当前登录用户。 */
    private static final Long USER_ID = 11L;

    /** 会话 ID。 */
    private static final Long CONVERSATION_ID = 900L;

    private final ConversationMapper conversationMapper = mock(ConversationMapper.class);
    private final ConversationMemberMapper memberMapper = mock(ConversationMemberMapper.class);
    private final MessageMapper messageMapper = mock(MessageMapper.class);
    private final MediaService mediaService = mock(MediaService.class);

    private ChatQueryService queryService;

    /**
     * 每个用例前重建服务，默认当前用户是会话成员。
     */
    @BeforeEach
    void setUp() {
        queryService = new ChatQueryService(
                conversationMapper, memberMapper, messageMapper, mediaService);
        when(memberMapper.selectMember(CONVERSATION_ID, USER_ID))
                .thenReturn(new ConversationMemberEntity());
    }

    /**
     * 列表行组装：下架标记与红点按行值派生，页大小超上限被钳制。
     *
     * @return void；断言失败即下架帖不置灰或一次可拉全量
     */
    @Test
    void listClampsPageSizeAndMapsRow() {
        when(conversationMapper.countForUser(eq(USER_ID), any())).thenReturn(1L);
        when(conversationMapper.selectPageForUser(eq(USER_ID), any(), eq(0),
                eq(ChatLimits.CONVERSATION_PAGE_MAX_SIZE)))
                .thenReturn(List.of(row("archived", 1)));
        when(mediaService.signCommittedImageUrl("media/first.jpg"))
                .thenReturn("https://oss/display/first.jpg");

        ConversationPageResponse response =
                queryService.listConversations(USER_ID, 0, 999);

        assertThat(response.page()).isEqualTo(1);
        assertThat(response.pageSize()).isEqualTo(ChatLimits.CONVERSATION_PAGE_MAX_SIZE);
        assertThat(response.total()).isEqualTo(1L);
        ConversationItem item = response.items().get(0);
        assertThat(item.conversationId()).isEqualTo(CONVERSATION_ID);
        assertThat(item.postThumbnailUrl()).isEqualTo("https://oss/display/first.jpg");
        assertThat(item.postGone()).isTrue();
        assertThat(item.unread()).isTrue();
        assertThat(item.peerNickname()).isEqualTo("对方");
    }

    /**
     * 90 天隐藏作为查询下界：service 传出的 visibleSince 约为 now − 90 天。
     *
     * @return void；断言失败即隐藏会话仍出现在列表（或活跃会话被误藏）
     */
    @Test
    void listUsesHideWindowLowerBound() {
        when(conversationMapper.countForUser(eq(USER_ID), any())).thenReturn(0L);
        when(conversationMapper.selectPageForUser(eq(USER_ID), any(), anyInt(), anyInt()))
                .thenReturn(List.of());

        queryService.listConversations(USER_ID, 1, 20);

        ArgumentCaptor<LocalDateTime> captor = ArgumentCaptor.forClass(LocalDateTime.class);
        verify(conversationMapper).countForUser(eq(USER_ID), captor.capture());
        LocalDateTime expected = LocalDateTime.now()
                .minusDays(ChatLimits.CONVERSATION_HIDE_AFTER_DAYS);
        assertThat(captor.getValue()).isBetween(expected.minusMinutes(1), expected.plusMinutes(1));
    }

    /**
     * 翻历史：倒序取一页后翻转成正序，多取的一条只用于 hasMore。
     *
     * @return void；断言失败即客户端拿到倒序消息或 hasMore 永远为真
     */
    @Test
    void listMessagesReversesHistoryPage() {
        when(messageMapper.selectBefore(CONVERSATION_ID, USER_ID, 8, 3))
                .thenReturn(List.of(message(5), message(4), message(3)));

        MessagePageResponse response =
                queryService.listMessages(USER_ID, CONVERSATION_ID, 8, null, 2);

        assertThat(response.items()).extracting(item -> item.seq()).containsExactly(4, 5);
        assertThat(response.hasMore()).isTrue();
    }

    /**
     * 增量：只返回 after_seq 之后的消息，保持正序，不重复。
     *
     * @return void；断言失败即拉取会重复渲染或漏条
     */
    @Test
    void listMessagesIncrementalUsesAfterSeq() {
        when(messageMapper.selectAfter(CONVERSATION_ID, USER_ID, 5, 4))
                .thenReturn(List.of(message(6), message(7)));

        MessagePageResponse response =
                queryService.listMessages(USER_ID, CONVERSATION_ID, null, 5, 3);

        assertThat(response.items()).extracting(item -> item.seq()).containsExactly(6, 7);
        assertThat(response.hasMore()).isFalse();
        verify(messageMapper, never()).selectBefore(any(), any(), any(), anyInt());
    }

    /**
     * 两个游标同时传入：参数非法，且不触达成员校验之后的查询。
     *
     * @return void；断言失败即语义含糊的请求照常返回
     */
    @Test
    void listMessagesRejectsBothCursors() {
        assertThatThrownBy(() -> queryService.listMessages(USER_ID, CONVERSATION_ID, 10, 5, 30))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 非成员读消息：与「会话不存在」同一响应，且不查消息表。
     *
     * @return void；断言失败即第三方可读到他人会话
     */
    @Test
    void listMessagesRejectsNonMember() {
        when(memberMapper.selectMember(CONVERSATION_ID, USER_ID)).thenReturn(null);

        assertThatThrownBy(() -> queryService.listMessages(USER_ID, CONVERSATION_ID, null, null, 30))
                .isInstanceOf(BizException.class)
                .satisfies(thrown -> {
                    BizException exception = (BizException) thrown;
                    assertThat(exception.getErrorCode()).isEqualTo(ErrorCode.NO_PERMISSION);
                    assertThat(exception.getMessage()).isEqualTo(ChatCopy.CONVERSATION_NOT_FOUND);
                });
        verify(messageMapper, never()).selectBefore(any(), any(), any(), anyInt());
        verify(messageMapper, never()).selectAfter(any(), any(), anyInt(), anyInt());
    }

    /**
     * 置已读：水位推进到会话当前最大序号，并复位已推送标记。
     *
     * @return void；断言失败即打开会话后红点仍在（或只清掉已滚动部分）
     */
    @Test
    void markReadAdvancesToConversationLastSeq() {
        ConversationEntity conversation = new ConversationEntity();
        conversation.setId(CONVERSATION_ID);
        conversation.setLastSeq(9);
        when(conversationMapper.selectById(CONVERSATION_ID)).thenReturn(conversation);
        when(memberMapper.markRead(CONVERSATION_ID, USER_ID, 9)).thenReturn(1);

        ReadResult result = queryService.markRead(USER_ID, CONVERSATION_ID);

        assertThat(result.lastReadSeq()).isEqualTo(9);
        verify(memberMapper).markRead(CONVERSATION_ID, USER_ID, 9);
    }

    /**
     * 非成员置已读：拒绝且不写水位。
     *
     * @return void；断言失败即第三方可替他人清红点
     */
    @Test
    void markReadRejectsNonMember() {
        when(memberMapper.selectMember(CONVERSATION_ID, USER_ID)).thenReturn(null);

        assertThatThrownBy(() -> queryService.markRead(USER_ID, CONVERSATION_ID))
                .isInstanceOf(BizException.class)
                .extracting(thrown -> ((BizException) thrown).getErrorCode())
                .isEqualTo(ErrorCode.NO_PERMISSION);
        verify(memberMapper, never()).markRead(any(), any(), anyInt());
    }

    /**
     * 消息查询必须带 {@code visible_to} 过滤：联系方式卡只对被同意人可见（R22）。
     *
     * @return void；断言失败即非目标用户能读到他人被给出的联系方式卡
     * @throws IOException Mapper XML 不可读时抛出
     */
    @Test
    void messageQueryFiltersInvisibleCards() throws IOException {
        String xml = Files.readString(
                Path.of("src", "main", "resources", "mapper", "MessageMapper.xml"),
                StandardCharsets.UTF_8);

        assertThat(xml)
                .as("两条消息查询都必须按 visible_to 过滤")
                .contains("AND (visible_to IS NULL OR visible_to = #{userId})");
    }

    /**
     * 构造一条列表行（只填断言用到的列）。
     *
     * @param postStatus 帖子库内状态
     * @param unreadFlag 红点标记（1=有未读）
     * @return {@link Map} 列名 → 值
     */
    private Map<String, Object> row(String postStatus, int unreadFlag) {
        Map<String, Object> row = new HashMap<>();
        row.put("conversation_id", CONVERSATION_ID);
        row.put("post_id", 3001L);
        row.put("post_title", "求租两居");
        row.put("post_status", postStatus);
        row.put("post_thumbnail_key", "media/first.jpg");
        row.put("peer_id", 22L);
        row.put("peer_nickname", "对方");
        row.put("peer_avatar_url", "https://img/1.png");
        row.put("last_message_type", MessageType.TEXT.dbValue());
        row.put("last_message_preview", "你好");
        row.put("last_message_at", LocalDateTime.now());
        row.put("unread_flag", unreadFlag);
        row.put("apply_status", ApplyStatus.NONE.dbValue());
        return row;
    }

    /**
     * 构造一条消息实体（只填断言用到的列）。
     *
     * @param seq 会话内序号
     * @return {@link MessageEntity} 测试消息
     */
    private MessageEntity message(int seq) {
        MessageEntity message = new MessageEntity();
        message.setId((long) seq);
        message.setConversationId(CONVERSATION_ID);
        message.setSeq(seq);
        message.setSenderId(USER_ID);
        message.setType(MessageType.TEXT.dbValue());
        message.setContent("第" + seq + "条");
        message.setCreatedAt(LocalDateTime.now());
        return message;
    }
}
