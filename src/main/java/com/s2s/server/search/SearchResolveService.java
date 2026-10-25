package com.s2s.server.search;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.ai.AiCostLedger;
import com.s2s.server.ai.AiProvider;
import com.s2s.server.category.CategoryService;
import com.s2s.server.common.constants.NfrMedia;
import com.s2s.server.common.constants.NfrSearch;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.post.MediaService;
import com.s2s.server.search.dto.CommunityCandidateDto;
import com.s2s.server.search.dto.SearchResolveRequest;
import com.s2s.server.search.dto.SearchResolveResult;
import com.s2s.server.search.mapper.CategorySynonymMapper;
import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.stereotype.Service;

/**
 * 语义搜索解析服务：把一句话（文字/语音）解析成地图收窄用的槽位卡。
 *
 * <p><b>分层口径</b>（2026-10-25 调整）：<b>所有搜索请求都走 AI 主解析</b>，只有命中
 * 语义解析缓存（文本 + 城市 + 提示词版本）时才跳过模型调用。确定性词表仍先跑，
 * 作为高置信锚点与 AI 不可用时的降级兜底（{@code degraded=true}）。AI 产物逐字段
 * 校验，越界值不采用并进 {@code unresolved_fields}。</p>
 *
 * <p><b>语音</b>（KTD7）：登录用户走 {@code voice_media_id}（签名 URL 后 ASR）；
 * 游客走 {@code voice_audio_base64}（data URI 直传上游，不落 OSS、不建媒体记录，
 * 转写即弃）。两路转写文本都并入同一解析管线。</p>
 */
@Service
public class SearchResolveService {

    /** 日志。 */
    private static final Logger LOG = LoggerFactory.getLogger(SearchResolveService.class);

    /** 半径数字 + 单位（公里/千米/km/米/m）。 */
    private static final Pattern RADIUS_PATTERN = Pattern.compile(
            "(\\d+(?:\\.\\d+)?)\\s*(公里|千米|km|KM|Km|米|m|M)");

    /** 阿拉伯数字价格上限（2000以内 / 不超过2000 / 最多2千元）。组 1 数字、组 2 单位。 */
    private static final Pattern PRICE_MAX_PATTERN = Pattern.compile(
            "(\\d+(?:\\.\\d+)?)\\s*(元|块|千|k|K)?\\s*(?:以内|以下|之内|内|最多|不超过|封顶)");

    /** 阿拉伯数字价格下限（2000以上 / 2000起）。组 1 数字、组 2 单位。 */
    private static final Pattern PRICE_MIN_PATTERN = Pattern.compile(
            "(\\d+(?:\\.\\d+)?)\\s*(元|块|千|k|K)?\\s*(?:以上|起)");

    /** 带「元/块」的裸价格（无上下限词时按预算上限处理）。组 1 数字、组 2 单位。 */
    private static final Pattern PRICE_BARE_PATTERN = Pattern.compile(
            "(\\d+(?:\\.\\d+)?)\\s*(元|块|千|k|K)");
    /** 中文数字价格 + 上限词（两千以内 / 一千五以下）。 */
    private static final Pattern PRICE_MAX_CN_PATTERN = Pattern.compile(
            "([零〇一二两三四五六七八九十百千万]+)\\s*(?:元|块)?\\s*(?:以内|以下|之内|内|最多|不超过|封顶)");

    /** 中文数字价格 + 下限词（两千以上 / 一千五起）。 */
    private static final Pattern PRICE_MIN_CN_PATTERN = Pattern.compile(
            "([零〇一二两三四五六七八九十百千万]+)\\s*(?:元|块)?\\s*(?:以上|起)");

    /** 纯中文数字价格（「预算两千」这类无上下限词的预算表达）。 */
    private static final Pattern PRICE_CN_BARE_PATTERN = Pattern.compile(
            "([零〇一二两三四五六七八九十百千万]{2,})\\s*(?:元|块|预算)");

    /** 「预算/价位 N」阿拉伯数字预算（无单位也成立）。组 1 数字、组 2 单位。 */
    private static final Pattern PRICE_BUDGET_PATTERN = Pattern.compile(
            "(?:预算|价位)\\s*(\\d+(?:\\.\\d+)?)\\s*(千|k|K)?");

    /** 「预算 N」中文数字预算。组 1 数字串。 */
    private static final Pattern PRICE_CN_BUDGET_PATTERN = Pattern.compile(
            "(?:预算|价位)\\s*([零〇一二两三四五六七八九十百千万]{2,})");

    /** 「我在 X」地点模式。 */
    private static final Pattern LOCATION_WO_ZAI = Pattern.compile(
            "我在([^，,。；;]{2,16}?)(?:要|想|，|,|。|；|;|附近|周边|这边|$|\\d)");

    /** 「在 X 附近」地点模式。 */
    private static final Pattern LOCATION_ZAI = Pattern.compile(
            "(?:^|[^我])在([^，,。；;]{2,16}?)(?:要|想|，|,|。|；|;|附近|周边|这边|$)");

