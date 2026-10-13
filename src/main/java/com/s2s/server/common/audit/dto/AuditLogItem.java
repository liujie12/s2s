package com.s2s.server.common.audit.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 审计留痕条目出参（[153] B2-5 审计查询接口）。
 *
 * <p>字段对应 {@code audit_log} 的 10 列（PRD §9.10.1「每条记录字段」：
 * 操作人、角色、时间、对象 ID、变更前值、变更后值、操作理由）。</p>
 *
 * @param id           审计 ID
 * @param operatorId   操作人 user_id
 * @param operatorRole 操作人角色落库值（super_admin/auditor/operator/algo/system/user）
 * @param action       动作标识
 * @param targetType   目标对象类型
 * @param targetId     目标对象 ID
 * @param beforeValue  变更前值 JSON 文本（可空）
 * @param afterValue   变更后值 JSON 文本（可空）
 * @param reason       操作理由（可空）
 * @param createdAt    操作时间
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AuditLogItem(
        Long id,
        Long operatorId,
        String operatorRole,
        String action,
        String targetType,
        Long targetId,
        String beforeValue,
        String afterValue,
        String reason,
        Instant createdAt) {
}
