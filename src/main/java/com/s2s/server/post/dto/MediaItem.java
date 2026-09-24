package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 帖子内媒体项（[125]；对应 openapi {@code MediaItem}）。
 *
 * <p>他人视角只出现 {@code audit_status=pass} 的项；本人视角可出现三态并携带
 * {@code reject_reason}。视角分流由 {@code MediaAssembler.toDto(entity, isOwner)} 承担，
 * 禁在 controller 判断视角（R2 硬规则）。</p>
 *
 * @param mediaId      媒体 ID
 * @param url          带签名临时访问地址
 * @param auditStatus  内容审核状态
 * @param rejectReason 审核拒绝原因（仅 reject 且本人视角）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MediaItem(
        String mediaId,
        String url,
        String auditStatus,
        String rejectReason) {
}
