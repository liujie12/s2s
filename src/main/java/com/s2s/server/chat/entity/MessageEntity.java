package com.s2s.server.chat.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 会话消息实体（映射表 {@code message}；V30；计划 KTD2 / KTD3）。
 *
 * <p><b>三类消息同表</b>：文本 {@code text}、申请卡 {@code apply}、联系方式卡
 * {@code contact}。卡片没有正文，靠 {@code type} 渲染；联系方式卡额外带
 * {@code visibleTo}，只有被同意的申请人能查到该行（R22：号码不落在卡片上）。</p>
 *
 * <p><b>正文可为空</b>：卡片类消息正文恒为 NULL；账号注销时正文置 NULL 表示
 * 已匿名化（保留行以维持会话序号与取证完整性）。</p>
 */
@TableName("message")
public class MessageEntity {

    /** 消息 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 会话 ID。 */
    private Long conversationId;

    /** 会话内序号（同会话唯一，兼作增量游标与已读水位，KTD3）。 */
    private Integer seq;

    /** 发送者 user_id。 */
    private Long senderId;

    /** 消息类型：text/apply/contact。 */
    private String type;

    /** 文本正文；卡片类与已匿名化的正文为 NULL。 */
    private String content;

    /** 可见范围：非空即只对该 user_id 可见（仅联系方式卡使用）。 */
    private Long visibleTo;

    /** 发送时刻（库内默认值）。 */
    private LocalDateTime createdAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getConversationId() {
        return conversationId;
    }

    public void setConversationId(Long conversationId) {
        this.conversationId = conversationId;
    }

    public Integer getSeq() {
        return seq;
    }

    public void setSeq(Integer seq) {
        this.seq = seq;
    }

    public Long getSenderId() {
        return senderId;
    }

    public void setSenderId(Long senderId) {
        this.senderId = senderId;
    }

    public String getType() {
        return type;
    }

    public void setType(String type) {
        this.type = type;
    }

    public String getContent() {
        return content;
    }

    public void setContent(String content) {
        this.content = content;
    }

    public Long getVisibleTo() {
        return visibleTo;
    }

    public void setVisibleTo(Long visibleTo) {
        this.visibleTo = visibleTo;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
