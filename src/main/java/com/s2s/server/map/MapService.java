package com.s2s.server.map;

import com.s2s.server.category.CategoryService;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.constants.NfrCache;
import com.s2s.server.common.constants.NfrPerf;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.map.dto.AuthorBrief;
import com.s2s.server.map.dto.ClusterItem;
import com.s2s.server.map.dto.PinsCompactResponse;
import com.s2s.server.map.dto.PostCard;
import com.s2s.server.map.dto.SearchPostsResponse;
import com.s2s.server.map.mapper.MapPostMapper;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Pattern;
import org.springframework.stereotype.Service;

/**
 * 地图域服务（[126]；详设 §5.4）。
 *
 * <p>职责：承载 {@code GET /map/pins}（覆盖索引查询 + 紧凑序列化）与
 * {@code GET /posts/search}（列表检索）的业务逻辑。核心口径：</p>
 * <ul>
 *   <li>缓存键五要素（分类 ID/供需态/半径档/坐标网格/数据版本号）任一缺失回
 *       {@code 40001}，不做默认值兜底（详设 §5.4.4）；</li>
 *   <li>半径档→网格展开：每向 {@code ±ceil(半径km / 网格边长km)} 格，{@code city} 不过滤网格；</li>
 *   <li>聚合模式按 {@code zoom} 换算 metersPerPixel 与阈值比较（按 zoom 非点数）；</li>
 *   <li>分类树版本不一致不报错，仅在响应附 {@code category_version_stale}（详设 §5.4.5）。</li>
 * </ul>
 */
@Service
public class MapService {

    /** grid_id 正则：{@code ^-?\d+_-?\d+$}（openapi {@code GridId}）。 */
    private static final Pattern GRID_ID_PATTERN = Pattern.compile("^-?\\d+_-?\\d+$");

    /** 半径档合法值（openapi {@code RadiusEnum}）。 */
    private static final Set<String> RADIUS_VALUES = Set.of("1", "3", "5", "10", "city");

    /** 供需态合法值（openapi {@code PostTypeEnum}）。 */
    private static final Set<String> POST_TYPES = Set.of("resource", "demand");

    /** 列表排序合法值（openapi {@code sort}）。 */
    private static final Set<String> SORT_VALUES = Set.of("distance", "publish_time", "completeness");

    /** 聚合模式字面量。 */
    private static final String MODE_PIN = "pin";
    private static final String MODE_CLUSTER = "cluster";

    /** pins 的固定列序声明（openapi {@code PinsCompactResponse.schema}）。 */
    private static final List<String> PIN_SCHEMA =
            List.of("id", "lng", "lat", "category_id", "type", "completeness_level");

    /** Web Mercator：zoom 0 的每像素米数（地球周长 / 256 瓦片像素）。 */
    private static final double METERS_PER_PIXEL_AT_ZOOM_0 = 156543.03392;

    /** 地球平均半径（米），Haversine 距离计算用。 */
    private static final double EARTH_RADIUS_METERS = 6371000.0;

    private final MapPostMapper mapPostMapper;
    private final CategoryService categoryService;

