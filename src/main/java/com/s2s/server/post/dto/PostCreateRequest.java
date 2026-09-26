package com.s2s.server.post.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;
import java.util.List;
import java.util.Map;

/**
 * 正式发布载荷（[125]；对应 openapi {@code PostCreateRequest}）。
 *
 * <p>在 {@link PostDraft} 基础上声明必填字段；派生字段（{@code l2_category_id}/
 * {@code completeness_level}/{@code grid_id}/{@code expire_at}/{@code version}）
 * 由服务端生成，客户端传了也被忽略。</p>
 *
 * @param type           类型（resource/demand，必填）
 * @param leafCategoryId 叶子类目 ID（必填）
 * @param title          标题（必填，maxLength 40）
 * @param price          价格（元；null 表示面议，PRD §5.8 允许为空）
 * @param priceUnit      价格单位（取模板 price_units 之一；price 为 null 时无意义）
 * @param description    描述正文（maxLength 500）
 * @param attributes     动态属性
 * @param lng            GCJ-02 经度（必填）
 * @param lat            GCJ-02 纬度（必填）
 * @param address        门牌号地址
 * @param addressPrecise 地址是否精确到门牌
 * @param mediaIds       媒体 ID 列表（maxItems 9）
 * @param contactType    联系方式渠道（必填，phone/wechat）
 * @param contactValue   联系方式值（必填，maxLength 64）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record PostCreateRequest(
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
        @NotBlank String contactType,
        @NotBlank @Size(max = 64) String contactValue) {
}
