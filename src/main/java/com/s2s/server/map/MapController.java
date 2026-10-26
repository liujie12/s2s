package com.s2s.server.map;

import com.s2s.server.auth.SettingService;
import com.s2s.server.common.web.AuthContext;
import com.s2s.server.map.dto.PinsCompactResponse;
import com.s2s.server.map.dto.SearchPostsResponse;
import jakarta.servlet.http.HttpServletRequest;
import java.math.BigDecimal;
import java.util.List;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 地图域控制器（[126]；详设 §5.4）。
 *
 * <p>职责：承载 map 域 HTTP 入口——{@code GET /map/pins}（地图图钉紧凑集合）、
 * {@code GET /posts/search}（列表检索）。两个接口均游客可访问（无 {@code Authorization}
 * 头即游客态，鉴权在横切链完成，见 {@code AuthInterceptor}）。</p>
 *
 * <p>入参全部 {@code required=false} 再交 {@code MapService} 显式校验：五要素缺失回
 * {@code 40001}（详设 §5.4.4 不做默认值兜底），正则/枚举非法同样回 {@code 40001}。
 * 返回 DTO 由 {@code ResponseBodyWrapper} 统一套壳。</p>
 */
@RestController
public class MapController {

    private final MapService mapService;
    private final SettingService settingService;

    /**
     * 构造地图域控制器。
     *
     * @param mapService     地图域服务
     * @param settingService 设置域服务（读「个性化排序」开关，游客/缺省视为开启）
     */
    public MapController(MapService mapService, SettingService settingService) {
        this.mapService = mapService;
        this.settingService = settingService;
    }

    /**
     * 拉取地图图钉集合（紧凑数组格式）。
     *
     * @param categoryIds     分类 ID 列表（缓存键要素 1）
     * @param postType        供需态（缓存键要素 2）
     * @param radius          半径档（缓存键要素 3）
     * @param gridId          约 500m 坐标网格（缓存键要素 4）
     * @param categoryVersion 分类树版本号（缓存键要素 5）
     * @param lng             视野中心经度（GCJ-02）
     * @param lat             视野中心纬度（GCJ-02）
     * @param zoom            地图缩放级别（决定 cluster/pin 模式）
     * @param priceMin        价格下限（元，可空；语义搜索一次性收窄）
     * @param priceMax        价格上限（元，可空；设置时面议被排除）
     * @param communityId     小区实体 ID（可空；口语地址精确过滤）
     * @return {@link PinsCompactResponse}
     */
    @GetMapping("/map/pins")
    public PinsCompactResponse getMapPins(
            @RequestParam(name = "category_ids", required = false) List<Integer> categoryIds,
            @RequestParam(name = "post_type", required = false) String postType,
            @RequestParam(required = false) String radius,
            @RequestParam(name = "grid_id", required = false) String gridId,
            @RequestParam(name = "category_version", required = false) String categoryVersion,
            @RequestParam(required = false) Double lng,
            @RequestParam(required = false) Double lat,
            @RequestParam(required = false) Double zoom,
            @RequestParam(name = "price_min", required = false) BigDecimal priceMin,
            @RequestParam(name = "price_max", required = false) BigDecimal priceMax,
            @RequestParam(name = "community_id", required = false) String communityId) {
        return mapService.getPins(categoryIds, postType, radius, gridId, categoryVersion,
                lng, lat, zoom, priceMin, priceMax, communityId);
    }

    /**
     * 列表检索（与地图同源筛选条件，返回带完整卡片字段的分页列表）。
     *
     * @param categoryIds     分类 ID 列表
     * @param postTypes       供需态（1–2 个；多值走一次查询，排序与分页才是全局的）
     * @param radius          半径档
     * @param gridId          坐标网格
     * @param categoryVersion 分类树版本号
     * @param lng             视野中心经度
     * @param lat             视野中心纬度
     * @param priceMin        价格下限（元，可空）
     * @param priceMax        价格上限（元，可空；设置时面议被排除）
     * @param communityId     小区实体 ID（可空；与 `/map/pins` 同口径）
     * @param keyword         关键词（可空）
     * @param sort            排序方式（六值，缺省 distance；见 openapi `/posts/search`）
     * @param page            页码（从 1 起）
     * @param pageSize        每页条数
     * @return {@link SearchPostsResponse}
     */
    @GetMapping("/posts/search")
    public SearchPostsResponse searchPosts(
            HttpServletRequest http,
            @RequestParam(name = "category_ids", required = false) List<Integer> categoryIds,
            @RequestParam(name = "post_type", required = false) List<String> postTypes,
            @RequestParam(required = false) String radius,
            @RequestParam(name = "grid_id", required = false) String gridId,
            @RequestParam(name = "category_version", required = false) String categoryVersion,
            @RequestParam(required = false) Double lng,
            @RequestParam(required = false) Double lat,
            @RequestParam(name = "price_min", required = false) BigDecimal priceMin,
            @RequestParam(name = "price_max", required = false) BigDecimal priceMax,
            @RequestParam(name = "community_id", required = false) String communityId,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        // 游客可访问 → userId 可能为 null；仅用于「空圈入队」的线索归属（PRD §6.4.4）
        Long userId = AuthContext.currentUserId(http);
        // 个性化排序开关（2026-10-23）：关闭后 composite 回落 distance，见 MapService 重载说明
        boolean personalizedEnabled = settingService.isPersonalizedRecommendEnabled(userId);
        return mapService.searchPosts(categoryIds, postTypes, radius, gridId, categoryVersion,
                lng, lat, priceMin, priceMax, communityId, keyword, sort, page, pageSize, userId,
                personalizedEnabled);
    }
}
