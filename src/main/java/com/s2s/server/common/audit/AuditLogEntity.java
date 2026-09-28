package com.s2s.server.common.audit;

import com.baomidou.mybatisplus.annotation.IdType;
import com.baomidou.mybatisplus.annotation.TableId;
import com.baomidou.mybatisplus.annotation.TableName;
import java.time.LocalDateTime;

/**
 * 审计留痕实体（映射表 {@code audit_log}；详设 §4.3、可观测 §5）。
 *
 * <p>字段与 DDL {@code V1__init_schema.sql:374-388} 逐列对齐；{@code before_value} /
 * {@code after_value} 为 JSON 列，本实体以 {@link String} 承载（写入方负责序列化）。</p>
 *
 * <p><b>审计白名单（编码规范 §4.11）</b>：{@code before_value}/{@code after_value}
 * 内容不得出现 {@code phone}/{@code real_name}/{@code id_card}/{@code contact_value}/
 * {@code *_enc}/{@code *_hash}。本类不做校验（校验会漏掉嵌套结构），由写入侧
 * {@link AuditLogWriter} 的调用方在构造 {@link AuditEntry} 时保证。</p>
 *
 * <p><b>本表与 {@code contact_event} 不互替</b>（详设 §5.5.1）：前者是合规举证唯一来源
 * （保留 180 天、必须同事务），后者是产品指标统计点（北极星辅助指标）。
 * 同一次「查看联系方式」会同时产生两条记录，不是重复写入。</p>
 */
@TableName("audit_log")
public class AuditLogEntity {

    /** 审计 ID（主键，自增）。 */
    @TableId(value = "id", type = IdType.AUTO)
    private Long id;

    /** 操作人 user_id。 */
    private Long operatorId;

    /** 操作人角色（{@link OperatorRole#dbValue()} 落库）。 */
    private String operatorRole;

    /** 动作标识（如 {@code contact.view}）。 */
    private String action;

    /** 目标对象类型（{@code post} / {@code user} / {@code cert} 等）。 */
    private String targetType;

    /** 目标对象 ID。 */
    private Long targetId;

    /** 变更前值（JSON 文本，可空）。 */
    private String beforeValue;

    /** 变更后值（JSON 文本，可空）。 */
    private String afterValue;

    /** 操作理由（可空）。 */
    private String reason;

    /** 操作时间（库内 DEFAULT CURRENT_TIMESTAMP，服务端不写）。 */
    private LocalDateTime createdAt;

    public Long getId() {
        return id;
    }

    public void setId(Long id) {
        this.id = id;
    }

    public Long getOperatorId() {
        return operatorId;
    }

    public void setOperatorId(Long operatorId) {
        this.operatorId = operatorId;
    }

    public String getOperatorRole() {
        return operatorRole;
    }

    public void setOperatorRole(String operatorRole) {
        this.operatorRole = operatorRole;
    }

    public String getAction() {
        return action;
    }

    public void setAction(String action) {
        this.action = action;
    }

    public String getTargetType() {
        return targetType;
    }

    public void setTargetType(String targetType) {
        this.targetType = targetType;
    }

    public Long getTargetId() {
        return targetId;
    }

    public void setTargetId(Long targetId) {
        this.targetId = targetId;
    }

    public String getBeforeValue() {
        return beforeValue;
    }

    public void setBeforeValue(String beforeValue) {
        this.beforeValue = beforeValue;
    }

    public String getAfterValue() {
        return afterValue;
    }

    public void setAfterValue(String afterValue) {
        this.afterValue = afterValue;
    }

    public String getReason() {
        return reason;
    }

    public void setReason(String reason) {
        this.reason = reason;
    }

    public LocalDateTime getCreatedAt() {
        return createdAt;
    }

    public void setCreatedAt(LocalDateTime createdAt) {
        this.createdAt = createdAt;
    }
}
