package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * 帖子详情（[125]；对应 openapi {@code PostDetail}，POST /posts 出参）。
 *
 * <p><b>出参必带 {@code version}</b>（供 PATCH status 乐观锁入参）。<b>不含完整
 * 联系方式</b>，仅 {@code contact_mask}；完整值只由 {@code GET /posts/{id}/contact}
 * 返回。</p>
 *
 * <p>{@code author}/{@code category_path}/{@code distance_m} 属 [127] GET 详情
 * 范畴，本条目 POST /posts 出参不填充（保持 null）。</p>
 *
 * @param id                帖子 ID
 * @param type              类型
 * @param leafCategoryId    叶子类目 ID
 * @param l2CategoryId      二级类目 ID（STORED 生成列）
 * @param title             标题
 * @param description       描述
 * @param attributes        动态属性
 * @param lng               GCJ-02 经度
 * @param lat               GCJ-02 纬度
 * @param address           门牌号地址
 * @param media             媒体列表（本人视角三态）
 * @param contactMask       脱敏联系方式
 * @param completenessLevel 完整度档位（0/1/2）
 * @param status            状态
 * @param expireAt          到期时间
 * @param version           乐观锁版本号
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostDetail(
        Long id,
        String type,
        Integer leafCategoryId,
        Integer l2CategoryId,
        String title,
        String description,
        Map<String, Object> attributes,
        BigDecimal lng,
        BigDecimal lat,
        String address,
        List<MediaItem> media,
        String contactMask,
        Integer completenessLevel,
        String status,
        Instant expireAt,
        Long version) {
}