    /** 「X 附近」地点模式。 */
    private static final Pattern LOCATION_NEAR = Pattern.compile(
            "([^，,。；;]{2,12}?)(?:附近|周边)");

    /** 「北城新徽苑租房」这类无介词口语：小区名 + 租房/求租意图。 */
    private static final Pattern LOCATION_HOUSING_INTENT = Pattern.compile(
            "(?:^|[^我])在?([\\u4e00-\\u9fa5]{2,15}?(?:小区|苑|府|家园|公寓|花园|湾|里|园))"
                    + "(?=租房|求租|找房|合租|整租)");

    /** 纯小区名（「北城新徽苑」）：末尾是住宅通名且整体无数字。 */
    private static final Pattern LOCATION_HOUSING_ONLY = Pattern.compile(
            "^([\\u4e00-\\u9fa5]{2,15}?(?:小区|苑|府|家园|公寓|花园|湾|里|园))$");

    /** 供需意图词：需求侧。 */
    private static final List<String> DEMAND_WORDS = List.of(
            "求租", "找房", "想找", "想租", "需要", "求职", "求购", "求搭车", "求拼", "求",
            "我要", "想买", "要");

    /** 供需意图词：资源侧（优先判定，避免「我要出租」被需求词抢走）。 */
    private static final List<String> RESOURCE_WORDS = List.of(
            "出租", "招聘", "招人", "转让", "出售", "提供", "接单", "有房", "我有");

    /** AI 兜底系统提示词（严格 Scope：只允许输出给定枚举内的值）。 */
    private static final String AI_SYSTEM_PROMPT = """
            你是搜索条件解析器。只允许使用 scope 中出现的叶子类目 ID、半径档、供需枚举。
            只输出一个 JSON 对象，不要解释、不要 Markdown 代码块，字段固定为：
            {"post_type":"resource|demand|null","leaf_category_ids":[整数],
             "radius":"1|3|5|10|city|null","price_min":数字|null,"price_max":数字|null,
             "location":"地点名或 null"}
             scope 中不存在的类目 ID 一律不要输出；不确定的字段输出 null。
            """;

    /** 契约供需枚举。 */
    private static final Set<String> POST_TYPES = Set.of("resource", "demand");

    /** 未敢采用/无法解析的字段名：地点。 */
    private static final String FIELD_LOCATION = "location";

    private final CategorySynonymMapper synonymMapper;
    private final CategoryService categoryService;
    private final AiProvider aiProvider;
    private final AmapPoiClient amapPoiClient;
    private final CommunityResolver communityResolver;
    private final SearchIntentCache intentCache;
    private final AiCostLedger aiCostLedger;
    private final MediaService mediaService;
    private final ObjectMapper objectMapper;

    /**
     * 构造语义解析服务。
     *
     * @param synonymMapper 同义词词表 Mapper（整表加载后内存匹配）
     * @param categoryService 分类服务（叶子清单与类目路径）
     * @param aiProvider 大模型供应商（ASR 与严格 Scope 兜底）
     * @param amapPoiClient 高德正向 POI / 输入提示客户端（未配置 Key 时自动降级）
     * @param communityResolver 小区实体归一（口语地址 → 小区 ID）
     * @param intentCache 语义解析缓存（文本 + 城市 + 提示词版本）
     * @param aiCostLedger AI 费用台账（搜索不消耗发布配额，仅做费用安全阀）
     * @param mediaService 媒体服务（登录态语音签名只读 URL）
     * @param objectMapper Jackson 解析器
     */
    public SearchResolveService(CategorySynonymMapper synonymMapper,
            CategoryService categoryService,
            AiProvider aiProvider,
            AmapPoiClient amapPoiClient,
            CommunityResolver communityResolver,
            SearchIntentCache intentCache,
            AiCostLedger aiCostLedger,
            MediaService mediaService,
            ObjectMapper objectMapper) {
        this.synonymMapper = synonymMapper;
        this.categoryService = categoryService;
        this.aiProvider = aiProvider;
        this.amapPoiClient = amapPoiClient;
        this.communityResolver = communityResolver;
        this.intentCache = intentCache;
        this.aiCostLedger = aiCostLedger;
        this.mediaService = mediaService;
        this.objectMapper = objectMapper;
    }

