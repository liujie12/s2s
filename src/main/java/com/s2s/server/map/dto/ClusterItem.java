package com.s2s.server.map.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 服务端预聚合结果单元（[126]；对应 openapi {@code clusters[]} 元素）。
 *
 * @param lng        聚合点经度（GCJ-02）
 * @param lat        聚合点纬度（GCJ-02）
 * @param count      该聚合点包含的帖子数
 * @param categoryId 聚合内主导类目，用于图标着色（可空，Batch1 简化为空由客户端用默认色）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record ClusterItem(
        Double lng,
        Double lat,
        Integer count,
        Integer categoryId) {
}
