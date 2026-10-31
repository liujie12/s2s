package com.s2s.server.contact.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 联系事件实体（映射表 {@code contact_event}；详设 §5.5.1 第 [7] 步、数据库设计 §3.8）。
 *
 * <p><b>本表是北极星辅助指标的唯一统计点</b>：详设 §5.5.1 明文「{@code contact_event}
 * 是产品指标口径的唯一来源——省掉它，北极星指标就没有数据来源」。</p>
 *
 * <p><b>Scope 红线（数据库设计 §3.8 原文）</b>：本表只记录「联系动作是否发生」，
 * <b>禁止增加 {@code contacted_success}/{@code deal_done} 等成交反馈字段</b>。
 * 本实体刻意只保留动作事实列；V30 按计划 KTD11 新增 {@code conversation_id}
 * （会话去重与渠道升级定位用），仍属「动作事实」而非成交反馈，经用户裁定后落地。</p>
 *
 * <p>与 {@code audit_log} 的分工（可观测 §5 的命名陷阱消歧）：同一次「查看联系方式」
 * 产生两条数据——本表服务业务指标（保留 90 天口径的埋点侧另计），
 * {@code audit_log} 服务合规举证（180 天、同事务、不可丢）。<b>两者不可合并、
 * 不可互相替代</b>。</p>
 */
@TableName("contact_event")
public class ContactEventEntity {

    /** 事件 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 帖子 ID。 */
    private Long postId;

    /** 发起联系者 user_id。 */
    private Long fromUserId;

    /** 被联系发布者 user_id。 */
    private Long toUserId;

    /** 会话 ID（渠道为 {@code conversation}/{@code apply} 时写入；其余渠道为 null，V30 / KTD11）。 */
    private Long conversationId;

    /** 联系方式渠道（phone / wechat / conversation / apply）。 */
    private String channelType;

    /** 联系时刻（库内 DEFAULT CURRENT_TIMESTAMP，服务端不写）。 */
    private LocalDateTime createdAt;

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

    public Long getFromUserId() {
        return fromUserId;
    }

    public void setFromUserId(Long fromUserId) {
        this.fromUserId = fromUserId;
    }

    public Long getToUserId() {
        return toUserId;
    }

    public void setToUserId(Long toUserId) {
        this.toUserId = toUserId;
    }

    /**
     * 取会话 ID。
     *
     * @return {@link Long} 会话 ID；非会话/申请渠道为 {@code null}
     */
    public Long getConversationId() {
        return conversationId;
    }

    /**
     * 设置会话 ID。
     *
     * @param conversationId 会话 ID（会话与申请渠道写入，其余渠道传 {@code null}）
     */
    public void setConversationId(Long conversationId) {
        this.conversationId = conversationId;
    }

    public String getChannelType() {
        return channelType;
    }

    public void setChannelType(String channelType) {
        this.channelType = channelType;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