    /**
     * 执行一次语义解析。
     *
     * <p>注意：本方法<b>不使用</b> {@code AiQuotaGate}——搜索不是「确认发布」，
     * 不应消耗发布配额；AI 兜底只经 {@link AiCostLedger#ensureWithinBudget(Long)}
     * 做日/月费用安全阀（对方案 KTD10 的收紧，登录与游客同口径）。</p>
     *
     * <p>解析策略（2026-10-25 用户裁定）：<b>所有请求优先走大模型</b>，只有命中
     * 「文本 + 城市」缓存才跳过上游；词表不再决定是否调 AI，而是作为高置信锚点与
     * AI 故障时的降级路径。AI 输出仍经严格 Scope 校验，越界值不采用。</p>
     *
     * @param userId 当前登录用户 ID（游客为 null）
     * @param req    解析入参
     * @return {@link SearchResolveResult} 槽位卡（含 ai_used / degraded 标记）
     * @throws BizException 输入全空/语音内容非法 → 40001
     */
    public SearchResolveResult resolve(Long userId, SearchResolveRequest req) {
        String transcript = transcribe(userId, req);
        String text = joinText(transcript, req.voiceText(), req.text());
        if (text.isBlank()) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        String normalized = normalize(text);

        Map<String, String> sources = new LinkedHashMap<>();
        Set<String> unresolved = new LinkedHashSet<>();

        RadiusSlot radiusSlot = parseRadius(normalized);
        if (radiusSlot != null) {
            sources.put("radius", "vocab");
        }
        PriceSlot priceSlot = parsePrice(normalized);
        if (priceSlot != null) {
            sources.put("price", "vocab");
        }
        String postType = parsePostType(normalized);
        if (postType != null) {
            sources.put("post_type", "vocab");
        }
        List<Integer> leafIds = matchCategories(normalized);
        if (!leafIds.isEmpty()) {
            sources.put("category", "vocab");
        }
        String vocabPlace = extractPlace(normalized);
        String cityAdcode = cityAdcodeOf(req);

        // AI 主解析：缓存未命中必调大模型；失败降级词表，不阻断搜索。
        Set<String> aiUnresolved = new LinkedHashSet<>();
        AiParseOutcome aiOutcome = parseWithAi(normalized, cityAdcode, userId, aiUnresolved);
        boolean aiUsed = aiOutcome.aiUsed();
        boolean degraded = aiOutcome.degraded();
        AiSlots ai = aiOutcome.slots();
        if (ai != null) {
            if (ai.postType() != null) {
                postType = ai.postType();
                sources.put("post_type", "ai");
            }
            if (!ai.leafCategoryIds().isEmpty()) {
                leafIds = ai.leafCategoryIds();
                sources.put("category", "ai");
            }
            if (ai.radius() != null) {
                radiusSlot = new RadiusSlot(ai.radius(), metersOfTier(ai.radius()));
                sources.put("radius", "ai");
            }
            if (ai.priceMin() != null || ai.priceMax() != null) {
                priceSlot = new PriceSlot(ai.priceMin(), ai.priceMax());
                sources.put("price", "ai");
            }
        }
        String place = ai != null && ai.location() != null ? ai.location() : vocabPlace;

        AnchorResolution anchorResolution =
                resolveAnchor(req, place, cityAdcode, sources, unresolved);
        AnchorSlot anchor = anchorResolution.anchor();
        String communityId = anchorResolution.communityId();
        String communityName = anchorResolution.communityName();
        List<CommunityCandidateDto> communityCandidates = anchorResolution.candidates();

        // AI 越界字段只有在词表也没兜住时才提示「没敢用」，避免误报。
        if (aiUnresolved.contains("category") && leafIds.isEmpty()) {
            unresolved.add("category");
        }
        if (aiUnresolved.contains("radius") && radiusSlot == null) {
            unresolved.add("radius");
        }
        if (aiUnresolved.contains("post_type") && postType == null) {
            unresolved.add("post_type");
        }
        if (aiUnresolved.contains("price") && priceSlot == null) {
            unresolved.add("price");
        }
        if (anchor == null) {
            unresolved.add(FIELD_LOCATION);
        }

        return new SearchResolveResult(
                transcript,
                postType,
                leafIds,
                labelsOf(leafIds),
                radiusSlot == null ? null : radiusSlot.tier(),
                radiusSlot == null ? null : radiusSlot.meters(),
                anchor == null ? null : anchor.lng(),
                anchor == null ? null : anchor.lat(),
                anchor == null ? null : anchor.name(),
                anchor == null ? null : anchor.source(),
                communityId,
                communityName,
                communityCandidates,
                priceSlot == null ? null : priceSlot.min(),
                priceSlot == null ? null : priceSlot.max(),
                priceSlot != null && priceSlot.max() != null,
                new ArrayList<>(unresolved),
                sources,
                normalized,
                aiUsed,
                degraded);
    }

    /**
     * 语音转写：客户端转写文本优先；其次登录态媒体；最后游客 base64。
     *
     * @param userId 当前用户 ID（游客为 null）
     * @param req    解析入参
     * @return {@link String} 转写文本；无语音输入时为空串
     * @throws BizException 游客音频非法 → 40001；上游 ASR 失败 → 50301
     */
    private String transcribe(Long userId, SearchResolveRequest req) {
        if (notBlank(req.voiceText())) {
            return req.voiceText().strip();
        }
        if (notBlank(req.voiceMediaId()) && userId != null) {
            MediaService.AiMediaAccess access = mediaService.signAiReadAccess(userId, req.voiceMediaId());
            aiCostLedger.ensureWithinBudget(userId);
            try {
                String text = aiProvider.transcribe(userId, access.accessUrl(), access.contentType());
                return text == null ? "" : text.strip();
            } catch (RuntimeException exception) {
                throw BizException.of(ErrorCode.AI_UNAVAILABLE);
            }
        }
        if (notBlank(req.voiceAudioBase64())) {
            String base64 = req.voiceAudioBase64().strip();
            if (base64.length() > NfrSearch.VOICE_BASE64_MAX_LENGTH) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            String contentType = notBlank(req.voiceContentType())
                    ? req.voiceContentType().strip() : NfrSearch.DEFAULT_VOICE_CONTENT_TYPE;
            if (!NfrMedia.AUDIO_CONTENT_TYPES.contains(contentType)) {
                throw BizException.of(ErrorCode.PARAM_INVALID);
            }
            aiCostLedger.ensureWithinBudget(NfrSearch.GUEST_LEDGER_USER_ID);
            String dataUri = "data:" + contentType + ";base64," + base64;
            try {
                String text = aiProvider.transcribe(
                        NfrSearch.GUEST_LEDGER_USER_ID, dataUri, contentType);
                return text == null ? "" : text.strip();
            } catch (RuntimeException exception) {
                throw BizException.of(ErrorCode.AI_UNAVAILABLE);
            }
        }
        return "";
    }

