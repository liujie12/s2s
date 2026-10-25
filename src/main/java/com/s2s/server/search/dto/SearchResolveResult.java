package com.s2s.server.search.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;
import java.math.BigDecimal;
import java.util.List;
import java.util.Map;

/**
 * 语义搜索槽位卡（{@code POST /search/resolve} 响应 data）。
 *
 * <p>一次性、可撤销：前端只把本对象作为临时搜索态，不写入持久筛选。
 * 每个槽位在 {@code sources} 标明来源（vocab/ai/poi/anchor/current），
 * 越界或无法确定的值进 {@code unresolvedFields}，前端以灰态「没敢用」回显。</p>
 *
 * @param transcript             语音转写文本（无语音时为 null）
 * @param postType               供需方向（resource/demand，可空）
 * @param leafCategoryIds        命中的叶子类目 ID 集合（空集合表示未收窄类目）
 * @param categoryLabels         叶子类目显示名（与 ID 同序，供 chip 回显）
 * @param radius                 半径档（1/3/5/10/city，可空）
 * @param radiusMeters           真实半径米数（city 档为 null，用于按真实米数画圈与精裁）
 * @param anchorLng              地点锚点经度（可空）
 * @param anchorLat              地点锚点纬度（可空）
 * @param anchorName             地点名称（POI 命中时有值）
 * @param anchorSource           锚点来源：text/poi/long_press/current（可空）
 * @param communityId            小区实体 ID（高置信时自动采用，用于精确过滤）
 * @param communityName          小区规范名（回显用）
 * @param communityCandidates    低置信时的小区候选（供用户点选）
 * @param priceMin               价格下限（元，可空）
 * @param priceMax               价格上限（元，可空）
 * @param priceExcludesNegotiable 设置价格上限时面议（price IS NULL）被排除
 * @param unresolvedFields       未敢采用/无法解析的字段名（如 location/price）
 * @param sources                各槽位来源标记（字段名 → vocab/ai/poi/anchor/current）
 * @param queryText              归一化后的解析输入
 * @param aiUsed                 是否采用了 AI 解析结果（缓存命中也算 true）
 * @param degraded               AI 不可用/超时，已降级为词表解析
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record SearchResolveResult(
        String transcript,
        String postType,
        List<Integer> leafCategoryIds,
        List<String> categoryLabels,
        String radius,
        Integer radiusMeters,
        Double anchorLng,
        Double anchorLat,
        String anchorName,
        String anchorSource,
        String communityId,
        String communityName,
        List<CommunityCandidateDto> communityCandidates,
        BigDecimal priceMin,
        BigDecimal priceMax,
        boolean priceExcludesNegotiable,
        List<String> unresolvedFields,
        Map<String, String> sources,
        String normalizedText,
        boolean aiUsed,
        boolean degraded) {
}
