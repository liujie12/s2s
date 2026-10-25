package com.s2s.server.common.constants;

import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * 搜索域 NFR 常量（地图语音语义搜索 U2）。
 *
 * <p>职责：承载语义解析用到的半径档、米数映射、价格与词表边界、POI 调用、
 * AI 兜底与游客记账账号等阈值，禁在业务代码里写死数字/字面量。</p>
 */
public final class NfrSearch {

    /**
     * 契约半径档（与 openapi {@code RadiusEnum} 逐值一致，顺序即由近到远）。
     */
    public static final List<String> RADIUS_TIERS = List.of("1", "3", "5", "10", "city");

    /**
     * 半径档 → 米数映射（{@code city} 不做距离过滤，故不在此表）。
     */
    public static final Map<String, Integer> RADIUS_TIER_METERS = radiusTierMeters();

    /**
     * 全城档的契约值（不参与距离过滤）。
     */
    public static final String RADIUS_CITY = "city";

    /**
     * 价格上限合理性上限（元）。语义解析出的价格超过该值视为越界，进
     * {@code unresolved_fields}，不落到地图过滤条件上。
     */
    public static final int PRICE_MAX_REASONABLE_YUAN = 1_000_000;

    /**
     * 语义解析缓存前缀（Redis）。
     */
    public static final String AI_PARSE_CACHE_PREFIX = "search:intent";

    /**
     * 语义解析提示词版本：提示词或输出契约变更时必须递增，使旧缓存自然失效。
     */
    public static final String AI_PARSE_PROMPT_VERSION = "1";

    /**
     * 语义解析缓存 TTL（秒）。只缓存「文本 + 城市」的语义槽位，
     * 地点/小区每次按当前坐标重新解析，不随缓存返回。
     */
    public static final long AI_PARSE_CACHE_TTL_SECONDS = 3600L;

    /**
     * 游客记账账号 ID（游客 AI/ASR 的费用与配额记在该账号上，避免 userId 为空）。
     *
     * <p>取 0 是因为 `user` 表自增从 1 起，0 不会与真实用户冲突；费用台账只写
     * Redis 键，不落库，故无需真实用户行。</p>
     */
    public static final long GUEST_LEDGER_USER_ID = 0L;

    /**
     * 正向 POI 调用超时（秒）。高德 Web 服务在弱网下可能拖到数秒，超时即降级。
     */
    public static final int POI_TIMEOUT_SECONDS = 3;

    /**
     * POI 结果进程内缓存 TTL（秒）。地名解析对时效不敏感，缓存降低上游调用量。
     */
    public static final long POI_CACHE_TTL_SECONDS = 600L;

    /**
     * POI 结果缓存的最大条目数（超出后整表清空，避免无界增长）。
     */
    public static final int POI_CACHE_MAX_ENTRIES = 512;

    /**
     * 语音转写允许的最大 base64 字符数（约 2MB 音频，与 NfrMedia 单文件上限解耦：
     * 游客音频不落 OSS，直接进 JSON 请求体，必须有独立上限）。
     */
    public static final int VOICE_BASE64_MAX_LENGTH = 2_800_000;

    /**
     * 语音 MIME 缺省值（客户端 `record` 默认 AAC-LC/m4a）。
     */
    public static final String DEFAULT_VOICE_CONTENT_TYPE = "audio/mp4";

    /**
     * 中文价格最大支持位数（「十万」级），用于口语数字解析的边界。
     */
    public static final long SPOKEN_PRICE_MAX = 100_000L;

    /**
     * 小区候选返回上限（低置信时回显给用户点选，取前 N 个）。
     */
    public static final int COMMUNITY_CANDIDATE_LIMIT = 3;

    /**
     * 小区名自动采用阈值：高德候选名与口语词的归一化相似度达到该值才静默采用，
     * 否则回显候选让用户确认（同音错字不能靠猜）。
     */
    public static final double COMMUNITY_AUTO_ACCEPT_SCORE = 0.8;

    /**
     * 小区候选最低分：低于该值的候选不展示（避免把完全无关的小区列给用户）。
     */
    public static final double COMMUNITY_MIN_SCORE = 0.4;

    /**
     * 小区解析结果缓存 TTL（秒），键为「关键词 + 城市」。
     */
    public static final long COMMUNITY_CACHE_TTL_SECONDS = 1800L;

    /**
     * 高德住宅区 POI 类型码（inputtips 的 type 参数）。
     */
    public static final String AMAP_RESIDENTIAL_TYPE = "120302";

    /**
     * 存量帖子小区回填的批大小（单次 SELECT 上限）。
     */
    public static final int BACKFILL_BATCH_SIZE = 200;

    /**
     * 存量帖子小区回填的每条间隔（毫秒）：高德 Web 服务有 QPS 配额，
     * 10 QPS 是个人 Key 的保守值，避免回填把线上解析打满。
     */
    public static final long BACKFILL_DELAY_MILLIS = 100L;

    /**
     * 工具类：禁止实例化。
     */
    private NfrSearch() {
        throw new AssertionError("NfrSearch 是常量类，不可实例化");
    }

    /**
     * 构造半径档 → 米数只读映射。
     *
     * @return {@link Map} 契约档位到米数的映射（city 除外）
     */
    private static Map<String, Integer> radiusTierMeters() {
        Map<String, Integer> map = new LinkedHashMap<>();
        map.put("1", 1_000);
        map.put("3", 3_000);
        map.put("5", 5_000);
        map.put("10", 10_000);
        return Map.copyOf(map);
    }
}