    /**
     * 合并多路文本（去重、非空片段以空格连接）。
     *
     * @param parts 文本片段（可含 null/空串）
     * @return {@link String} 合并结果
     */
    private String joinText(String... parts) {
        StringBuilder builder = new StringBuilder();
        for (String part : parts) {
            if (!notBlank(part) || builder.indexOf(part.strip()) >= 0) {
                continue;
            }
            if (builder.length() > 0) {
                builder.append(' ');
            }
            builder.append(part.strip());
        }
        return builder.toString();
    }

    /**
     * 文本归一化：去首尾空白、全角转半角、压缩连续空白。
     *
     * @param raw 原始文本
     * @return {@link String} 归一化文本
     */
    private String normalize(String raw) {
        StringBuilder builder = new StringBuilder(raw.length());
        for (char ch : raw.toCharArray()) {
            if (ch >= '！' && ch <= '～') {
                builder.append((char) (ch - 0xFEE0));
            } else if (ch == '　') {
                builder.append(' ');
            } else {
                builder.append(ch);
            }
        }
        return builder.toString().replaceAll("\\s+", " ").strip();
    }

    /**
     * 解析半径：数字 + 单位 → 真实米数与最近契约档。
     *
     * @param text 归一化文本
     * @return {@link RadiusSlot} 未表达半径时返回 null
     */
    private RadiusSlot parseRadius(String text) {
        Matcher matcher = RADIUS_PATTERN.matcher(text);
        if (!matcher.find()) {
            return null;
        }
        double value = Double.parseDouble(matcher.group(1));
        String unit = matcher.group(2);
        double meters = ("米".equals(unit) || "m".equalsIgnoreCase(unit)) ? value : value * 1000;
        String tier = tierOfMeters(meters);
        if (NfrSearch.RADIUS_CITY.equals(tier)) {
            return new RadiusSlot(tier, null);
        }
        return new RadiusSlot(tier, (int) Math.round(meters));
    }

    /**
     * 真实米数 → 最近契约半径档（向上取档，保证圈不切掉用户要的范围）。
     *
     * @param meters 真实米数
     * @return {@link String} 契约档位
     */
    private String tierOfMeters(double meters) {
        for (String tier : NfrSearch.RADIUS_TIERS) {
            if (NfrSearch.RADIUS_CITY.equals(tier)) {
                return tier;
            }
            Integer tierMeters = NfrSearch.RADIUS_TIER_METERS.get(tier);
            if (tierMeters != null && meters <= tierMeters) {
                return tier;
            }
        }
        return NfrSearch.RADIUS_CITY;
    }

    /**
     * 档位 → 默认米数。
     *
     * @param tier 契约档位
     * @return {@link Integer} 米数；全城档为 null
     */
    private Integer metersOfTier(String tier) {
        return NfrSearch.RADIUS_TIER_METERS.get(tier);
    }

    /**
     * 解析价格上下限（阿拉伯数字与中文数字，含无单位口语）。
     *
     * @param text 归一化文本
     * @return {@link PriceSlot} 未表达价格时返回 null
     */
    private PriceSlot parsePrice(String text) {
        BigDecimal max = firstPrice(text, PRICE_MAX_PATTERN, PRICE_MAX_CN_PATTERN);
        BigDecimal min = firstPrice(text, PRICE_MIN_PATTERN, PRICE_MIN_CN_PATTERN);
        if (max == null) {
            max = firstPrice(text, PRICE_BARE_PATTERN, PRICE_CN_BARE_PATTERN);
        }
        if (max == null) {
            max = firstPrice(text, PRICE_BUDGET_PATTERN, PRICE_CN_BUDGET_PATTERN);
        }
        if (min == null && max == null) {
            return null;
        }
        if (min != null && max != null && min.compareTo(max) > 0) {
            BigDecimal swap = min;
            min = max;
            max = swap;
        }
        return new PriceSlot(min, max);
    }

