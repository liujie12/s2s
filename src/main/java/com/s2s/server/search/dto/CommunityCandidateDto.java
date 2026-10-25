package com.s2s.server.search.dto;

import com.fasterxml.jackson.databind.PropertyNamingStrategies;
import com.fasterxml.jackson.databind.annotation.JsonNaming;

/**
 * 小区候选（口语地址低置信时回显给用户点选）。
 *
 * @param id       小区实体 ID（高德 POI ID，落 {@code post.community_id}）
 * @param name     小区规范名
 * @param district 所属区县
 * @param lng      小区质心经度（GCJ-02）
 * @param lat      小区质心纬度（GCJ-02）
 */
@JsonNaming(PropertyNamingStrategies.SnakeCaseStrategy.class)
public record CommunityCandidateDto(String id, String name, String district, Double lng, Double lat) {
}
