package com.s2s.server.chat;

import com.s2s.server.chat.entity.ConversationEntity;
import com.s2s.server.chat.entity.MessageEntity;
import com.s2s.server.chat.mapper.ConversationMapper;
import com.s2s.server.chat.mapper.MessageMapper;
import com.s2s.server.common.constants.ChatLimits;
import com.s2s.server.contact.ContactChannel;
import com.s2s.server.contact.entity.ContactEventEntity;
import com.s2s.server.contact.mapper.ContactEventMapper;
import java.time.LocalDateTime;
import org.springframework.stereotype.Component;

/**
 * 会话消息写入的唯一落点（V30 / 计划 U3 / U6）。
 *
 * <p><b>为什么单独抽出来</b>：文本消息（U3）与申请卡 / 联系方式卡（U6）都要做同一件事——
 * 在持有会话行锁的前提下取下一个 {@code seq}、写消息、更新会话尾部、首条消息写联系事件。
 * 这份逻辑若在两处各写一遍，申请卡一旦漏更 {@code last_seq}，会话里就会出现重号，
 * 而重号会直接破坏已读水位与增量游标。</p>
 *
 * <p><b>调用前提</b>：调用方必须已经用
 * {@link ConversationMapper#selectByIdForUpdate(Long)} 拿到了会话行锁，并把该行传进来。
 * 文本发送需要「加锁 → 判未回复额度 → 写入」的次序，故锁不能藏在本类内部。</p>
 */
@Component
public class ChatMessageWriter {

    private final ConversationMapper conversationMapper;
    private final MessageMapper messageMapper;
    private final ContactEventMapper contactEventMapper;

    /**
     * 构造消息写入器。
     *
     * @param conversationMapper 会话持久层（更新最后消息时间 / 类型 / 摘要与序号）
     * @param messageMapper      消息持久层
     * @param contactEventMapper 联系事件持久层（会话首条消息写一条事件，R31）
     */
    public ChatMessageWriter(ConversationMapper conversationMapper, MessageMapper messageMapper,
            ContactEventMapper contactEventMapper) {
        this.conversationMapper = conversationMapper;
        this.messageMapper = messageMapper;
        this.contactEventMapper = contactEventMapper;
    }

    /**
     * 在已加锁的会话内追加一条消息。
     *
     * @param conversation 已加行锁的会话（必须非空）
     * @param senderId     发送者 user_id
     * @param type         消息类型
     * @param content      文本正文；卡片类传 {@code null}
     * @param visibleTo    可见范围；仅联系方式卡传申请人 user_id，其余传 {@code null}
     * @return {@link MessageEntity} 已落库的消息（含 ID、seq、发送时刻）
     */
    public MessageEntity appendLocked(ConversationEntity conversation, Long senderId,
            MessageType type, String content, Long visibleTo) {
        int previousSeq = conversation.getLastSeq() == null ? 0 : conversation.getLastSeq();
        int seq = previousSeq + 1;
        LocalDateTime now = LocalDateTime.now();

        MessageEntity message = new MessageEntity();
        message.setConversationId(conversation.getId());
        message.setSeq(seq);
        message.setSenderId(senderId);
        message.setType(type.dbValue());
        message.setContent(content);
        message.setVisibleTo(visibleTo);
        message.setCreatedAt(now);
        messageMapper.insert(message);

        ConversationEntity patch = new ConversationEntity();
        patch.setId(conversation.getId());
        patch.setLastSeq(seq);
        patch.setLastMessageAt(now);
        patch.setLastMessageType(type.dbValue());
        patch.setLastMessagePreview(preview(content));
        conversationMapper.updateById(patch);

        if (previousSeq == 0) {
            // 一个会话只写一条联系事件：首条消息落「会话」渠道，申请同意时由 U6 升级为「申请」
            writeConversationContactEvent(conversation, senderId);
        }
        return message;
    }

    /**
     * 写一条渠道为「会话」的联系事件（R31 / KTD11）。
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
     * 生成列表摘要：超过上限即截断，不改正文真源；卡片消息（正文为 null）摘要也为 null，
     * 由客户端按 {@code last_message_type} 选文案。
     *
     * @param content 消息正文（可空）
     * @return {@link String} 不超过 {@link ChatLimits#LIST_PREVIEW_MAX_LENGTH} 个字符的摘要
     */
    private String preview(String content) {
        if (content == null || content.length() <= ChatLimits.LIST_PREVIEW_MAX_LENGTH) {
            return content;
        }
        return content.substring(0, ChatLimits.LIST_PREVIEW_MAX_LENGTH);
    }
}