    /**
     * 用两组正则依次取第一个价格。
     *
     * @param text      归一化文本
     * @param arabic    阿拉伯数字正则（组 1 为数字）
     * @param chinese   中文数字正则（组 1 为数字串）
     * @return {@link BigDecimal} 价格（元）；未命中返回 null
     */
    private BigDecimal firstPrice(String text, Pattern arabic, Pattern chinese) {
        Matcher arabicMatcher = arabic.matcher(text);
        if (arabicMatcher.find()) {
            double value = Double.parseDouble(arabicMatcher.group(1));
            String unit = arabicMatcher.groupCount() >= 2 ? arabicMatcher.group(2) : null;
            if ("千".equals(unit) || "k".equalsIgnoreCase(unit)) {
                value = value * 1000;
            }
            return boundedPrice(value);
        }
        Matcher chineseMatcher = chinese.matcher(text);
        if (chineseMatcher.find()) {
            long value = chineseNumber(chineseMatcher.group(1));
            return value < 0 ? null : boundedPrice(value);
        }
        return null;
    }

    /**
     * 价格边界归一：非正或超上限视为不合理解析结果。
     *
     * @param value 价格（元）
     * @return {@link BigDecimal} 合法价格；越界返回 null
     */
    private BigDecimal boundedPrice(double value) {
        if (value <= 0 || value > NfrSearch.PRICE_MAX_REASONABLE_YUAN) {
            return null;
        }
        return normalizePrice(BigDecimal.valueOf(value));
    }

    /**
     * 价格归一：去掉无意义的尾零，并避免 2000 被表示成科学计数法 {@code 2E+3}。
     *
     * @param value 原始价格
     * @return {@link BigDecimal} 归一后的价格
     */
    private BigDecimal normalizePrice(BigDecimal value) {
        BigDecimal normalized = value.stripTrailingZeros();
        return normalized.scale() < 0 ? normalized.setScale(0) : normalized;
    }

    /**
     * 中文数字转数值（支持 十/百/千/万，拒绝「一百二」这类省略式）。
     *
     * @param raw 中文数字串
     * @return long 数值；无法解析返回 -1
     */
    private long chineseNumber(String raw) {
        Map<Character, Integer> digits = Map.ofEntries(
                Map.entry('零', 0), Map.entry('〇', 0), Map.entry('一', 1), Map.entry('二', 2),
                Map.entry('两', 2), Map.entry('三', 3), Map.entry('四', 4), Map.entry('五', 5),
                Map.entry('六', 6), Map.entry('七', 7), Map.entry('八', 8), Map.entry('九', 9));
        Map<Character, Integer> units = Map.of('十', 10, '百', 100, '千', 1000);
        long total = 0;
        long section = 0;
        long current = 0;
        int lastUnit = 0;
        boolean afterZero = false;
        for (char ch : raw.toCharArray()) {
            if (digits.containsKey(ch)) {
                current = digits.get(ch);
                if (ch == '零' || ch == '〇') {
                    afterZero = true;
                }
            } else if (units.containsKey(ch)) {
                int unit = units.get(ch);
                section += (current == 0 ? 1 : current) * unit;
                current = 0;
                lastUnit = unit;
                afterZero = false;
            } else if (ch == '万') {
                total += (section + current) * 10_000L;
                section = 0;
                current = 0;
                lastUnit = 0;
                afterZero = false;
            } else {
                return -1;
            }
        }
        // 口语省略式「一千五」= 1500：末位数字紧跟在百/千后且中间无「零」时按下一档处理
        if (current > 0 && lastUnit >= 100 && !afterZero) {
            section += current * (lastUnit / 10);
            current = 0;
        }
        long result = total + section + current;
        return result > 0 && result <= NfrSearch.SPOKEN_PRICE_MAX ? result : -1;
    }

    /**
     * 解析供需方向（资源侧优先，避免「我要出租」被判成需求）。
     *
     * @param text 归一化文本
     * @return {@link String} resource/demand；未表达返回 null
     */
    private String parsePostType(String text) {
        for (String word : RESOURCE_WORDS) {
            if (text.contains(word)) {
                return "resource";
            }
        }
        for (String word : DEMAND_WORDS) {
            if (text.contains(word)) {
                return "demand";
            }
        }
        return null;
    }

    /**
     * 词表匹配类目：取文本中包含的最长词条，同词条的多叶子全部并入。
     *
     * @param text 归一化文本
     * @return {@link List} 叶子类目 ID（去重升序）
     */
    private List<Integer> matchCategories(String text) {
        List<CategorySynonym> synonyms = synonymMapper.selectAllEnabled();
        int maxLength = 0;
        List<CategorySynonym> hits = new ArrayList<>();
        for (CategorySynonym synonym : synonyms) {
            String term = synonym.term();
            if (term == null || term.isBlank()) {
                continue;
            }
            if (text.contains(term)) {
                if (term.length() > maxLength) {
                    maxLength = term.length();
                    hits.clear();
                }
                if (term.length() == maxLength) {
                    hits.add(synonym);
                }
            }
        }
        if (hits.isEmpty() && text.matches("[a-zA-Z]{2,8}")) {
            for (CategorySynonym synonym : synonyms) {
                if (text.equalsIgnoreCase(synonym.pinyin())) {
                    hits.add(synonym);
                }
            }
        }
        return hits.stream()
                .map(CategorySynonym::leafCategoryId)
                .filter(id -> id != null)
                .distinct()
                .sorted()
                .toList();
    }

