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
 * <p>{@code contactMask} 在两个出参场景下的取值不同，且是刻意为之：
 * <ul>
 *   <li>{@code POST /posts}（[125]）：发布者握有自己刚提交的明文，回显其脱敏值；</li>
 *   <li>{@code GET /posts/{id}}（[127]）：<b>恒为 {@code null}</b>——库内只有 AEAD 密文，
 *       而「{@code CryptoFacade.decrypt} 全库唯一调用点在 contact 域」是安全红线
 *       （详设 §5.5.1），detail 域解密即破坏该不变量；且 PRD §7.4.1 详情页线框图
 *       无号码展示位，只有「📞 联系 TA」按钮——脱敏值属联系中转页（[128]）职责。</li>
 * </ul>
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
 * @param contactMask       脱敏联系方式（见类注释：GET 详情恒 null）
 * @param completenessLevel 完整度档位（0/1/2）
 * @param status            状态（API 值，见 {@code PostStatus#toApi}）
 * @param publishAt         发布时间
 * @param expireAt          到期时间
 * @param author            作者摘要（POST /posts 出参不填充，保持 null）
 * @param version           乐观锁版本号
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
        Long version) {
}
