package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;
import java.util.Map;

/**
 * 编辑帖子载荷（[B2-8]；对应 openapi {@code PostUpdateRequest}、{@code PATCH /posts/{post_id}}）。
 *
 * <p>字段集与 {@link PostCreateRequest} 一致，另带 {@code version} 乐观锁；
 * 两处差异（安全收窄，PRD §8.4「进发布页编辑态」+ 安全方案 §4.6 出口收敛）：</p>
 * <ul>
 *   <li>{@code contactType}/{@code contactValue} <b>可空</b>：合同唯一明文出口是
 *       {@code GET /posts/{id}/contact}，编辑接口不回显亦不要求重填 ——
 *       {@code contactValue} 为 {@code null}/空表示<b>保留原密文不改</b>；</li>
 *   <li>{@code version} 必带：不符/非本人/行不存在/非在架一律 {@code 40903}（0 行不区分成因）。</li>
 * </ul>
 *
 * @param version        乐观锁版本号（必填，取自列表/详情出参）
 * @param type           类型（resource/demand，必填）
 * @param leafCategoryId 叶子类目 ID（必填）
 * @param title          标题（必填，maxLength 40）
 * @param price          价格（元；null = 面议）
 * @param priceUnit      价格单位
 * @param description    描述正文（maxLength 500）
 * @param attributes     动态属性
 * @param lng            GCJ-02 经度（必填）
 * @param lat            GCJ-02 纬度（必填）
 * @param address        门牌号地址
 * @param addressPrecise 地址是否精确到门牌
 * @param mediaIds       媒体 ID 列表（maxItems 9）
 * @param contactType    联系方式渠道（可空 = 保留原渠道）
 * @param contactValue   联系方式值（可空 = 保留原密文不改）
 * @param certIds        资质栏挂载结果（{@code null} = 本次不改动；空列表 = 取消全部挂载）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostUpdateRequest(
        @NotNull Long version,
        @NotBlank String type,
        @NotNull Integer leafCategoryId,
        @NotBlank @Size(max = 40) String title,
        Double price,
        String priceUnit,
        @Size(max = 500) String description,
        Map<String, Object> attributes,
        @NotNull Double lng,
        @NotNull Double lat,
        @Size(max = 120) String address,
        Boolean addressPrecise,
        @Size(max = 9) List<String> mediaIds,
        String contactType,
        @Size(max = 64) String contactValue,
        List<Long> certIds) {
}
