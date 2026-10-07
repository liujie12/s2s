package com.s2s.server.city;

import static org.assertj.core.api.Assertions.assertThat;

import com.s2s.server.city.dto.CitiesResponse;
import com.s2s.server.city.dto.CityItem;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link CityService} 城市列表测试（[132]；PRD §6.4.4）。
 *
 * <p>覆盖场景：
 * <ol>
 *   <li>列表非空且含试点城市杭州（adcode 330100）；</li>
 *   <li>条目字段完整且坐标合法（lat ∈ [-90,90]、lng ∈ [-180,180]）。</li>
 * </ol>
 */
class CityServiceTest {

    private CityService cityService;

    /**
     * 每测前置：装配被测服务。
     *
     * @return void
     */
    @BeforeEach
    void setUp() {
        cityService = new CityService();
    }

    /**
     * 列表非空且含试点城市杭州。
     *
     * @return void
     */
    @Test
    void listCities_containsHangzhou() {
        CitiesResponse result = cityService.listCities();

        assertThat(result.getCities()).isNotEmpty();
        assertThat(result.getCities())
                .anyMatch(c -> "杭州".equals(c.getName()) && "330100".equals(c.getAdcode()));
    }

    /**
     * 条目字段完整且坐标合法。
     *
     * @return void
     */
    @Test
    void listCities_itemsHaveCompleteFields() {
        CitiesResponse result = cityService.listCities();

        for (CityItem city : result.getCities()) {
            assertThat(city.getAdcode()).isNotBlank();
            assertThat(city.getName()).isNotBlank();
            assertThat(city.getLat()).isGreaterThanOrEqualTo(-90.0).isLessThanOrEqualTo(90.0);
            assertThat(city.getLng()).isGreaterThanOrEqualTo(-180.0).isLessThanOrEqualTo(180.0);
        }
    }
}