    /**
     * 构造地图域服务。
     *
     * @param mapPostMapper   map 只读查询 Mapper
     * @param categoryService 分类树服务（提供版本协商）
     */
    public MapService(MapPostMapper mapPostMapper, CategoryService categoryService) {
        this.mapPostMapper = mapPostMapper;
        this.categoryService = categoryService;
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
     * @return 图钉紧凑响应
     */
    public PinsCompactResponse getPins(List<Integer> categoryIds, String postType, String radius,
            String gridId, String categoryVersion, Double lng, Double lat, Double zoom) {
        validatePinsParams(categoryIds, postType, radius, gridId, categoryVersion, lng, lat, zoom);

        List<String> gridIds = expandGridCells(gridId, radius);
        boolean stale = categoryService.isVersionStale(categoryVersion);
        String mode = resolveMode(zoom, lat);

        if (MODE_CLUSTER.equals(mode)) {
            List<ClusterItem> clusters = mapPostMapper.selectClusters(
                            gridIds, categoryIds, postType, NfrPerf.RENDER_MAX_PINS).stream()
                    .map(this::toCluster)
                    .toList();
            int total = clusters.stream().mapToInt(ClusterItem::count).sum();
            return new PinsCompactResponse(mode, null, null, clusters, total, stale);
        }

        List<List<Object>> pins = mapPostMapper.selectPins(
                        gridIds, categoryIds, postType, NfrPerf.RENDER_MAX_PINS).stream()
                .map(this::toPin)
                .toList();
        long total = mapPostMapper.countPins(gridIds, categoryIds, postType);
        return new PinsCompactResponse(mode, PIN_SCHEMA, pins, null, (int) total, stale);
    }

    /**
     * 列表检索（与地图同源筛选条件）。
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
     * @param page            页码（从 1 起，缺省 1）
     * @param pageSize        每页条数（缺省/上限见 NfrApi）
     * @return 分页列表检索响应
     */
    public SearchPostsResponse searchPosts(List<Integer> categoryIds, String postType, String radius,
            String gridId, String categoryVersion, Double lng, Double lat,
            String keyword, String sort, Integer page, Integer pageSize) {
        validateSearchParams(categoryIds, postType, radius, gridId, categoryVersion, lng, lat, sort);

        List<String> gridIds = expandGridCells(gridId, radius);
        boolean stale = categoryService.isVersionStale(categoryVersion);
        String normalizedKeyword = keyword == null || keyword.isBlank() ? null : keyword.trim();
        String resolvedSort = sort == null || sort.isBlank() ? "distance" : sort;
        int resolvedPage = page == null ? 1 : page;
        int resolvedPageSize = pageSize == null ? NfrApi.PAGE_SIZE_DEFAULT : pageSize;

        List<Map<String, Object>> rows = mapPostMapper.selectSearchPosts(
                gridIds, categoryIds, postType, normalizedKeyword);
        // 用可变 ArrayList 承载，sortCards 需原地排序（Stream.toList() 返回不可变列表）。
        List<PostCard> cards = new ArrayList<>(
                rows.stream().map(row -> toCard(row, lng, lat, resolvedSort)).toList());
        sortCards(cards, resolvedSort);

        int total = cards.size();
        int from = (resolvedPage - 1) * resolvedPageSize;
        int to = Math.min(from + resolvedPageSize, total);
        List<PostCard> pageItems = from >= total ? List.of() : cards.subList(from, to);

        return new SearchPostsResponse(pageItems, total, resolvedPage, resolvedPageSize, stale);
    }

    /**
     * 校验 /map/pins 入参：五要素 + 视野中心 + 缩放级别齐全且合法，否则回 40001。
     *
     * @param categoryIds     分类 ID 列表
     * @param postType        供需态
     * @param radius          半径档
     * @param gridId          坐标网格
     * @param categoryVersion 分类树版本号
     * @param lng             视野中心经度
     * @param lat             视野中心纬度
     * @param zoom            缩放级别
     */
    private void validatePinsParams(List<Integer> categoryIds, String postType, String radius,
            String gridId, String categoryVersion, Double lng, Double lat, Double zoom) {
        validateFiveElements(categoryIds, postType, radius, gridId, categoryVersion);
        if (lng == null || lat == null || zoom == null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
    }

    /**
     * 校验 /posts/search 入参（与 /map/pins 共用五要素，另校验排序枚举）。
     *
     * @param categoryIds     分类 ID 列表
     * @param postType        供需态
     * @param radius          半径档
     * @param gridId          坐标网格
     * @param categoryVersion 分类树版本号
     * @param lng             视野中心经度
     * @param lat             视野中心纬度
     * @param sort            排序方式
     */
    private void validateSearchParams(List<Integer> categoryIds, String postType, String radius,
            String gridId, String categoryVersion, Double lng, Double lat, String sort) {
        validateFiveElements(categoryIds, postType, radius, gridId, categoryVersion);
        if (lng == null || lat == null) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (sort != null && !sort.isBlank() && !SORT_VALUES.contains(sort)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
    }

    /**
     * 校验缓存键五要素（分类 ID/供需态/半径档/坐标网格/数据版本号），任一缺失回 40001。
     *
     * @param categoryIds     分类 ID 列表
     * @param postType        供需态
     * @param radius          半径档
     * @param gridId          坐标网格
     * @param categoryVersion 分类树版本号
     */
    private void validateFiveElements(List<Integer> categoryIds, String postType, String radius,
            String gridId, String categoryVersion) {
        if (categoryIds == null || categoryIds.isEmpty()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (postType == null || !POST_TYPES.contains(postType)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (radius == null || !RADIUS_VALUES.contains(radius)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (gridId == null || !GRID_ID_PATTERN.matcher(gridId).matches()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (categoryVersion == null || categoryVersion.isBlank()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
    }

    /**
     * 按半径档把中心网格展开为邻域网格集合。
     *
     * <p>每向 {@code ±ceil(半径km / 网格边长km)} 格（网格边长见
     * {@link NfrCache#KEY_GRID_METERS}，约 500m）。{@code city} 返回 {@code null}，
     * 由查询跳过 {@code grid_id} 过滤（全城）。</p>
     *
     * @param gridId 中心网格 {@code "gx_gy"}
     * @param radius 半径档（1/3/5/10/city）
     * @return 邻域网格集合；全城为 {@code null}
     */
    private List<String> expandGridCells(String gridId, String radius) {
        if ("city".equals(radius)) {
            return null;
        }
        int radiusKm = Integer.parseInt(radius);
        int n = (int) Math.ceil(radiusKm * 1000.0 / NfrCache.KEY_GRID_METERS);
        String[] parts = gridId.split("_");
        long gx = Long.parseLong(parts[0]);
        long gy = Long.parseLong(parts[1]);
        List<String> cells = new ArrayList<>();
        for (long dx = -n; dx <= n; dx++) {
            for (long dy = -n; dy <= n; dy++) {
                cells.add((gx + dx) + "_" + (gy + dy));
            }
        }
        return cells;
    }

    /**
     * 由 zoom 换算 metersPerPixel 并与阈值比较，决定聚合模式。
     *
     * <p>公式（Web Mercator）：{@code metersPerPixel = 156543.03392 * cos(lat) / 2^zoom}。
     * 远景（大于阈值）→ {@code cluster}（服务端预聚合）；近景 → {@code pin}（客户端聚合）。</p>
     *
     * @param zoom 缩放级别
     * @param lat  视野中心纬度（cos 修正）
     * @return 聚合模式字面量
     */
    private String resolveMode(double zoom, double lat) {
        double metersPerPixel = METERS_PER_PIXEL_AT_ZOOM_0
                * Math.cos(Math.toRadians(lat)) / Math.pow(2, zoom);
        return metersPerPixel > NfrPerf.CLUSTER_MODE_SWITCH_METERS_PER_PIXEL
                ? MODE_CLUSTER : MODE_PIN;
    }

    /**
     * 将 Pin 查询行序列化为紧凑数组 {@code [id, lng, lat, category_id, type, completeness_level]}。
     *
     * @param row 覆盖索引查询结果行（列名：id/lng/lat/leaf_category_id/type/completeness_level）
     * @return 6 元素紧凑数组
     */
    private List<Object> toPin(Map<String, Object> row) {
        long id = ((Number) row.get("id")).longValue();
        double lng = toCoord(row.get("lng"));
        double lat = toCoord(row.get("lat"));
        int categoryId = ((Number) row.get("leaf_category_id")).intValue();
        int typeCode = "demand".equals(row.get("type")) ? 1 : 0;
        int completenessLevel = ((Number) row.get("completeness_level")).intValue();
        return List.of(id, lng, lat, categoryId, typeCode, completenessLevel);
    }

    /**
     * 将服务端预聚合查询行映射为 {@link ClusterItem}。
     *
     * @param row 聚合查询结果行（列名：lng/lat/count）
     * @return 聚合点单元
     */
    private ClusterItem toCluster(Map<String, Object> row) {
        double lng = toCoord(row.get("lng"));
        double lat = toCoord(row.get("lat"));
        int count = ((Number) row.get("count")).intValue();
        return new ClusterItem(lng, lat, count, null);
    }

    /**
     * 将列表检索查询行映射为 {@link PostCard}（作者摘要取自 JOIN 的 user 列）。
     *
     * @param row      检索结果行（列名见 mapper 注释）
     * @param lng      视野中心经度（distance 排序时计算距离）
     * @param lat      视野中心纬度
     * @param sort     排序方式（决定 distance_m 是否有值）
     * @return 卡片项
     */
    private PostCard toCard(Map<String, Object> row, Double lng, Double lat, String sort) {
        AuthorBrief author = new AuthorBrief(
                ((Number) row.get("author_id")).longValue(),
                (String) row.get("nickname"),
                (String) row.get("avatar_url"),
                (String) row.get("realname_status"),
                List.of());

        Integer distanceM = null;
        if ("distance".equals(sort)) {
            distanceM = haversineMeters(lat, lng, toCoord(row.get("lat")), toCoord(row.get("lng")));
        }

        return new PostCard(
                ((Number) row.get("id")).longValue(),
                (String) row.get("type"),
                ((Number) row.get("leaf_category_id")).intValue(),
                ((Number) row.get("l2_category_id")).intValue(),
                (String) row.get("title"),
                (String) row.get("summary"),
                null,
                toCoord(row.get("lng")),
                toCoord(row.get("lat")),
                distanceM,
                ((Number) row.get("completeness_level")).intValue(),
                ((LocalDateTime) row.get("publish_at")).toInstant(ZoneOffset.UTC),
                author);
    }

    /**
     * 按排序方式对卡片列表排序。
     *
     * @param cards 卡片列表
     * @param sort  排序方式（distance/publish_time/completeness）
     */
    private void sortCards(List<PostCard> cards, String sort) {
        switch (sort) {
            case "publish_time" -> cards.sort(Comparator.comparing(PostCard::publishAt).reversed());
            case "completeness" -> cards.sort(
                    Comparator.comparing(PostCard::completenessLevel).reversed()
                            .thenComparing(PostCard::publishAt).reversed());
            default -> cards.sort(Comparator.comparingInt(c -> c.distanceM() == null
                    ? Integer.MAX_VALUE : c.distanceM()));
        }
    }

    /**
     * 将 DECIMAL 坐标截位到 {@link NfrPerf#MAP_PIN_COORD_DECIMALS} 位并转 double。
     *
     * @param value 坐标值（BigDecimal）
     * @return 截位后的 double
     */
    private double toCoord(Object value) {
        return ((BigDecimal) value).setScale(NfrPerf.MAP_PIN_COORD_DECIMALS, RoundingMode.HALF_UP)
                .doubleValue();
    }

    /**
     * Haversine 球面距离（米）。
     *
     * @param lat1 点 1 纬度
     * @param lng1 点 1 经度
     * @param lat2 点 2 纬度
     * @param lng2 点 2 经度
     * @return 两点球面距离，四舍五入到米
     */
    private int haversineMeters(double lat1, double lng1, double lat2, double lng2) {
        double dLat = Math.toRadians(lat2 - lat1);
        double dLng = Math.toRadians(lng2 - lng1);
        double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
                + Math.cos(Math.toRadians(lat1)) * Math.cos(Math.toRadians(lat2))
                * Math.sin(dLng / 2) * Math.sin(dLng / 2);
        double c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return (int) Math.round(EARTH_RADIUS_METERS * c);
    }
}
