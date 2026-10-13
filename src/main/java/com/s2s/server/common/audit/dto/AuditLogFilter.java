package com.s2s.server.common.audit.dto;

import java.time.LocalDateTime;

/**
 * 审计查询过滤条件（[153] B2-5 审计查询接口的入参载体）。
 *
 * <p>承载七个可选过滤维度 + 分页参数；作为 MyBatis 单参数对象传入，
 * 属性名与 XML 中的 {@code #{}}` 占位一一对应。</p>
 */
public class AuditLogFilter {

    /** 操作人 ID（null = 不限）。 */
    private Long operatorId;

    /** 操作人角色落库值（null = 不限；[153] 起支持按四角色筛选）。 */
    private String operatorRole;

    /** 动作标识（null = 不限）。 */
    private String action;

    /** 目标对象类型（null = 不限）。 */
    private String targetType;

    /** 目标对象 ID（null = 不限）。 */
    private Long targetId;

    /** 起始时间（含；null = 不限）。 */
    private LocalDateTime from;

    /** 截止时间（含；null = 不限）。 */
    private LocalDateTime to;

    /** 每页条数（分页 LIMIT）。 */
    private int limit;

    /** 偏移量（分页 OFFSET）。 */
    private int offset;

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

    public LocalDateTime getFrom() {
        return from;
    }

    public void setFrom(LocalDateTime from) {
        this.from = from;
    }

    public LocalDateTime getTo() {
        return to;
    }

    public void setTo(LocalDateTime to) {
        this.to = to;
    }

    public int getLimit() {
        return limit;
    }

    public void setLimit(int limit) {
        this.limit = limit;
    }

    public int getOffset() {
        return offset;
    }

    public void setOffset(int offset) {
        this.offset = offset;
    }
}
