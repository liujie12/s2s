package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 我的帖子分页响应（[127]；对应 openapi {@code GET /posts/mine} 响应 {@code data}）。
 *
 * @param items    当前页列表项（每项必带 {@code version}）
 * @param total    符合条件的总条数
 * @param page     当前页码（从 1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MyPostsResponse(
        List<MyPostItem> items,
        long total,
        int page,
        int pageSize) {
}
