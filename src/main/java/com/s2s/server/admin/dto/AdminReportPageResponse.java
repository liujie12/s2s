package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 举报工单队列出参（[153] B2-5 ④；PRD §9.10.1 ④、§9.10.3）。
 *
 * @param items    当前页工单（按被举报帖子累计风险分降序）
 * @param total    该状态命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminReportPageResponse(
        List<Item> items,
        long total,
        int page,
        int pageSize) {

    /**
     * 工单条目。
     *
     * @param reportId      举报 ID
     * @param postId        被举报帖子 ID
     * @param postTitle     被举报帖子标题
     * @param reason        举报原因
     * @param weight        该举报的风险分贡献
     * @param status        工单状态
     * @param isFalseReport 是否已打标误报（0/1）
     * @param riskScore     被举报帖子的累计风险分
     * @param createdAt     举报时间
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Long reportId,
            Long postId,
            String postTitle,
            String reason,
            Integer weight,
            String status,
            Integer isFalseReport,
            Integer riskScore,
            Instant createdAt) {
    }
}
