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
import com.s2s.server.contact.ContactChannel;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import java.time.LocalDateTime;
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
 * {@link MessageType#TEXT}。申请卡与联系方式卡由 U6 的申请链路写入，走同一套
 * 取号与摘要更新规则。</p>
 *
 * <p><b>日志纪律</b>：本类不打印任何消息正文或联系方式（编码规范安全红线）。</p>
 */
@Service
public class ChatMessageService {

    private final ChatService chatService;
    private final ConversationMapper conversationMapper;
    private final ConversationMemberMapper memberMapper;
    private final MessageMapper messageMapper;
    private final ContactEventMapper contactEventMapper;
    private final SensitiveWordChecker sensitiveWordChecker;

    /**
     * 构造消息发送服务。
     *
     * @param chatService          会话主链服务（复用维护开关判定，保证两处口径一致）
     * @param conversationMapper   会话持久层（行锁取号与最后消息摘要更新）
     * @param memberMapper         会话成员持久层（成员校验）
     * @param messageMapper        消息持久层（写入与未回复额度计数）
     * @param contactEventMapper   联系事件持久层（会话首条消息写一条事件，R31）
     * @param sensitiveWordChecker 敏感词检测抽象（命中抛 {@code 40901}）
     */
    public ChatMessageService(ChatService chatService,
            ConversationMapper conversationMapper,
            ConversationMemberMapper memberMapper,
            MessageMapper messageMapper,
            ContactEventMapper contactEventMapper,
            SensitiveWordChecker sensitiveWordChecker) {
        this.chatService = chatService;
        this.conversationMapper = conversationMapper;
        this.memberMapper = memberMapper;
        this.messageMapper = messageMapper;
        this.contactEventMapper = contactEventMapper;
        this.sensitiveWordChecker = sensitiveWordChecker;
    }

    /**
     * 在会话内发送一条文本消息（{@code POST /conversations/{id}/messages}）。
     *
     * <p>发送成功后的副作用：消息行写入（{@code seq} 由会话行锁内自增）、会话的最后
     * 消息时间/类型/摘要更新、会话首条消息写一条渠道为「会话」的联系事件。
     * 接收方未读由「消息 seq &gt; 成员已读水位」自然推导，本方法不写未读计数。</p>
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

        int previousSeq = conversation.getLastSeq() == null ? 0 : conversation.getLastSeq();
        int seq = previousSeq + 1;
        LocalDateTime now = LocalDateTime.now();

        MessageEntity message = new MessageEntity();
        message.setConversationId(conversationId);
        message.setSeq(seq);
        message.setSenderId(userId);
        message.setType(MessageType.TEXT.dbValue());
        message.setContent(content);
        message.setCreatedAt(now);
        messageMapper.insert(message);

        updateConversationTail(conversationId, seq, content, now);

        if (previousSeq == 0) {
            // 首条消息落一条会话渠道的联系事件；后续消息不重复写（R31 / KTD11）
            writeConversationContactEvent(conversation, userId);
        }

        // 推送触发在 U9 接入（接收方未读且未推送过时只推首条，KTD6 / KTD7）；
        // 本单元只保证消息落库与会话尾部更新，避免在 U9 之前引入半成品推送路径。
        return new MessageSendResponse(message.getId(), conversationId, seq,
                now.toInstant(ZoneOffset.UTC));
    }

    /**
     * 断言当前用户是会话语成员（R32：非成员与不存在同一响应，不泄露会话存在性）。
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

    /**
     * 更新会话尾部的最后消息时间、类型与摘要（列表展示口径）。
     *
     * <p>只写这三列与序号：申请卡状态（{@code apply_*}）不属于发送文本的副作用，
     * 由 U6 的申请链路维护。</p>
     *
     * @param conversationId 会话 ID
     * @param seq            本次消息的序号
     * @param content        消息正文（摘要按 {@link ChatLimits#LIST_PREVIEW_MAX_LENGTH} 截断）
     * @param now            发送时刻
     */
    private void updateConversationTail(Long conversationId, int seq, String content,
            LocalDateTime now) {
        ConversationEntity patch = new ConversationEntity();
        patch.setId(conversationId);
        patch.setLastSeq(seq);
        patch.setLastMessageAt(now);
        patch.setLastMessageType(MessageType.TEXT.dbValue());
        patch.setLastMessagePreview(preview(content));
        conversationMapper.updateById(patch);
    }

    /**
     * 写一条渠道为「会话」的联系事件（R31 / KTD11）。
     *
     * <p>联系双方取自会话行：发起人是 {@code initiator_id}，发布者是 {@code owner_id}，
     * 发送者只可能是其中之一（成员校验已保证）。</p>
     *
     * @param conversation 会话（提供帖子与双方 user_id）
     * @param senderId     发送者 user_id
     */
    private void writeConversationContactEvent(ConversationEntity conversation, Long senderId) {
        Long receiverId = senderId.equals(conversation.getInitiatorId())
                ? conversation.getOwnerId()
                : conversation.getInitiatorId();
        ContactEventEntity event = new ContactEventEntity();
        event.setPostId(conversation.getPostId());
        event.setFromUserId(senderId);
        event.setToUserId(receiverId);
        event.setConversationId(conversation.getId());
        event.setChannelType(ContactChannel.CONVERSATION);
        contactEventMapper.insert(event);
    }

    /**
     * 生成列表摘要：超过上限即截断，不改正文真源。
     *
     * @param content 消息正文（非空）
     * @return {@link String} 不超过 {@link ChatLimits#LIST_PREVIEW_MAX_LENGTH} 个字符的摘要
     */
    private String preview(String content) {
        if (content.length() <= ChatLimits.LIST_PREVIEW_MAX_LENGTH) {
            return content;
        }
        return content.substring(0, ChatLimits.LIST_PREVIEW_MAX_LENGTH);
    }
}
