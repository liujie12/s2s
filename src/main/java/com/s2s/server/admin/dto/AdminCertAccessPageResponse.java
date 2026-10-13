package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 认证敏感查看复核申请列表出参（[153] B2-5；PRD §9.10.1）。
 *
 * @param items    当前页条目（按申请时间倒序）
 * @param total    命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminCertAccessPageResponse(
        List<Item> items,
        long total,
        int page,
        int pageSize) {

    /**
     * 复核申请条目。
     *
     * @param id          申请 ID
     * @param certId      目标认证记录 ID
     * @param requesterId 发起人（admin_user.id）
     * @param reason      查看理由
     * @param status      复核状态：pending/approved/rejected
     * @param reviewerId  复核人（admin_user.id；未复核为 null）
     * @param reviewedAt  复核时刻（未复核为 null）
     * @param createdAt   申请时刻
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Long id,
            Long certId,
            Long requesterId,
            String reason,
            String status,
            Long reviewerId,
            Instant reviewedAt,
            Instant createdAt) {
    }
}
