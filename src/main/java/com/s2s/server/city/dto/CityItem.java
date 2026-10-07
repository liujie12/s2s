package com.s2s.server.city.dto;

import com.fasterxml.jackson.annotation.JsonProperty;

/**
 * 城市条目 DTO（对齐 openapi {@code CityItem} schema）。
 *
 * <p>定位三态（PRD §6.4.4）「手动选择城市」出口的数据项。{@code adcode} 为行政区划
 * 代码（稳定标识），{@code lat}/{@code lng} 为城市中心坐标（GCJ-02），仅用于确定
 * 地图中心，不在客户端做行政区过滤（DEC-24）。</p>
 */
public class CityItem {

    /** 行政区划代码（稳定标识）。 */
    private String adcode;

    /** 城市名称。 */
    private String name;

    /** 城市中心纬度（GCJ-02）。 */
    private double lat;

    /** 城市中心经度（GCJ-02）。 */
    private double lng;

    public CityItem() {
    }

    public CityItem(String adcode, String name, double lat, double lng) {
        this.adcode = adcode;
        this.name = name;
        this.lat = lat;
        this.lng = lng;
    }

    @JsonProperty("adcode")
    public String getAdcode() {
        return adcode;
    }

    public void setAdcode(String adcode) {
        this.adcode = adcode;
    }

    @JsonProperty("name")
    public String getName() {
        return name;
    }

    public void setName(String name) {
        this.name = name;
    }

    @JsonProperty("lat")
    public double getLat() {
        return lat;
    }

    public void setLat(double lat) {
        this.lat = lat;
    }

    @JsonProperty("lng")
    public double getLng() {
        return lng;
    }

    public void setLng(double lng) {
        this.lng = lng;
    }
}
