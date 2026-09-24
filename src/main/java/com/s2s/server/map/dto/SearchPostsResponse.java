package com.s2s.server.map.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 列表检索响应（[126]；对应 openapi {@code /posts/search} 200 的 data 结构）。
 *
 * @param items                卡片列表
 * @param total                命中总数
 * @param page                 当前页（从 1 起）
 * @param pageSize             每页条数
 * @param categoryVersionStale 客户端分类树版本是否过期
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SearchPostsResponse(
        List<PostCard> items,
        Integer total,
        Integer page,
        Integer pageSize,
        Boolean categoryVersionStale) {
}
