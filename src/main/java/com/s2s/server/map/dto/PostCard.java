package com.s2s.server.map.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.time.Instant;

/**
 * 列表卡片项（[126]；对应 openapi {@code PostCard}，GET /posts/search 出参）。
 *
 * <p>不含完整联系方式（详情/联系另走 {@code /posts/{id}} 与
 * {@code /posts/{id}/contact}）。{@code coverUrl} 仅当存在 {@code audit_status=pass}
 * 的封面媒体时有值（Batch1 简化为 null，OSS URL 拼装随 media 展示后续条目落地）。</p>
 *
 * @param id                帖子 ID
 * @param type              供需态（resource/demand）
 * @param leafCategoryId    叶子类目 ID
 * @param l2CategoryId      二级类目 ID（STORED 生成列）
 * @param title             标题
 * @param summary           描述摘要
 * @param coverUrl          封面 URL（可空）
 * @param lng               GCJ-02 经度
 * @param lat               GCJ-02 纬度
 * @param distanceM         距视野中心距离（米，可空；仅 distance 排序时有值）
 * @param completenessLevel 完整度档位（0/1/2）
 * @param publishAt         发布时间
 * @param author            作者摘要
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostCard(
        Long id,
        String type,
        Integer leafCategoryId,
        Integer l2CategoryId,
        String title,
        String summary,
        String coverUrl,
        Double lng,
        Double lat,
        Integer distanceM,
        Integer completenessLevel,
        Instant publishAt,
        AuthorBrief author) {
}
