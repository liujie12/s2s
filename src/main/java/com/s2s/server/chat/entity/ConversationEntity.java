package com.s2s.server.chat.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 会话实体（映射表 {@code conversation}；V30；计划 KTD1 / KTD2 / KTD3 / KTD8）。
 *
 * <p><b>唯一性由结构保证</b>：{@code uk_post_initiator} 决定「同一帖子 + 同一发起人」
 * 全生命周期只有一条会话——隐藏后再次发起走复用，不做状态翻转（R5）。</p>
 *
 * <p><b>申请卡状态挂在本行</b>（KTD2）：卡片在会话内是一条 {@code message}，
 * 但「待审批 / 已同意 / 已拒绝」与两个时间点属于会话本身，避免为一张卡再建一张表。</p>
 */
@TableName("conversation")
public class ConversationEntity {

    /** 会话 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 会话所锚定的帖子 ID。帖子下架不影响会话可用（R4）。 */
    private Long postId;

    /** 发起人 user_id。 */
    private Long initiatorId;

    /** 帖子发布者 user_id。 */
    private Long ownerId;

    /** 会话内消息序号水位（KTD3）：发送时加锁自增，消息行取该值。 */
    private Integer lastSeq;

    /** 最后一条可见消息时刻；空表示会话尚无消息。列表倒序与隐藏窗口都依据本列。 */
    private LocalDateTime lastMessageAt;

    /** 最后一条消息类型（text/apply/contact），列表摘要按类型选文案。 */
    private String lastMessageType;

    /** 最后一条消息摘要（发送时截断写入，仅供列表展示，不是正文真源）。 */
    private String lastMessagePreview;

    /** 联系方式申请卡状态：none/pending/approved/rejected。 */
    private String applyStatus;

    /** 申请卡最近一次提交时刻（重申窗口起算点）。 */
    private LocalDateTime applyAt;

    /** 申请卡最近一次审批时刻（冷却窗口起算点）。 */
    private LocalDateTime applyDecidedAt;

    /** 创建时间（库内默认值）。 */
    private LocalDateTime createdAt;

    /** 更新时间（库内自动更新）。 */
    private LocalDateTime updatedAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getPostId() {
        return postId;
    }

    public void setPostId(Long postId) {
        this.postId = postId;
    }

    public Long getInitiatorId() {
        return initiatorId;
    }

    public void setInitiatorId(Long initiatorId) {
        this.initiatorId = initiatorId;
    }

    public Long getOwnerId() {
        return ownerId;
    }

    public void setOwnerId(Long ownerId) {
        this.ownerId = ownerId;
    }

    public Integer getLastSeq() {
        return lastSeq;
    }

    public void setLastSeq(Integer lastSeq) {
        this.lastSeq = lastSeq;
    }

    public LocalDateTime getLastMessageAt() {
        return lastMessageAt;
    }

    public void setLastMessageAt(LocalDateTime lastMessageAt) {
        this.lastMessageAt = lastMessageAt;
    }

    public String getLastMessageType() {
        return lastMessageType;
    }

    public void setLastMessageType(String lastMessageType) {
        this.lastMessageType = lastMessageType;
    }

    public String getLastMessagePreview() {
        return lastMessagePreview;
    }

    public void setLastMessagePreview(String lastMessagePreview) {
        this.lastMessagePreview = lastMessagePreview;
    }

    public String getApplyStatus() {
        return applyStatus;
    }

    public void setApplyStatus(String applyStatus) {
        this.applyStatus = applyStatus;
    }

    public LocalDateTime getApplyAt() {
        return applyAt;
    }

    public void setApplyAt(LocalDateTime applyAt) {
        this.applyAt = applyAt;
    }

    public LocalDateTime getApplyDecidedAt() {
        return applyDecidedAt;
    }

    public void setApplyDecidedAt(LocalDateTime applyDecidedAt) {
        this.applyDecidedAt = applyDecidedAt;
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