    /**
     * 取叶子类目显示名（L3 名称）作为 chip 文案。
     *
     * @param leafIds 叶子类目 ID 列表
     * @return {@link List} 与 ID 同序的名称
     */
    private List<String> labelsOf(List<Integer> leafIds) {
        List<String> labels = new ArrayList<>(leafIds.size());
        for (Integer id : leafIds) {
            List<String> path = categoryService.categoryPath(id);
            labels.add(path.isEmpty() ? String.valueOf(id) : path.get(path.size() - 1));
        }
        return labels;
    }

    /**
     * 解析地点锚点，同时产出小区实体与候选。
     *
     * <p><b>优先级（2026-10-25 用户裁定）</b>：文本地点 &gt; 长按点 &gt; 当前定位。
     * 文本里说出的地名比任意长按点更精确；长按点只在文本没给出地点、或文本小区低置信
     * 时作为兜底锚点，此时仍把候选带回前端让用户点选。</p>
     *
     * @param req        解析入参
     * @param place      文本地名（AI 或词表抽取，可空）
     * @param cityAdcode 城市 adcode（约束小区检索范围）
     * @param sources    各槽位来源标记（就地写入）
     * @param unresolved 未解析字段集合（就地写入）
     * @return {@link AnchorResolution} 锚点 + 小区实体 + 候选
     */
    private AnchorResolution resolveAnchor(SearchResolveRequest req, String place,
            String cityAdcode, Map<String, String> sources, Set<String> unresolved) {
        boolean hasLongPress = req.anchorLng() != null && req.anchorLat() != null;
        if (place != null && !place.isBlank()) {
            AnchorResolution resolved = poiAnchor(place, sources, cityAdcode);
            if (resolved.anchor() != null) {
                return resolved;
            }
            if (!resolved.candidates().isEmpty()) {
                // 低置信：有长按点就保留长按点作锚，但候选照常回给用户点选。
                if (hasLongPress) {
                    sources.put("anchor", "anchor");
                    return new AnchorResolution(
                            new AnchorSlot(req.anchorLng(), req.anchorLat(), null, "long_press"),
                            null, null, resolved.candidates());
                }
                unresolved.add(FIELD_LOCATION);
                return resolved;
            }
        }
        if (hasLongPress) {
            sources.put("anchor", "anchor");
            return new AnchorResolution(
                    new AnchorSlot(req.anchorLng(), req.anchorLat(), null, "long_press"),
                    null, null, List.of());
        }
        if (req.currentLng() != null && req.currentLat() != null) {
            sources.put("anchor", "current");
            return new AnchorResolution(
                    new AnchorSlot(req.currentLng(), req.currentLat(), null, "current"),
                    null, null, List.of());
        }
        if (place != null && !place.isBlank()) {
            unresolved.add(FIELD_LOCATION);
        }
        return AnchorResolution.empty();
    }

    /**
     * 解析地名：先做小区实体归一（inputtips + 打分），未命中再回退正向 POI。
     *
     * @param place      地名
     * @param sources    来源标记（命中时写 anchor=poi）
     * @param cityAdcode 城市 adcode（用于约束小区候选范围）
     * @return {@link AnchorResolution} 未命中时 anchor 为 null，候选可能非空
     */
    private AnchorResolution poiAnchor(String place, Map<String, String> sources,
            String cityAdcode) {
        CommunityResolver.CommunityMatch match = communityResolver.resolve(place, cityAdcode);
        List<CommunityCandidateDto> candidates = new ArrayList<>();
        for (CommunityResolver.CommunityCandidate candidate : match.candidates()) {
            candidates.add(new CommunityCandidateDto(candidate.id(), candidate.name(),
                    candidate.district(), candidate.lng(), candidate.lat()));
        }
        if (match.communityId() != null) {
            sources.put("anchor", "poi");
            return new AnchorResolution(
                    new AnchorSlot(match.lng(), match.lat(), match.communityName(), "poi"),
                    match.communityId(), match.communityName(), candidates);
        }
        Optional<AmapPoiClient.PoiPoint> point = amapPoiClient.search(place);
        if (point.isEmpty()) {
            return new AnchorResolution(null, null, null, candidates);
        }
        AmapPoiClient.PoiPoint poi = point.get();
        sources.put("anchor", "poi");
        return new AnchorResolution(
                new AnchorSlot(poi.lng(), poi.lat(), poi.name(), "poi"),
                null, null, candidates);
    }

    /**
     * 取城市 adcode 以约束小区候选范围（优先当前定位，其次长按点）。
     *
     * @param req 解析入参
     * @return {@link String} adcode；无坐标或无 Key 返回 null
     */
    private String cityAdcodeOf(SearchResolveRequest req) {
        if (req.currentLng() != null && req.currentLat() != null) {
            return amapPoiClient.reverseAdcode(req.currentLng(), req.currentLat());
        }
        if (req.anchorLng() != null && req.anchorLat() != null) {
            return amapPoiClient.reverseAdcode(req.anchorLng(), req.anchorLat());
        }
        return null;
    }

