package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import com.s2s.server.common.dto.AuthorBrief;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Map;

/**
 * 帖子详情（[125] 建立，[127] 补齐读路径字段；对应 openapi {@code PostDetail}）。
 *
 * <p><b>出参必带 {@code version}</b>（供 PATCH status 乐观锁入参）。<b>不含完整
 * 联系方式</b>；完整值只由 {@code GET /posts/{id}/contact} 返回。</p>
 *
 * <p>{@code contactMask} 两个出参场景同源于发布时落库的 {@code post.contact_mask}
 * （[147] DEC-13），取值一致且均<b>非解密所得</b>：
 * <ul>
 *   <li>{@code POST /posts}（[125]）：回显发布时由明文派生的脱敏值；</li>
 *   <li>{@code GET /posts/{id}}（[127] → [147]）：读取库内 {@code contact_mask} 列。
 *       该列由<strong>发布端由明文派生</strong>（非密文回解），故读取它不破坏
 *       「{@code CryptoFacade.decrypt} 全库唯一调用点在 contact 域」这一安全红线
 *       （详设 §5.5.1）；完整明文仍只由 {@code GET /posts/{id}/contact} 返回。</li>
 * </ul>
 * 值为可空：存量行（V9 迁移前发布）无掩码，为 {@code null}。
 * </p>
 *
 * @param id                帖子 ID
 * @param type              类型
 * @param leafCategoryId    叶子类目 ID
 * @param l2CategoryId      二级类目 ID（STORED 生成列）
 * @param categoryPath      类目面包屑名称（L1 → L2 → L3，[127] GET 详情填充）
 * @param title             标题
 * @param price             价格（null 表示面议）
 * @param priceUnit         价格单位（price 为 null 时无意义）
 * @param description       描述
 * @param attributes        动态属性
 * @param lng               GCJ-02 经度
 * @param lat               GCJ-02 纬度
 * @param address           门牌号地址
 * @param distanceM         与请求方视野中心的距离（米）；详情接口无视野中心入参
 *                          （openapi 未声明 lng/lat query），[127] 恒 {@code null}
 * @param media             媒体列表（本人视角三态，他人视角仅 pass）
 * @param contactMask       发布时落库的脱敏联系方式（见类注释；可空）
 * @param completenessLevel 完整度档位（0/1/2）
 * @param status            状态（API 值，见 {@code PostStatus#toApi}）
 * @param publishAt         发布时间
 * @param expireAt          到期时间
 * @param author            作者摘要（POST /posts 出参不填充，保持 null）
 * @param version           乐观锁版本号
 * @param aiAssisted        本条是否由 T2 AI 智能发布辅助生成（B2-4，PRD §5.9；详情页标识来源）
 * @param favorited         当前登录用户是否已收藏；登录用户恒 {@code true/false}，游客 {@code null}
 * @param credentials       帖级凭证声明列表（一帖多证；无有效凭证时为空列表，客户端整栏不渲染）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostDetail(
        Long id,
        String type,
        Integer leafCategoryId,
        Integer l2CategoryId,
        List<String> categoryPath,
        String title,
        BigDecimal price,
        String priceUnit,
        String description,
        Map<String, Object> attributes,
        BigDecimal lng,
        BigDecimal lat,
        String address,
        Integer distanceM,
        List<MediaItem> media,
        String contactMask,
        Integer completenessLevel,
        String status,
        Instant publishAt,
        Instant expireAt,
        AuthorBrief author,
        Long version,
        Boolean aiAssisted,
        Boolean favorited,
        List<PostCredential> credentials) {
}
