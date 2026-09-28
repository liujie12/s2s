package com.s2s.server.contact.entity;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 举报实体（映射表 {@code report}；详设 §5.5.2、数据库设计 §3.9）。
 *
 * <p>字段与 DDL {@code V1__init_schema.sql:260-279} 逐列对齐。{@code evidence} 为 JSON 列，
 * 本实体以 {@link String} 承载（写入方负责序列化）。</p>
 *
 * <p><b>Batch1 的字段空置说明</b>：{@code weight}（风险分权重）与
 * {@code is_false_report} 由运营侧写入，Batch1 无运营后台，故一律走 DDL 默认值
 * （0 / 0）不在 Java 侧赋值；{@code handlerId}/{@code handledAt} 同理留空。
 * 风险分累计（{@code post.risk_score}）与自动下架（阈值 60）属 §9.10.3 的运营链路，
 * Batch1 只负责「举报落库」，不做自动下架。</p>
 */
@TableName("report")
public class ReportEntity {

    /** 举报 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 被举报帖子 ID。 */
    private Long postId;

    /** 举报者 user_id。 */
    private Long reporterId;

    /** 被举报发布者 user_id（按用户查举报历史用）。 */
    private Long reportedUserId;

    /** 举报原因（{@code false_info}/{@code fraud}/{@code wrong_category}/
     * {@code harassment}/{@code other}）。 */
    private String reason;

    /** 举报描述（契约字段名 {@code remark}，列名 {@code description}）。 */
    private String description;

    /** 举报凭证 media_ids 数组（JSON 文本）。 */
    private String evidence;

    /** 风险分权重（运营可配；Batch1 不写，走 DDL 默认 0）。 */
    private Integer weight;

    /** 运营打标误报（Batch1 不写，走 DDL 默认 0）。 */
    private Integer isFalseReport;

    /** 处理状态（新建恒 pending）。 */
    private String status;

    /** 处理人 user_id（Batch1 不写）。 */
    private Long handlerId;

    /** 处理时间（Batch1 不写）。 */
    private LocalDateTime handledAt;

    /** 举报时间（库内 DEFAULT CURRENT_TIMESTAMP，服务端不写）。 */
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

    public Long getReporterId() {
        return reporterId;
    }

    public void setReporterId(Long reporterId) {
        this.reporterId = reporterId;
    }

    public Long getReportedUserId() {
        return reportedUserId;
    }

    public void setReportedUserId(Long reportedUserId) {
        this.reportedUserId = reportedUserId;
    }

    public String getReason() {
        return reason;
    }

    public void setReason(String reason) {
        this.reason = reason;
    }

    public String getDescription() {
        return description;
    }

    public void setDescription(String description) {
        this.description = description;
    }

    public String getEvidence() {
        return evidence;
    }

    public void setEvidence(String evidence) {
        this.evidence = evidence;
    }

    public Integer getWeight() {
        return weight;
    }

    public void setWeight(Integer weight) {
        this.weight = weight;
    }

    public Integer getIsFalseReport() {
        return isFalseReport;
    }

    public void setIsFalseReport(Integer isFalseReport) {
        this.isFalseReport = isFalseReport;
    }

    public String getStatus() {
        return status;
    }

    public void setStatus(String status) {
        this.status = status;
    }

    public Long getHandlerId() {
        return handlerId;
    }

    public void setHandlerId(Long handlerId) {
        this.handlerId = handlerId;
    }

    public LocalDateTime getHandledAt() {
        return handledAt;
    }

    public void setHandledAt(LocalDateTime handledAt) {
        this.handledAt = handledAt;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
