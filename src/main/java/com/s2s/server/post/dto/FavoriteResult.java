package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 收藏 / 取消收藏结果（openapi {@code FavoriteResult}）。
 *
 * <p>幂等写：{@code POST /posts/{id}/favorite} 恒回 {@code favorited=true}、
 * {@code DELETE} 恒回 {@code favorited=false}，供客户端同步星标状态。</p>
 *
 * @param favorited true=已收藏；false=已取消
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record FavoriteResult(boolean favorited) {
}
