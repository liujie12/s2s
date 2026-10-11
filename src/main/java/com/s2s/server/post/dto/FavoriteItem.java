package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.math.BigDecimal;
import java.time.Instant;

/**
 * 我的收藏列表项（openapi {@code FavoriteItem}；{@code GET /favorites} 出参）。
 *
 * <p>视角为<b>收藏者（非帖主）</b>：封面媒体只出 {@code audit_status=pass} 的项
 * （由 {@code MediaAssembler.toDto(media, false)} 承担视角分流），故 {@code coverMedia}
 * 的 {@code rejectReason} 恒为 {@code null}。不含完整联系方式。</p>
 *
 * @param postId            帖子 ID
 * @param type              供需态（resource/demand）
 * @param leafCategoryId    叶子类目 ID
 * @param l2CategoryId      二级类目 ID
 * @param title             标题
 * @param price             价格（null 表示面议）；PRD §8.3.2 卡片展示列
 * @param priceUnit         价格单位（price 为 null 时无意义）
 * @param coverMedia        封面媒体（他人视角，可为 {@code null}＝无过审媒体）
 * @param completenessLevel 完整度档位（0/1/2）
 * @param status            状态（API 值）
 * @param publishAt         发布时间
 * @param favoriteAt        收藏时间（列表排序键，倒序）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record FavoriteItem(
        Long postId,
        String type,
        Integer leafCategoryId,
        Integer l2CategoryId,
        String title,
        BigDecimal price,
        String priceUnit,
        MediaItem coverMedia,
        Integer completenessLevel,
        String status,
        Instant publishAt,
        Instant favoriteAt) {
}
