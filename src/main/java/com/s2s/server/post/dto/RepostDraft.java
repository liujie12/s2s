package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;
import java.util.Map;

/**
 * 克隆重发草稿载荷（[B2-8]；对应 openapi {@code RepostDraft}、{@code POST /posts/{post_id}/repost}）。
 *
 * <p>服务端读取原帖返回的<b>可编辑草稿</b>（<b>不落库</b>），前端带入发布页编辑态，
 * 用户确认后走既有 {@code POST /posts}（PRD §8.4「克隆原内容 + 进入发布页 + 自动带入所有字段」、
 * §8.6「archived → 重发 → 克隆新 draft → 编辑 → active」）。</p>
 *
 * <p><b>安全收窄</b>：本载荷<b>不含完整联系方式</b>——只回 {@code contactType}（渠道）
 * 与 {@code contactMask}（脱敏串）；明文唯一出口是 {@code GET /posts/{id}/contact}
 * （安全方案 §4.6 出口收敛）。前端编辑态据此展示脱敏值，未重填则发布时按原值处理。</p>
 *
 * @param sourcePostId      原帖 ID
 * @param type              类型（resource/demand）
 * @param leafCategoryId    叶子类目 ID
 * @param title             标题
 * @param price             价格（元；null = 面议）
 * @param priceUnit         价格单位
 * @param description       描述正文
 * @param attributes        动态属性（原帖 {@code template_values} 反序列化）
 * @param lng               GCJ-02 经度
 * @param lat               GCJ-02 纬度
 * @param address           门牌号地址
 * @param addressPrecise    地址是否精确到门牌（取自原帖完整度条件）
 * @param mediaIds          原帖关联媒体 ID 列表
 * @param contactType       原渠道（phone/wechat）
 * @param contactMask       脱敏原联系方式（不回显明文）
 * @param categoryAvailable 原分类是否仍可用（false = 已被运营停用，PRD §8.7 须提示重选）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record RepostDraft(
        Long sourcePostId,
        String type,
        Integer leafCategoryId,
        String title,
        Double price,
        String priceUnit,
        String description,
        Map<String, Object> attributes,
        Double lng,
        Double lat,
        String address,
        Boolean addressPrecise,
        List<String> mediaIds,
        String contactType,
        String contactMask,
        boolean categoryAvailable) {
}
