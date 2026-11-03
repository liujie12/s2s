package com.s2s.server.chat.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 会话成员实体（映射表 {@code conversation_member}；V30；计划 KTD1 / KTD7）。
 *
 * <p><b>已读只认水位</b>：{@code last_read_seq} 是已读的唯一真源，未读由
 * 「消息 seq &gt; 水位」推导，不存计数器——避免「计数与消息行不同步」这类
 * 需要补偿任务修复的偏差。</p>
 *
 * <p><b>复合主键</b>：表主键是 {@code (conversation_id, user_id)}。MyBatis-Plus
 * 只支持单主键，故仅把 {@code conversation_id} 标为 {@link TableId} 以满足插入；
 * 所有按主键的读写都走自定义 SQL（{@code ConversationMemberMapper}），
 * <b>禁止</b>用 {@code updateById}/{@code deleteById} 操作本实体。</p>
 */
@TableName("conversation_member")
public class ConversationMemberEntity {

    /** 会话 ID（复合主键之一；仅用于插入，不作为单主键更新依据）。 */
    @TableId(value = "conversation_id", type = IdType.INPUT)
    private Long conversationId;

    /** 成员 user_id（复合主键之一）。 */
    private Long userId;

    /** 已读水位：未读 = 消息 seq 大于本值。 */
    private Integer lastReadSeq;

    /** 未读期间已推送标记：1=已推过首条，读会话时复位（KTD7）。 */
    private Integer pushedUnread;

    /**
     * 用户从自己列表删除会话的时刻（V33）：非空=对本人不可见。
     *
     * <p>仅本人口径：对方成员行不受影响；会话与消息仍保留（举报取证需要）。
     * 收到新消息或本人重新发起时由 {@code ConversationMemberMapper#restoreVisibility}
     * 清空，会话重新出现在列表。</p>
     */
    private LocalDateTime deletedAt;

    /** 创建时间（库内默认值）。 */
    private LocalDateTime createdAt;

    /** 更新时间（库内自动更新）。 */
    private LocalDateTime updatedAt;

    public Long getConversationId() {
        return conversationId;
    }

    public void setConversationId(Long conversationId) {
        this.conversationId = conversationId;
    }

    public Long getUserId() {
        return userId;
    }

    public void setUserId(Long userId) {
        this.userId = userId;
    }

    public Integer getLastReadSeq() {
        return lastReadSeq;
    }

    public void setLastReadSeq(Integer lastReadSeq) {
        this.lastReadSeq = lastReadSeq;
    }

    public Integer getPushedUnread() {
        return pushedUnread;
    }

    public void setPushedUnread(Integer pushedUnread) {
        this.pushedUnread = pushedUnread;
    }

    public LocalDateTime getDeletedAt() {
        return deletedAt;
    }

    public void setDeletedAt(LocalDateTime deletedAt) {
        this.deletedAt = deletedAt;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }

    public LocalDateTime getUpdatedAt() {
        return updatedAt;
    }

    public void setUpdatedAt(LocalDateTime updatedAt) {
        this.updatedAt = updatedAt;
    }
}
