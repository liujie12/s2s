package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 媒体提交确认结果（[125]；对应 openapi {@code MediaCommitResult}）。
 *
 * <p>{@code reject_reason} 仅 {@code audit_status=reject} 且本人视角时下发。</p>
 *
 * @param mediaId      媒体 ID
 * @param url          带签名的临时访问地址（桶不开公共读）
 * @param auditStatus  内容审核状态（pending/pass/reject）
 * @param rejectReason 审核拒绝原因（仅 reject 时下发）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MediaCommitResult(
        String mediaId,
        String url,
        String auditStatus,
        String rejectReason) {
}
