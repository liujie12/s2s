package com.s2s.server.map;

import com.s2s.server.category.CategoryService;
import com.s2s.server.common.constants.NfrApi;
import com.s2s.server.common.constants.NfrCache;
import com.s2s.server.common.constants.NfrPerf;
import com.s2s.server.common.dto.AuthorBrief;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.map.dto.ClusterItem;
import com.s2s.server.map.dto.PinsCompactResponse;
import com.s2s.server.map.dto.PostCard;
import com.s2s.server.map.dto.SearchPostsResponse;
import com.s2s.server.map.mapper.MapPostMapper;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Duration;
import java.time.Instant;
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

    /** 列表排序合法值（openapi {@code sort}；2026-10-08 由三值扩展为六值）。 */
    private static final Set<String> SORT_VALUES = Set.of("distance", "publish_time", "completeness",
            "composite", "price_asc", "price_desc");

    /** 综合排序的距离归一化上界（米）：范围最大档 10km 的一倍余量（与客户端同口径）。 */
    private static final int MAX_COMPOSITE_DISTANCE_M = 20000;

    /** 综合排序的时效归一化上界（分钟）：7 天，与 §6.4.4 兜底口径一致。 */
    private static final long MAX_COMPOSITE_AGE_MINUTES = 7L * 24 * 60;

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
                rows.stream().map(row -> toCard(row, lng, lat)).toList());
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
     * @param lng      视野中心经度（用于计算 distance_m）
     * @param lat      视野中心纬度
     * @return 卡片项
     */
    private PostCard toCard(Map<String, Object> row, Double lng, Double lat) {
        AuthorBrief author = new AuthorBrief(
                ((Number) row.get("author_id")).longValue(),
                (String) row.get("nickname"),
                (String) row.get("avatar_url"),
                (String) row.get("realname_status"),
                List.of());

        // 距离一律计算：列表卡片要展示距离（PRD §6.4.3），composite 排序也依赖它。
        // 原先仅在 distance 排序时计算，会让其它排序下的卡片缺距离（契约虽可空，
        // 但「换个排序距离就消失」在界面上是明显缺陷）。
        Integer distanceM = haversineMeters(lat, lng, toCoord(row.get("lat")), toCoord(row.get("lng")));

        return new PostCard(
                ((Number) row.get("id")).longValue(),
                (String) row.get("type"),
                ((Number) row.get("leaf_category_id")).intValue(),
                ((Number) row.get("l2_category_id")).intValue(),
                (String) row.get("title"),
                (String) row.get("summary"),
                null,
                (BigDecimal) row.get("price"),
                (String) row.get("price_unit"),
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
     * <p>契约 {@code sort} 六值（openapi {@code /posts/search}，2026-10-08 由三值扩展）：
     * {@code distance} / {@code publish_time} / {@code completeness} /
     * {@code composite} / {@code price_asc} / {@code price_desc}。缺省与未知值走
     * {@code distance}（{@code validateSearchParams} 已挡住非法值，此处兜底只为默认档）。</p>
     *
     * @param cards 卡片列表
     * @param sort  排序方式
     */
    private void sortCards(List<PostCard> cards, String sort) {
        switch (sort) {
            case "publish_time" -> cards.sort(Comparator.comparing(PostCard::publishAt).reversed());
            case "completeness" -> cards.sort(
                    Comparator.comparing(PostCard::completenessLevel).reversed()
                            .thenComparing(PostCard::publishAt).reversed());
            case "price_asc" -> cards.sort(priceComparator(true));
            case "price_desc" -> cards.sort(priceComparator(false));
            case "composite" -> cards.sort(Comparator.comparingDouble(this::compositeScore));
            default -> cards.sort(Comparator.comparingInt(c -> c.distanceM() == null
                    ? Integer.MAX_VALUE : c.distanceM()));
        }
    }

    /**
     * 价格比较器：无价格（{@code price = null}，即「面议」）**恒沉底**（与升降序无关）。
     *
     * <p>把 null 当 0 会让「面议」在升序里霸占首屏，当极大值则会在降序里霸屏 ——
     * 两个方向都沉底，才符合「不参与价格比较」的语义（与客户端 `_comparePrice` 同口径）。</p>
     *
     * @param ascending true 升序 / false 降序
     * @return 比较器
     */
    private Comparator<PostCard> priceComparator(boolean ascending) {
        return (a, b) -> {
            BigDecimal pa = a.price();
            BigDecimal pb = b.price();
            if (pa == null && pb == null) {
                return 0;
            }
            if (pa == null) {
                return 1;
            }
            if (pb == null) {
                return -1;
            }
            return ascending ? pa.compareTo(pb) : pb.compareTo(pa);
        };
    }

    /**
     * 综合排序得分：距离与新鲜度各占一半，**越小越靠前**。
     *
     * <p>与客户端 {@code _compositeScore} 同口径：两者量纲不同（米 vs 分钟），
     * 直接相加会让换单位就翻转排序，故各自先按业务上界归一化到 0–1 再加权。
     * 上界取业务边界（距离 20km / 时效 7 天）而非样本极值 —— 用样本极值会让
     * 同一条信息的排名随其它信息的增删而跳动。</p>
     *
     * @param card 卡片
     * @return 0–1 的得分（越小越靠前）
     */
    private double compositeScore(PostCard card) {
        Integer distanceM = card.distanceM();
        double distancePart = Math.min(
                1.0,
                (distanceM == null ? MAX_COMPOSITE_DISTANCE_M : distanceM)
                        / (double) MAX_COMPOSITE_DISTANCE_M);
        long ageMinutes = Math.max(
                0, Duration.between(card.publishAt(), Instant.now()).toMinutes());
        double agePart = Math.min(1.0, ageMinutes / (double) MAX_COMPOSITE_AGE_MINUTES);
        return distancePart * 0.5 + agePart * 0.5;
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
