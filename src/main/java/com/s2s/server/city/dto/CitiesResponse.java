package com.s2s.server.city.dto;

import com.fasterxml.jackson.annotation.JsonProperty;
import java.util.List;

/**
 * 可选城市列表 DTO（对齐 openapi {@code CitiesResponse} schema）。
 *
 * <p>承载 {@code GET /cities} 的响应数据，由 {@code ResponseBodyWrapper} 统一套壳
 * {@code ApiResponse}。</p>
 */
public class CitiesResponse {

    /** 城市列表。 */
    private List<CityItem> cities;

    public CitiesResponse() {
    }

    public CitiesResponse(List<CityItem> cities) {
        this.cities = cities;
    }

    @JsonProperty("cities")
    public List<CityItem> getCities() {
        return cities;
    }

    public void setCities(List<CityItem> cities) {
        this.cities = cities;
    }
}
