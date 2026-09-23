package com.s2s.server.map;

import com.s2s.server.map.dto.PinsCompactResponse;
import com.s2s.server.map.dto.SearchPostsResponse;
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

    /**
     * 构造地图域控制器。
     *
     * @param mapService 地图域服务
     */
    public MapController(MapService mapService) {
        this.mapService = mapService;
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
            @RequestParam(required = false) Double zoom) {
        return mapService.getPins(categoryIds, postType, radius, gridId, categoryVersion,
                lng, lat, zoom);
    }

    /**
     * 列表检索（与地图同源筛选条件，返回带完整卡片字段的分页列表）。
     *
     * @param categoryIds     分类 ID 列表
     * @param postType        供需态
     * @param radius          半径档
     * @param gridId          坐标网格
     * @param categoryVersion 分类树版本号
     * @param lng             视野中心经度
     * @param lat             视野中心纬度
     * @param keyword         关键词（可空）
     * @param sort            排序方式（distance/publish_time/completeness，缺省 distance）
     * @param page            页码（从 1 起）
     * @param pageSize        每页条数
     * @return {@link SearchPostsResponse}
     */
    @GetMapping("/posts/search")
    public SearchPostsResponse searchPosts(
            @RequestParam(name = "category_ids", required = false) List<Integer> categoryIds,
            @RequestParam(name = "post_type", required = false) String postType,
            @RequestParam(required = false) String radius,
            @RequestParam(name = "grid_id", required = false) String gridId,
            @RequestParam(name = "category_version", required = false) String categoryVersion,
            @RequestParam(required = false) Double lng,
            @RequestParam(required = false) Double lat,
            @RequestParam(required = false) String keyword,
            @RequestParam(required = false) String sort,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        return mapService.searchPosts(categoryIds, postType, radius, gridId, categoryVersion,
                lng, lat, keyword, sort, page, pageSize);
    }
}
