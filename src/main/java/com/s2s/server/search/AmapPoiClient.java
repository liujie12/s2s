package com.s2s.server.search;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.config.SecretsProperties;
import com.s2s.server.common.constants.NfrSearch;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * 高德正向 POI 客户端（搜索地点锚点解析）。
 *
 * <p>职责：把「用户说出的地名」换成 GCJ-02 坐标。仅调用高德 Web 服务
 * {@code /v3/place/text}；Key 取 {@link SecretsProperties#amapKey()}，未注入时
 * <b>直接返回空</b>（不抛异常、不阻塞整条解析），由调用方回退到当前定位。</p>
 *
 * <p>结果按地名做进程内缓存（TTL/条数上限见 {@link NfrSearch}），
 * 地名解析对时效不敏感，缓存可显著减少上游调用。</p>
 */
@Component
public class AmapPoiClient {

    /** 高德正向 POI 接口地址（不含参数）。 */
    private static final String PLACE_TEXT_URL = "https://restapi.amap.com/v3/place/text";

    /** 高德输入提示接口（口语/错字地址补全）。 */
    private static final String INPUT_TIPS_URL = "https://restapi.amap.com/v3/assistant/inputtips";

    /** 高德逆地理接口（取城市 adcode 约束小区候选范围）。 */
    private static final String REGEO_URL = "https://restapi.amap.com/v3/geocode/regeo";

    /** 高德成功状态码。 */
    private static final String STATUS_OK = "1";

    private static final Logger log = LoggerFactory.getLogger(AmapPoiClient.class);

    private final SecretsProperties secrets;
    private final ObjectMapper objectMapper;
    private final HttpClient httpClient;
    private final Map<String, CacheEntry> cache = new ConcurrentHashMap<>();

    /** 输入提示结果缓存（键：城市 + 关键词）。 */
    private final Map<String, TipCacheEntry> tipCache = new ConcurrentHashMap<>();

    /** 逆地理 adcode 缓存（键：lng,lat 5 位小数）。 */
    private final Map<String, String> adcodeCache = new ConcurrentHashMap<>();

    /**
     * 构造 POI 客户端。
     *
     * @param secrets      全量凭证配置（{@code amapKey} 为可选绑定，未注入为 null）
     * @param objectMapper Jackson 反序列化器（与全仓单例复用）
     */
    public AmapPoiClient(SecretsProperties secrets, ObjectMapper objectMapper) {
        this.secrets = secrets;
        this.objectMapper = objectMapper;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(NfrSearch.POI_TIMEOUT_SECONDS))
                .build();
    }

    /**
     * 按地名做正向 POI 查询，取第一个结果的坐标。
     *
     * @param keyword 地名（已由调用方从文本中抽出的候选，非空）
     * @return {@link Optional} 命中时含坐标与名称；未配置 Key/无结果/上游失败均为空
     */
    public Optional<PoiPoint> search(String keyword) {
        String key = secrets.amapKey();
        if (key == null || keyword == null || keyword.isBlank()) {
            return Optional.empty();
        }
        String normalized = keyword.strip();
        CacheEntry cached = cache.get(normalized);
        long now = System.currentTimeMillis();
        if (cached != null && now - cached.createdAtMillis() < NfrSearch.POI_CACHE_TTL_SECONDS * 1000L) {
            return Optional.ofNullable(cached.point());
        }

        Optional<PoiPoint> point = request(normalized, key);
        if (cache.size() >= NfrSearch.POI_CACHE_MAX_ENTRIES) {
            cache.clear();
        }
        // 未命中同样缓存（null），避免对同一个查不到的地名反复打上游
        cache.put(normalized, new CacheEntry(point.orElse(null), now));
        return point;
    }

    /**
     * 发起一次正向 POI 请求并解析首个结果。
     *
     * @param keyword 地名
     * @param key     高德 Web 服务 Key
     * @return {@link Optional} 坐标与名称；任何异常都归一为空
     */
    private Optional<PoiPoint> request(String keyword, String key) {
        String url = PLACE_TEXT_URL
                + "?key=" + urlEncode(key)
                + "&keywords=" + urlEncode(keyword)
                + "&offset=1&page=1";
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(NfrSearch.POI_TIMEOUT_SECONDS))
                .GET()
                .build();
        try {
            HttpResponse<String> response = httpClient.send(request,
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() != 200) {
                log.warn("高德正向 POI 非 200：status={}", response.statusCode());
                return Optional.empty();
            }
            JsonNode root = objectMapper.readTree(response.body());
            if (!STATUS_OK.equals(root.path("status").asText())) {
                // 不打印 Key 与原始响应体（可能含 Key），只留状态
                log.warn("高德正向 POI 业务失败：infocode={}", root.path("infocode").asText());
                return Optional.empty();
            }
            JsonNode pois = root.path("pois");
            if (!pois.isArray() || pois.isEmpty()) {
                return Optional.empty();
            }
            JsonNode first = pois.get(0);
            String location = first.path("location").asText("");
            String[] lngLat = location.split(",");
            if (lngLat.length != 2) {
                return Optional.empty();
            }
            return Optional.of(new PoiPoint(
                    Double.parseDouble(lngLat[0]),
                    Double.parseDouble(lngLat[1]),
                    first.path("name").asText(keyword)));
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            log.warn("高德正向 POI 请求被中断");
            return Optional.empty();
        } catch (Exception exception) {
            // 超时/网络/JSON 结构异常统一降级：地点锚点缺失不应阻断搜索
            log.warn("高德正向 POI 请求失败：{}", exception.getClass().getSimpleName());
            return Optional.empty();
        }
    }

    /**
     * 高德输入提示：把口语/错字地址补全成候选住宅区。
     *
     * <p>为什么用 inputtips 而不是 place/text：用户说的是「北城新徽苑」这类口语，
     * inputtips 本身就是联想补全接口，配合 `type=120302`（住宅区）与城市 adcode
     * 可把候选压到小区级别；是否采用由 {@code CommunityResolver} 打分决定。</p>
     *
     * @param keyword    口语地点（非空）
     * @param cityAdcode 城市 adcode（可空；非空时 citylimit=true）
     * @return {@link List} 候选（按高德返回顺序；无 Key/无结果/失败均为空表）
     */
    public List<Tip> inputTips(String keyword, String cityAdcode) {
        String key = secrets.amapKey();
        if (key == null || keyword == null || keyword.isBlank()) {
            return List.of();
        }
        String normalized = keyword.strip();
        String cacheKey = (cityAdcode == null ? "" : cityAdcode) + "|" + normalized;
        TipCacheEntry cached = tipCache.get(cacheKey);
        long now = System.currentTimeMillis();
        if (cached != null && now - cached.createdAtMillis()
                < NfrSearch.COMMUNITY_CACHE_TTL_SECONDS * 1000L) {
            return cached.tips();
        }
        String url = INPUT_TIPS_URL
                + "?key=" + urlEncode(key)
                + "&keywords=" + urlEncode(normalized)
                + "&type=" + NfrSearch.AMAP_RESIDENTIAL_TYPE
                + (cityAdcode == null || cityAdcode.isBlank()
                        ? "" : "&city=" + urlEncode(cityAdcode) + "&citylimit=true");
        List<Tip> tips = parseTips(requestBody(url));
        if (tipCache.size() >= NfrSearch.POI_CACHE_MAX_ENTRIES) {
            tipCache.clear();
        }
        tipCache.put(cacheKey, new TipCacheEntry(tips, now));
        return tips;
    }

    /**
     * 逆地理取城市 adcode（用于约束小区候选范围）。
     *
     * @param lng 经度（GCJ-02）
     * @param lat 纬度（GCJ-02）
     * @return {@link String} 城市 adcode；无 Key/失败返回 null
     */
    public String reverseAdcode(double lng, double lat) {
        String key = secrets.amapKey();
        if (key == null) {
            return null;
        }
        String point = String.format(java.util.Locale.ROOT, "%.5f,%.5f", lng, lat);
        String cached = adcodeCache.get(point);
        if (cached != null) {
            return cached;
        }
        String url = REGEO_URL + "?key=" + urlEncode(key) + "&location=" + urlEncode(point);
        String body = requestBody(url);
        if (body == null) {
            return null;
        }
        try {
            JsonNode root = objectMapper.readTree(body);
            if (!STATUS_OK.equals(root.path("status").asText())) {
                return null;
            }
            String adcode = root.path("regeocode").path("addressComponent").path("adcode").asText("");
            if (adcode.isBlank()) {
                return null;
            }
            if (adcodeCache.size() >= NfrSearch.POI_CACHE_MAX_ENTRIES) {
                adcodeCache.clear();
            }
            adcodeCache.put(point, adcode);
            return adcode;
        } catch (Exception exception) {
            log.warn("高德逆地理解析失败：{}", exception.getClass().getSimpleName());
            return null;
        }
    }

    /**
     * 发起 GET 请求并返回响应体（统一超时/状态码/异常处理）。
     *
     * @param url 完整请求地址（含参数）
     * @return {@link String} 响应体；非 200/异常返回 null
     */
    private String requestBody(String url) {
        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(Duration.ofSeconds(NfrSearch.POI_TIMEOUT_SECONDS))
                .GET()
                .build();
        try {
            HttpResponse<String> response = httpClient.send(request,
                    HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
            if (response.statusCode() != 200) {
                log.warn("高德 Web 服务非 200：status={}", response.statusCode());
                return null;
            }
            return response.body();
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            log.warn("高德 Web 服务请求被中断");
            return null;
        } catch (Exception exception) {
            log.warn("高德 Web 服务请求失败：{}", exception.getClass().getSimpleName());
            return null;
        }
    }

    /**
     * 解析 inputtips 响应中的住宅区候选。
     *
     * @param body 响应体（可空）
     * @return {@link List} 合法候选（location 缺失的跳过）
     */
    private List<Tip> parseTips(String body) {
        if (body == null) {
            return List.of();
        }
        try {
            JsonNode root = objectMapper.readTree(body);
            if (!STATUS_OK.equals(root.path("status").asText())) {
                return List.of();
            }
            JsonNode tips = root.path("tips");
            if (!tips.isArray()) {
                return List.of();
            }
            List<Tip> result = new java.util.ArrayList<>();
            for (JsonNode tip : tips) {
                String id = tip.path("id").asText("");
                String name = tip.path("name").asText("");
                String location = tip.path("location").asText("");
                String[] lngLat = location.split(",");
                if (id.isBlank() || name.isBlank() || lngLat.length != 2) {
                    continue;
                }
                result.add(new Tip(id, name, tip.path("district").asText(""),
                        tip.path("adcode").asText(""),
                        Double.parseDouble(lngLat[0]), Double.parseDouble(lngLat[1])));
            }
            return result;
        } catch (Exception exception) {
            log.warn("高德输入提示解析失败：{}", exception.getClass().getSimpleName());
            return List.of();
        }
    }

    /**
     * URL 查询参数编码。
     *
     * @param value 原始值
     * @return {@link String} UTF-8 百分号编码结果
     */
    private String urlEncode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    /**
     * POI 命中结果。
     *
     * @param lng  GCJ-02 经度
     * @param lat  GCJ-02 纬度
     * @param name POI 名称
     */
    public record PoiPoint(double lng, double lat, String name) {
    }

    /**
     * 输入提示候选（住宅区）。
     *
     * @param id       高德 POI ID（作为 community_id 落库）
     * @param name     小区规范名
     * @param district 所属区县
     * @param adcode   区县 adcode
     * @param lng      经度（GCJ-02）
     * @param lat      纬度（GCJ-02）
     */
    public record Tip(String id, String name, String district, String adcode, double lng, double lat) {
    }

    /**
     * 输入提示缓存条目。
     *
     * @param tips            候选列表（可空表）
     * @param createdAtMillis 写入时刻（毫秒）
     */
    private record TipCacheEntry(List<Tip> tips, long createdAtMillis) {
    }

    /**
     * 进程内缓存条目。
     *
     * @param point           命中结果（null 表示「查过但没有结果」）
     * @param createdAtMillis 写入时刻（毫秒）
     */
    private record CacheEntry(PoiPoint point, long createdAtMillis) {
    }
}