    /**
     * 从文本抽取候选地名（我在X / 在X / X附近）。
     *
     * @param text 归一化文本
     * @return {@link String} 候选地名；抽不到返回 null
     */
    private String extractPlace(String text) {
        for (Pattern pattern : List.of(LOCATION_WO_ZAI, LOCATION_ZAI, LOCATION_NEAR,
                LOCATION_HOUSING_INTENT, LOCATION_HOUSING_ONLY)) {
            Matcher matcher = pattern.matcher(text);
            if (matcher.find()) {
                String candidate = matcher.group(1).strip();
                if (!candidate.isEmpty() && !candidate.matches(".*\\d.*")
                        && !candidate.contains("以内") && !candidate.contains("公里")) {
                    return candidate;
                }
            }
        }
        return null;
    }

    /**
     * AI 主解析：缓存未命中必调大模型；失败返回 degraded 由调用方走词表。
     *
     * @param text        归一化文本
     * @param cityAdcode  城市 adcode（缓存键要素）
     * @param userId      当前用户 ID（游客为 null）
     * @param aiUnresolved AI 越界字段集合（原地写入）
     * @return {@link AiParseOutcome} 成功槽位或降级标记
     */
    private AiParseOutcome parseWithAi(String text, String cityAdcode, Long userId,
            Set<String> aiUnresolved) {
        String raw = intentCache.get(text, cityAdcode);
        boolean cacheHit = raw != null;
        if (!cacheHit) {
            long ledgerUserId = userId == null ? NfrSearch.GUEST_LEDGER_USER_ID : userId;
            try {
                aiCostLedger.ensureWithinBudget(ledgerUserId);
                raw = aiProvider.generate(ledgerUserId, buildAiScope(text), AI_SYSTEM_PROMPT);
            } catch (RuntimeException exception) {
                LOG.warn("搜索语义解析 AI 不可用，降级词表：{}",
                        exception.getClass().getSimpleName());
                return AiParseOutcome.degradedOutcome();
            }
            if (raw == null || raw.isBlank() || parseAiJson(raw) == null) {
                LOG.warn("搜索语义解析 AI 输出不可用，降级词表");
                return AiParseOutcome.degradedOutcome();
            }
            intentCache.put(text, cityAdcode, raw);
        }
        return AiParseOutcome.success(verifyAi(raw, aiUnresolved));
    }

    /**
     * 构造 AI scope JSON（候选叶子、半径档、供需枚举、价格语义）。
     *
     * @param text 自由文本
     * @return {@link String} scope JSON
     */
    private String buildAiScope(String text) {
        Map<String, Object> scope = new LinkedHashMap<>();
        scope.put("text", text);
        scope.put("radius_tiers", NfrSearch.RADIUS_TIERS);
        scope.put("post_types", List.of("resource", "demand"));
        List<Map<String, Object>> leaves = new ArrayList<>();
        for (CategoryService.LeafOption option : categoryService.listLeafOptions()) {
            leaves.add(Map.of("id", option.id(), "path", option.path()));
        }
        scope.put("leaf_categories", leaves);
        try {
            return objectMapper.writeValueAsString(scope);
        } catch (Exception exception) {
            throw BizException.of(ErrorCode.INTERNAL_ERROR);
        }
    }

    /**
     * 校验 AI 输出：越界字段不采用并记入 unresolved。
     *
     * @param raw        AI 原始输出
     * @param unresolved 未解析字段集合（原地写入）
     * @return {@link AiSlots} 合法子集
     */
    private AiSlots verifyAi(String raw, Set<String> unresolved) {
        JsonNode root = parseAiJson(raw);
        if (root == null) {
            unresolved.add("ai");
            return AiSlots.empty();
        }
        String postType = textOrNull(root, "post_type");
        if (postType != null && !POST_TYPES.contains(postType)) {
            unresolved.add("post_type");
            postType = null;
        }
        String radius = textOrNull(root, "radius");
        if (radius != null && !NfrSearch.RADIUS_TIERS.contains(radius)) {
            unresolved.add("radius");
            radius = null;
        }
        Set<Integer> allowed = new LinkedHashSet<>();
        for (CategoryService.LeafOption option : categoryService.listLeafOptions()) {
            allowed.add(option.id());
        }
        List<Integer> leaves = new ArrayList<>();
        JsonNode leafNode = root.path("leaf_category_ids");
        if (leafNode.isArray()) {
            for (JsonNode node : leafNode) {
                int id = node.asInt(-1);
                if (allowed.contains(id)) {
                    leaves.add(id);
                } else {
                    unresolved.add("category");
                }
            }
        }
        BigDecimal min = aiPrice(root, "price_min", unresolved);
        BigDecimal max = aiPrice(root, "price_max", unresolved);
        if (min != null && max != null && min.compareTo(max) > 0) {
            unresolved.add("price");
            min = null;
            max = null;
        }
        return new AiSlots(postType, leaves.stream().distinct().sorted().toList(), radius, min, max,
                textOrNull(root, "location"));
    }

