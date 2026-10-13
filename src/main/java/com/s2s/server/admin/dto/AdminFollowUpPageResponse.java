package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 待运营跟进队列出参（[153] B2-5 ⑥；PRD §6.4.4）。
 *
 * @param items    当前页条目（按入队时间升序）
 * @param total    该状态命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminFollowUpPageResponse(
        List<Item> items,
        long total,
        int page,
        int pageSize) {

    /**
     * 队列条目。
     *
     * @param id          条目 ID
     * @param userId      触发检索的用户（游客为 null）
     * @param keyword     检索关键词
     * @param l2CategoryId 检索的二级类目 ID
     * @param gridId      坐标网格（约 500m，粗粒度）
     * @param status      处理状态
     * @param triggeredAt 入队时间
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Long id,
            Long userId,
            String keyword,
            Integer l2CategoryId,
            String gridId,
            String status,
            Instant triggeredAt) {
    }
}
