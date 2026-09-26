package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 我的帖子列表项（[127]；对应 openapi {@code MyPostItem}，{@code GET /posts/mine} 出参）。
 *
 * <p><b>必带 {@code version}</b>（供 {@code PATCH /posts/{id}/status} 乐观锁入参）。
 * 本人视角下发媒体三态——{@code coverMedia} 走 {@code MediaAssembler.toDto(entity, true)}，
 * 故 {@code pending}/{@code reject} 的封面同样下发并携带 {@code reject_reason}。</p>
 *
 * @param id                帖子 ID
 * @param type              供需态（resource/demand）
 * @param leafCategoryId    叶子类目 ID
 * @param title             标题
 * @param coverMedia        封面媒体（本人视角，可为 {@code null}＝无媒体）
 * @param completenessLevel 完整度档位（0/1/2）
 * @param status            状态（API 值）
 * @param publishAt         发布时间
 * @param expireAt          到期时间
 * @param viewCount         浏览数；Batch1 无数据源（浏览计数随 [129] 埋点落库），恒 {@code null}
 * @param contactCount      被查看联系方式次数（{@code contact_event} 按 post_id 聚合，
 *                          [128] 起有数据）
 * @param version           乐观锁版本号
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record MyPostItem(
        Long id,
        String type,
        Integer leafCategoryId,
        String title,
        MediaItem coverMedia,
        Integer completenessLevel,
        String status,
        Instant publishAt,
        Instant expireAt,
        Long viewCount,
        Long contactCount,
        Long version) {
}
