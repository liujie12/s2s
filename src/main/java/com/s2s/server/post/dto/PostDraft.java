package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.util.List;
import java.util.Map;

/**
 * 发布草稿载荷（[125]；对应 openapi {@code PostDraft}，用于 {@code POST /posts/precheck}）。
 *
 * <p>字段与 {@code PostCreateRequest} 一致但<b>全部非必填</b>（允许对半成品做预校验）。
 * 字段名用契约名（{@code description}/{@code attributes}），与 DDL 列名（{@code desc}/
 * {@code template_values}）的漂移在 Entity 层显式映射（KTD4）。</p>
 *
 * @param type           类型（resource/demand）
 * @param leafCategoryId 叶子类目 ID
 * @param title          标题（maxLength 40）
 * @param description    描述正文（maxLength 500）
 * @param attributes     动态属性，键取自模板 fields[].key，落 post.attributes JSON 列
 * @param lng            GCJ-02 经度
 * @param lat            GCJ-02 纬度
 * @param address        门牌号地址（maxLength 120）
 * @param addressPrecise 地址是否精确到门牌（completeness_level 三条件之一）
 * @param mediaIds       媒体 ID 列表（maxItems 9）
 * @param contactType    联系方式渠道（phone/wechat）
 * @param contactValue   联系方式值（maxLength 64）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostDraft(
        String type,
        Integer leafCategoryId,
        String title,
        String description,
        Map<String, Object> attributes,
        Double lng,
        Double lat,
        String address,
        Boolean addressPrecise,
        List<String> mediaIds,
        String contactType,
        String contactValue) {
}