    /**
     * 解析 AI 输出 JSON（容忍 Markdown 代码块包裹）。
     *
     * @param raw AI 原始输出
     * @return {@link JsonNode} 解析失败返回 null
     */
    private JsonNode parseAiJson(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        String cleaned = raw.strip();
        if (cleaned.startsWith("```")) {
            int firstNewline = cleaned.indexOf('\n');
            int lastFence = cleaned.lastIndexOf("```");
            if (firstNewline > 0 && lastFence > firstNewline) {
                cleaned = cleaned.substring(firstNewline + 1, lastFence).strip();
            }
        }
        int start = cleaned.indexOf('{');
        int end = cleaned.lastIndexOf('}');
        if (start < 0 || end <= start) {
            return null;
        }
        try {
            return objectMapper.readTree(cleaned.substring(start, end + 1));
        } catch (Exception exception) {
            return null;
        }
    }

    /**
     * 读取 AI 价格字段并做边界校验。
     *
     * @param root       AI JSON 根节点
     * @param field      字段名
     * @param unresolved 未解析字段集合（原地写入）
     * @return {@link BigDecimal} 合法价格；缺失/越界返回 null
     */
    private BigDecimal aiPrice(JsonNode root, String field, Set<String> unresolved) {
        JsonNode node = root.path(field);
        if (!node.isNumber()) {
            return null;
        }
        BigDecimal value = node.decimalValue();
        if (value.signum() <= 0 || value.compareTo(
                BigDecimal.valueOf(NfrSearch.PRICE_MAX_REASONABLE_YUAN)) > 0) {
            unresolved.add("price");
            return null;
        }
        return normalizePrice(value);
    }

    /**
     * 读取 JSON 文本字段（null/"null"/空串归一为 null）。
     *
     * @param root  JSON 根节点
     * @param field 字段名
     * @return {@link String} 文本或 null
     */
    private String textOrNull(JsonNode root, String field) {
        JsonNode node = root.path(field);
        if (!node.isTextual()) {
            return null;
        }
        String value = node.asText().strip();
        return value.isEmpty() || "null".equalsIgnoreCase(value) ? null : value;
    }

    /**
     * 判断字符串非空白。
     *
     * @param value 待判值
     * @return boolean 非 null 且含非空白字符返回 true
     */
    private boolean notBlank(String value) {
        return value != null && !value.isBlank();
    }

    /**
     * 半径解析结果。
     *
     * @param tier   契约档位
     * @param meters 真实米数（全城为 null）
     */
    private record RadiusSlot(String tier, Integer meters) {
    }

    /**
     * 价格解析结果。
     *
     * @param min 下限（元，可空）
     * @param max 上限（元，可空）
     */
    private record PriceSlot(BigDecimal min, BigDecimal max) {
    }

    /**
     * 地点锚点。
     *
     * @param lng    经度
     * @param lat    纬度
     * @param name   地点名（长按/定位为空）
     * @param source 来源（long_press/poi/current）
     */
    private record AnchorSlot(Double lng, Double lat, String name, String source) {
    }

    /**
     * 地点解析结果（锚点 + 小区实体 + 候选）。
     *
     * @param anchor        地点锚点（无法定位为 null）
     * @param communityId   自动采用的小区实体 ID（低置信为 null）
     * @param communityName 小区规范名（低置信为 null）
     * @param candidates    小区候选（供用户点选；可为空表）
     */
    private record AnchorResolution(AnchorSlot anchor, String communityId, String communityName,
            List<CommunityCandidateDto> candidates) {

        /**
         * 空结果。
         *
         * @return {@link AnchorResolution} 无锚点、无候选
         */
        static AnchorResolution empty() {
            return new AnchorResolution(null, null, null, List.of());
        }
    }

    /**
     * AI 解析结果（成功槽位或降级标记）。
     *
     * @param slots    校验后的槽位（降级时为 null）
     * @param aiUsed   是否采用了 AI（缓存命中也算）
     * @param degraded AI 不可用/输出非法，已降级词表
     */
    private record AiParseOutcome(AiSlots slots, boolean aiUsed, boolean degraded) {

        /**
         * 成功结果。
         *
         * @param slots 校验后的槽位
         * @return {@link AiParseOutcome}
         */
        static AiParseOutcome success(AiSlots slots) {
            return new AiParseOutcome(slots, true, false);
        }

        /**
         * 降级结果。
         *
         * @return {@link AiParseOutcome}
         */
        static AiParseOutcome degradedOutcome() {
            return new AiParseOutcome(null, false, true);
        }
    }

    /**
     * AI 校验后的槽位。
     *
     * @param postType        供需
     * @param leafCategoryIds 合法叶子
     * @param radius          半径档
     * @param priceMin        价格下限
     * @param priceMax        价格上限
     * @param location        地名
     */
    private record AiSlots(String postType, List<Integer> leafCategoryIds, String radius,
            BigDecimal priceMin, BigDecimal priceMax, String location) {

        /**
         * 全空结果。
         *
         * @return {@link AiSlots} 空槽位
         */
        static AiSlots empty() {
            return new AiSlots(null, List.of(), null, null, null, null);
        }
    }
}
