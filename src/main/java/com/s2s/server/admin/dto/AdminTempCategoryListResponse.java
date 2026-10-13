package com.s2s.server.admin.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;
import java.util.List;

/**
 * 临时类目列表出参（[153] B2-5 §9.10.2；PRD §9.10.2）。
 *
 * @param items    当前页条目（按创建时间倒序）
 * @param total    命中总数
 * @param page     页码（1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record AdminTempCategoryListResponse(
        List<Item> items,
        long total,
        int page,
        int pageSize) {

    /**
     * 临时类目条目。
     *
     * @param id           临时叶子类目 ID
     * @param l2ParentId   挂载的「临时」二级类目 ID
     * @param name         临时类目名
     * @param status       生命周期：{@code active}/{@code expired}/{@code promoted}
     * @param createdBy    创建人（后台 admin_user.id）
     * @param createdAt    创建时间
     * @param expireAt     自动下线时刻
     * @param closedAt     结算时刻（未结算为 null）
     * @param publishCount 72h 窗口内发布数（未结算为 null）
     * @param contactCount 72h 窗口内被联系数（未结算为 null）
     * @param promoted     是否达标进转正候选池（未结算为 null）
     */
    @JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
    public record Item(
            Integer id,
            Integer l2ParentId,
            String name,
            String status,
            Long createdBy,
            Instant createdAt,
            Instant expireAt,
            Instant closedAt,
            Integer publishCount,
            Integer contactCount,
            Boolean promoted) {
    }
}
