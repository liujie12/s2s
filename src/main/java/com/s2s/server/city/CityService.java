package com.s2s.server.city;

import com.s2s.server.city.dto.CitiesResponse;
import com.s2s.server.city.dto.CityItem;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 城市服务（[132]；PRD §6.4.4「手动选择城市」数据源）。
 *
 * <p>职责：返回可选城市列表（{@code GET /cities}）。试点期为静态城市表——
 * 单城试点 = 杭州，本列表仅作定位三态的「手动选城市」兜底出口，选中城市用于
 * 确定地图中心与 {@code radius=city} 请求入参，不在客户端做行政区过滤
 * （DEC-24 裁定「后端补 /cities 接口」）。</p>
 *
 * <p>后续若引入真实行政区划数据源（城市表或第三方逆地理），替换点集中在本类的
 * [CITIES] 常量，对外契约与调用方不变。</p>
 */
@Service
public class CityService {

    /** 试点期静态城市表：adcode、名称、城市中心（GCJ-02，近似值）。 */
    private static final List<CityItem> CITIES = List.of(
            new CityItem("110000", "北京", 39.9087, 116.3975),
            new CityItem("310000", "上海", 31.2304, 121.4737),
            new CityItem("440100", "广州", 23.1291, 113.2644),
            new CityItem("440300", "深圳", 22.5431, 114.0579),
            new CityItem("330100", "杭州", 30.2741, 120.1551),
            new CityItem("510100", "成都", 30.5728, 104.0668),
            new CityItem("420100", "武汉", 30.5928, 114.3055),
            new CityItem("610100", "西安", 34.3416, 108.9398),
            new CityItem("500000", "重庆", 29.5630, 106.5516),
            new CityItem("320100", "南京", 32.0603, 118.7969),
            new CityItem("320500", "苏州", 31.2989, 120.5853),
            new CityItem("120000", "天津", 39.0851, 117.1994)
    );

    /**
     * 返回可选城市列表。
     *
     * @return {@link CitiesResponse} 城市列表
     */
    public CitiesResponse listCities() {
        return new CitiesResponse(CITIES);
    }
}
