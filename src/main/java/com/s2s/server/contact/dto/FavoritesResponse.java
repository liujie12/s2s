package com.s2s.server.contact.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;

/**
 * 我的收藏分页响应（openapi {@code FavoritesResponse}；{@code GET /favorites} 的 {@code data}）。
 *
 * @param items    当前页收藏项（按 {@code favoriteAt} 倒序）
 * @param total    符合条件的总条数（随 {@code type} 筛选收窄）
 * @param page     当前页码（从 1 起）
 * @param pageSize 每页条数
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record FavoritesResponse(
        List<FavoriteItem> items,
        long total,
        int page,
        int pageSize) {
}
