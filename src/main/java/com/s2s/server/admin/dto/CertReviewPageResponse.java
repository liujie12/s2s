package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 认证审核队列出参（[153] B2-5 ⑤；PRD §9.10.1 ⑤、§4.7）。
 *
 * @param items    当前页认证记录（按提交时间升序）
 * @param total    该状态命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CertReviewPageResponse(
        List<Item> items,
        long total,
        int page,
        int pageSize) {

    /**
     * 队列条目。
     *
     * @param certId      认证 ID
     * @param userId      申请人 user_id
     * @param certType    认证类型
     * @param status      认证状态
     * @param submittedAt 提交时间
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Long certId,
            Long userId,
            String certType,
            String status,
            Instant submittedAt) {
    }
}
