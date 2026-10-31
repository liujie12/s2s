package com.s2s.server.chat;

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
import java.time.ZoneOffset;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 会话消息发送服务（V30 / 计划 U3）。
 *
 * <p><b>门禁次序</b>（次序本身是规格，不可换序）：维护开关 → 成员校验 → 敏感词 →
 * 会话行加锁 → 未回复额度。前两步拒绝「不该发的人」，第三步拒绝「不该发的内容」，
 * 后两步拒绝「发得太多的行为」；额度判定放在行锁之后，使同一会话的并发发送串行化，
 * 三条额度不会被两个并发请求同时突破。</p>
 *
 * <p><b>只发文本</b>：本版 {@code POST /conversations/{id}/messages} 仅承载
 * {@link MessageType#TEXT}。申请卡与联系方式卡由 U6 的申请链路经
 * {@link ChatMessageWriter} 写入，与文本共用同一套取号、摘要与首条联系事件规则。</p>
 *
 * <p><b>日志纪律</b>：本类不打印任何消息正文或联系方式（编码规范安全红线）。</p>
 */
@Service
public class ChatMessageService {

    private final ChatService chatService;
    private final ConversationMapper conversationMapper;
    private final ConversationMemberMapper memberMapper;
    private final MessageMapper messageMapper;
    private final SensitiveWordChecker sensitiveWordChecker;
    private final ChatMessageWriter messageWriter;
    private final ChatPushService chatPushService;

    /**
     * 构造消息发送服务。
     *
     * @param chatService          会话主链服务（复用维护开关判定，保证两处口径一致）
     * @param conversationMapper   会话持久层（行锁取号）
     * @param memberMapper         会话成员持久层（成员校验）
     * @param messageMapper        消息持久层（未回复额度计数）
     * @param sensitiveWordChecker 敏感词检测抽象（命中抛 {@code 40901}）
     * @param messageWriter        消息写入唯一落点（取号、摘要、首条联系事件）
     * @param chatPushService      新消息推送（未读期间只推首条，只推不落通知）
     */
    public ChatMessageService(ChatService chatService,
            ConversationMapper conversationMapper,
            ConversationMemberMapper memberMapper,
            MessageMapper messageMapper,
            SensitiveWordChecker sensitiveWordChecker,
            ChatMessageWriter messageWriter,
            ChatPushService chatPushService) {
        this.chatService = chatService;
        this.conversationMapper = conversationMapper;
        this.memberMapper = memberMapper;
        this.messageMapper = messageMapper;
        this.sensitiveWordChecker = sensitiveWordChecker;
        this.messageWriter = messageWriter;
        this.chatPushService = chatPushService;
    }

    /**
     * 在会话内发送一条文本消息（{@code POST /conversations/{id}/messages}）。
     *
     * <p>发送成功的副作用由 {@link ChatMessageWriter} 统一完成：消息行写入（{@code seq}
     * 由会话行锁内自增）、会话最后消息时间 / 类型 / 摘要更新、会话首条消息写一条渠道为
     * 「会话」的联系事件。接收方未读由「消息 seq &gt; 成员已读水位」自然推导，
     * 本方法不写未读计数。</p>
     *
     * @param userId         当前登录用户 ID（控制器已保证非 null）
     * @param conversationId 会话 ID
     * @param request        发送入参（只含正文）
     * @return {@link MessageSendResponse}（消息 ID + 会话 ID + 序号 + 发送时刻）
     * @throws BizException {@code 40305} 维护中 / 非成员 / 未回复额度用尽；
     *         {@code 40901} 命中敏感词
     */
    @Transactional
    public MessageSendResponse sendText(Long userId, Long conversationId,
            MessageSendRequest request) {
        chatService.requireMessageEnabled();
        requireMember(conversationId, userId);

        String content = request.content();
        sensitiveWordChecker.check(content);

        // 行锁之后再做额度判定：同一会话的并发发送在此排队，三条额度不会被同时突破
        ConversationEntity conversation = lockConversation(conversationId);
        requireUnrepliedQuota(conversationId, userId);

        MessageEntity message = messageWriter.appendLocked(conversation, userId,
                MessageType.TEXT, content, null);

        // 推送只在本会话未读期间推首条（KTD7），且只推不落站内通知（KTD6）；
        // 配额/通道不可用时静默降级，不影响已落库的消息。
        Long receiverId = userId.equals(conversation.getInitiatorId())
                ? conversation.getOwnerId()
                : conversation.getInitiatorId();
        chatPushService.notifyNewMessage(receiverId, conversationId);

        return new MessageSendResponse(message.getId(), conversationId, message.getSeq(),
                message.getCreatedAt().toInstant(ZoneOffset.UTC));
    }

    /**
     * 断言当前用户是会话成员（R32：非成员与不存在同一响应，不泄露会话存在性）。
     *
     * @param conversationId 会话 ID
     * @param userId         当前用户 ID
     * @throws BizException {@code 40305}，文案为「会话不存在或已不可访问」
     */
    private void requireMember(Long conversationId, Long userId) {
        ConversationMemberEntity member = memberMapper.selectMember(conversationId, userId);
        if (member == null) {
            throw BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.CONVERSATION_NOT_FOUND);
        }
    }

    /**
     * 加行锁读取会话；读不到视为已不可访问（与成员校验同一响应）。
     *
     * @param conversationId 会话 ID
     * @return {@link ConversationEntity} 加锁读到的会话
     * @throws BizException {@code 40305}，文案同成员校验
     */
    private ConversationEntity lockConversation(Long conversationId) {
        ConversationEntity conversation = conversationMapper.selectByIdForUpdate(conversationId);
        if (conversation == null) {
            throw BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.CONVERSATION_NOT_FOUND);
        }
        return conversation;
    }

    /**
     * 断言未回复文本未达上限（R26）。
     *
     * @param conversationId 会话 ID
     * @param userId         当前发送者
     * @throws BizException {@code 40305}，文案为「等待对方回复后可继续发送」
     */
    private void requireUnrepliedQuota(Long conversationId, Long userId) {
        int unreplied = messageMapper.countUnrepliedText(conversationId, userId);
        if (unreplied >= ChatLimits.UNREPLIED_TEXT_LIMIT) {
            throw BizException.of(ErrorCode.NO_PERMISSION, ChatCopy.UNREPLIED_LIMIT);
        }
    }
}
