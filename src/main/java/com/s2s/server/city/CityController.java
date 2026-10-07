package com.s2s.server.city;

import com.s2s.server.city.dto.CitiesResponse;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 城市域控制器（[132]；PRD §6.4.4）。
 *
 * <p>职责：承载 city 域 HTTP 入口——{@code GET /cities}（可选城市列表）。
 * 游客可访问（无 {@code Authorization} 头即游客态，鉴权在横切链完成，见
 * {@code AuthInterceptor}）。返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳。</p>
 */
@RestController
public class CityController {

    /** 城市服务（构造注入）。 */
    private final CityService cityService;

    /**
     * 构造城市域控制器。
     *
     * @param cityService 城市服务
     */
    public CityController(CityService cityService) {
        this.cityService = cityService;
    }

    /**
     * 拉取可选城市列表。
     *
     * @return {@link CitiesResponse}
     */
    @GetMapping("/cities")
    public CitiesResponse listCities() {
        return cityService.listCities();
    }
}
