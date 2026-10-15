package com.s2s.server.ai;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.ai.dto.AiGuess;
import com.s2s.server.ai.dto.AiParseRequest;
import com.s2s.server.ai.dto.AiParseResult;
import com.s2s.server.ai.dto.AiQuota;
import com.s2s.server.category.TemplateService;
import com.s2s.server.category.dto.TemplateDto;
import com.s2s.server.category.dto.TemplateFieldDto;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.ratelimit.RateLimitKeys;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.stereotype.Service;

/**
 * AI 智能发布解析服务（B2-4；PRD §5.9 四模式 / §5.10 严格 Scope 四步管线）。
 *
 * <p>四步管线（PRD §5.10，红线级）：</p>
 * <ol>
 *   <li><b>Step 1 用户输入</b>：图 / 语音 / 文本（模式差异仅在入参组合）；</li>
 *   <li><b>Step 2 Scope 提取</b>：构造 U（用户文本）∪ N（邻居，本期无数据源，空）
 *       ∪ P（平台模板：叶子类目、模板字段选项）的可允许字段集合；</li>
 *   <li><b>Step 3 大模型生成</b>：交 {@link AiProvider}（prompt 限死「仅用 scope 字段」）；</li>
 *   <li><b>Step 4 逆向 Scope 比对</b>：<b>核心红线</b>——逐字段校验模型产物能否在 scope
 *       找到源头，找不到的一律<b>留空</b>并移入 {@code unresolved_fields}（服务端不猜、不编造）。</li>
 * </ol>
 *
 * <p><b>配额</b>：本服务只读判定（{@link AiQuotaGate#ensureAvailable}），<b>不扣减</b>；
 * 扣减唯一发生在 {@code POST /posts}（带 {@code ai_assisted=true}），由 {@code PostService}
 * 调用 {@link AiQuotaGate#increment}（PRD §5.9「仅确认发布才计 1 次」）。</p>
 *
 * <p><b>异常映射</b>：输入全空 → {@code 40001}；配额耗尽 → {@code 42901}（携 Retry-After）；
 * 上游模型不可用 / 返回结构非法 → {@code 50301}。</p>
 */
@Service
public class AiParseService {

    /**
     * Step 3 系统提示词（严格 Scope 红线）。
     *
     * <p>限死「仅可使用 scope 中出现的实体，禁止编造新实体，无法确定则留空」——
     * 与 Step 4 逆向比对一正一反共同守住幻觉 ≈ 0（PRD §5.10）。同时给出<b>输出结构</b>：
     * 真实模型不知道 Step 4 的字段口径，不写清结构会返回自造键名（全被 Step 4 拒掉）。</p>
     *
     * <p>提示词口径与 {@link #verifyAgainstScope} 一一对应（title 须能在 text 溯源、
     * leaf_category_id 须等于 scope 已选叶子、price 数字须在 text 出现、template_values
     * 键值须落在模板字段与选项内）；两处改动必须同批。</p>
     */
    private static final String SYSTEM_PROMPT =
            "你是发布信息抽取器，只输出一个 JSON 对象，不要任何解释或 Markdown 代码块。"
            + "用户消息是一段 JSON（scope）：text=用户原话，leaf_category_id=用户已选叶子类目，"
            + "template_fields=平台模板字段（key）及其可选项（options）。"
            + "只允许从 scope 中已有的内容搬运，禁止编造任何未出现的实体（价格、地名、型号、单位、类目等）。"
            + "输出结构："
            + "{\"title\":字符串（必须是 text 的子串，≤40 字，无法确定则省略）,"
            + "\"leaf_category_id\":整数（只能是 scope.leaf_category_id，没有则省略）,"
            + "\"price\":数字（必须是 text 中出现过的数字，没有则省略）,"
            + "\"price_unit\":字符串（必须是 text 中出现过的单位，没有则省略）,"
            + "\"template_values\":对象（键必须来自 template_fields 的 key，值必须是该字段 options 之一或 text 中出现过）}。"
            + "无法从 scope 确定的字段一律省略，不要猜测。";

    /** 猜测字段名（scope_verified / unresolved_fields 的键）。 */
    private static final String FIELD_TITLE = "title";
    private static final String FIELD_LEAF_CATEGORY = "leaf_category_id";
    private static final String FIELD_PRICE = "price";
    private static final String FIELD_PRICE_UNIT = "price_unit";

    /** 数字抽取正则（价格溯源用）。 */
    private static final Pattern NUMBER_PATTERN = Pattern.compile("\\d+(?:\\.\\d+)?");

    private final AiProvider aiProvider;
    private final AiQuotaService aiQuotaService;
    private final AiQuotaGate aiQuotaGate;
    private final TemplateService templateService;
    private final ObjectMapper objectMapper;

    /**
     * 构造解析服务。
     *
     * @param aiProvider      大模型供应商（dry-run 或真实现）
     * @param aiQuotaService  配额档位解析
     * @param aiQuotaGate     配额闸（只读判定）
     * @param templateService 模板服务（scope 的 P 集合）
     * @param objectMapper    JSON 解析器
     */
    public AiParseService(AiProvider aiProvider,
            AiQuotaService aiQuotaService,
            AiQuotaGate aiQuotaGate,
            TemplateService templateService,
            ObjectMapper objectMapper) {
        this.aiProvider = aiProvider;
        this.aiQuotaService = aiQuotaService;
        this.aiQuotaGate = aiQuotaGate;
        this.templateService = templateService;
        this.objectMapper = objectMapper;
    }

    /**
     * 执行 AI 解析（Step 1–4）。
     *
     * @param userId 当前登录用户 ID
     * @param req    解析入参（四模式共用）
     * @return {@link AiParseResult} 四件套猜测 + 来源 + 未解析字段 + 配额快照
     * @throws BizException 输入全空 → {@code 40001}；配额耗尽 → {@code 42901}；上游不可用 → {@code 50301}
     */
    public AiParseResult parse(Long userId, AiParseRequest req) {
        // Step 1：合并用户文本（voiceText 优先于 text；ASR 后的文本即 voiceText）
        String userText = joinUserText(req.voiceText(), req.text());

        // 至少一项输入非空
        if (!hasAnyInput(req, userText)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        // 配额只读判定（不扣减）
        int limit = aiQuotaService.resolveLimit(userId, req.completenessLevel(), req.leafCategoryId());
        aiQuotaGate.ensureAvailable(userId, limit, RateLimitKeys.today());

        // Step 2：Scope 提取（U ∪ N ∪ P；N 本期无数据源）
        TemplateDto template = resolveTemplate(req.leafCategoryId());
        Integer scopeLeafId = template == null ? null : req.leafCategoryId();
        String scopeJson = buildScopeJson(userText, req.kind(), scopeLeafId, template);

        // Step 3：大模型生成（上游异常 → 50301）
        String raw = generate(scopeJson);

        // Step 4：逆向 Scope 比对（核心红线）
        Verified verified = verifyAgainstScope(raw, userText, scopeLeafId, template);

        AiQuota quota = aiQuotaService.snapshot(userId, limit);
        return new AiParseResult(
                verified.guess(), verified.scopeVerified(), verified.unresolvedFields(), quota);
    }

    /**
     * 调用上游大模型，失败映射为 {@code 50301}。
     *
     * @param scopeJson scope JSON
     * @return {@link String} 模型原始输出
     * @throws BizException 上游不可用 → {@code 50301}
     */
    private String generate(String scopeJson) {
        try {
            return aiProvider.generate(scopeJson, SYSTEM_PROMPT);
        } catch (RuntimeException e) {
            // 不打印 scope（含用户明文）；仅记异常类型语义，交全局处理器回 50301
            throw BizException.of(ErrorCode.AI_UNAVAILABLE);
        }
    }

    /**
     * 解析模板（叶子不存在 / 校验失败时返回 {@code null}，不阻塞解析）。
     *
     * @param leafCategoryId 叶子类目 ID（可空）
     * @return {@link TemplateDto} 模板；无有效叶子返回 {@code null}
     */
    private TemplateDto resolveTemplate(Integer leafCategoryId) {
        if (leafCategoryId == null) {
            return null;
        }
        try {
            return templateService.getByLeaf(leafCategoryId);
        } catch (BizException e) {
            // 叶子不存在（40001）视为「无模板」，AI 解析不因草稿不完整而失败
            return null;
        }
    }

    /**
     * 构造 Step 2 的 scope JSON（U ∪ P）。
     *
     * <p><b>ASR TODO</b>：模式② {@code voiceMediaId} 的语音转写应由真实通路在此前完成
     * （通义千问 ASR，备案覆盖内）；dry-run 阶段仅依赖客户端已给的 {@code voiceText}。</p>
     *
     * @param userText  用户文本（U）
     * @param kind      类型（可空）
     * @param leafId    有效叶子类目 ID（可空）
     * @param template  模板（可空）
     * @return {@link String} scope JSON 文本
     */
    private String buildScopeJson(String userText, String kind, Integer leafId, TemplateDto template) {
        Map<String, Object> scope = new LinkedHashMap<>();
        scope.put("text", userText);
        if (kind != null && !kind.isBlank()) {
            scope.put("kind", kind);
        }
        if (leafId != null) {
            scope.put("leaf_category_id", leafId);
        }
        List<Map<String, Object>> fields = new ArrayList<>();
        if (template != null && template.getFields() != null) {
            for (TemplateFieldDto field : template.getFields()) {
                Map<String, Object> item = new LinkedHashMap<>();
                item.put("key", field.getKey());
                if (field.getOptions() != null) {
                    item.put("options", field.getOptions());
                }
                fields.add(item);
            }
        }
        scope.put("template_fields", fields);
        try {
            return objectMapper.writeValueAsString(scope);
        } catch (Exception e) {
            throw BizException.of(ErrorCode.AI_UNAVAILABLE);
        }
    }

    /**
     * Step 4：逆向 Scope 比对（把模型产物逐字段校验，越界即留空）。
     *
     * @param raw       模型原始输出（JSON 文本）
     * @param userText  用户文本（U 集合，溯源依据）
     * @param scopeLeafId scope 中的叶子类目 ID（P 集合）
     * @param template  模板（P 集合）
     * @return {@link Verified} 校验后的猜测 / 来源 / 未解析字段
     * @throws BizException 模型输出非法 JSON 或非对象 → {@code 50301}
     */
    private Verified verifyAgainstScope(String raw, String userText, Integer scopeLeafId,
            TemplateDto template) {
        JsonNode node;
        try {
            node = objectMapper.readTree(raw);
        } catch (Exception e) {
            throw BizException.of(ErrorCode.AI_UNAVAILABLE);
        }
        if (node == null || !node.isObject()) {
            throw BizException.of(ErrorCode.AI_UNAVAILABLE);
        }

        Map<String, String> verified = new LinkedHashMap<>();
        Set<String> unresolved = new LinkedHashSet<>();

        String title = textOrNull(node, FIELD_TITLE);
        Integer leafId = intOrNull(node, FIELD_LEAF_CATEGORY);
        Double price = doubleOrNull(node, FIELD_PRICE);
        String priceUnit = textOrNull(node, FIELD_PRICE_UNIT);
        Map<String, Object> templateValues = verifyTemplateValues(node.path("template_values"),
                userText, template, unresolved);

        // 标题：须能在用户文本中找到源头（包含关系，允许需求前缀/截断）
        if (title != null) {
            if (isTitleSourced(title, userText)) {
                verified.put(FIELD_TITLE, sourceOfUser());
            } else {
                title = null;
                unresolved.add(FIELD_TITLE);
            }
        }
        // 分类：须等于用户在当前草稿已选的叶子类目（P 集合）
        if (leafId != null) {
            if (leafId.equals(scopeLeafId)) {
                verified.put(FIELD_LEAF_CATEGORY, sourceOfPlatform());
            } else {
                leafId = null;
                unresolved.add(FIELD_LEAF_CATEGORY);
            }
        }
        // 价格：其数值须出现在用户文本中
        if (price != null) {
            if (isNumberInText(price, userText)) {
                verified.put(FIELD_PRICE, sourceOfUser());
            } else {
                price = null;
                unresolved.add(FIELD_PRICE);
            }
        }
        // 价格单位：本期无服务端模板来源，只认「文本中出现」
        if (priceUnit != null) {
            if (userText.contains(priceUnit)) {
                verified.put(FIELD_PRICE_UNIT, sourceOfUser());
            } else {
                priceUnit = null;
                unresolved.add(FIELD_PRICE_UNIT);
            }
        }

        AiGuess guess = new AiGuess(
                title,
                leafId,
                price,
                priceUnit,
                templateValues.isEmpty() ? null : templateValues);
        return new Verified(guess, verified, new ArrayList<>(unresolved));
    }

    /**
     * 校验模板字段值：key 必须在模板字段集合内，value 必须在选项内或出现在用户文本中。
     *
     * @param node            模型输出的 {@code template_values} 节点
     * @param userText        用户文本
     * @param template        模板（可空）
     * @param unresolvedSink  未解析字段收集器（追加被拒绝的模板字段 key）
     * @return {@link Map} 通过校验的模板字段（key → value）；无则空 Map
     */
    private Map<String, Object> verifyTemplateValues(JsonNode node, String userText,
            TemplateDto template, Set<String> unresolvedSink) {
        Map<String, Object> result = new LinkedHashMap<>();
        if (node == null || !node.isObject() || template == null || template.getFields() == null) {
            return result;
        }
        Map<String, List<String>> optionsByKey = new HashMap<>();
        for (TemplateFieldDto field : template.getFields()) {
            optionsByKey.put(field.getKey(), field.getOptions());
        }
        for (Map.Entry<String, JsonNode> entry : iterable(node)) {
            String key = entry.getKey();
            String value = entry.getValue().asText("");
            if (!optionsByKey.containsKey(key)) {
                // 模板无此字段 → 编造实体，拒绝
                unresolvedSink.add(key);
                continue;
            }
            List<String> options = optionsByKey.get(key);
            boolean inOptions = options != null && options.contains(value);
            boolean inText = !value.isBlank() && userText.contains(value);
            if (inOptions || inText) {
                result.put(key, value);
            } else {
                unresolvedSink.add(key);
            }
        }
        return result;
    }

    /**
     * 标题是否源于用户文本（包含关系，允许平台加前缀或截断）。
     *
     * @param title    模型标题
     * @param userText 用户文本
     * @return boolean 可溯源返回 {@code true}
     */
    private boolean isTitleSourced(String title, String userText) {
        if (userText.isBlank()) {
            return false;
        }
        return title.contains(userText) || userText.contains(title);
    }

    /**
     * 数值是否出现在用户文本中（抽取文本数字逐一比较）。
     *
     * @param value    模型价格
     * @param userText 用户文本
     * @return boolean 文本中存在相等数字返回 {@code true}
     */
    private boolean isNumberInText(Double value, String userText) {
        Matcher matcher = NUMBER_PATTERN.matcher(userText);
        while (matcher.find()) {
            try {
                if (Math.abs(Double.parseDouble(matcher.group()) - value) < 1e-9) {
                    return true;
                }
            } catch (NumberFormatException ignored) {
                // 正则保证可解析；防御性忽略
            }
        }
        return false;
    }

    /**
     * 合并用户文本（voiceText 优先，可空过滤）。
     *
     * @param voiceText 语音文本
     * @param text      自由文本
     * @return {@link String} 合并文本（可空串）
     */
    private String joinUserText(String voiceText, String text) {
        StringBuilder sb = new StringBuilder();
        if (voiceText != null && !voiceText.isBlank()) {
            sb.append(voiceText.strip());
        }
        if (text != null && !text.isBlank()) {
            if (sb.length() > 0) {
                sb.append('\n');
            }
            sb.append(text.strip());
        }
        return sb.toString();
    }

    /**
     * 判断四模式任一路径是否有输入。
     *
     * @param req      入参
     * @param userText 合并后的文本
     * @return boolean 有任一输入返回 {@code true}
     */
    private boolean hasAnyInput(AiParseRequest req, String userText) {
        return !userText.isBlank()
                || notBlank(req.mediaId())
                || notBlank(req.voiceMediaId());
    }

    /**
     * 取节点文本字段（缺失/非文本/空串返回 {@code null}）。
     *
     * @param node  JSON 对象
     * @param field 字段名
     * @return {@link String} 值或 {@code null}
     */
    private String textOrNull(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.isNull()) {
            return null;
        }
        String text = value.asText("");
        return text.isBlank() ? null : text;
    }

    /**
     * 取节点整数字段（缺失/非数返回 {@code null}）。
     *
     * @param node  JSON 对象
     * @param field 字段名
     * @return {@link Integer} 值或 {@code null}
     */
    private Integer intOrNull(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value != null && value.isNumber() ? value.asInt() : null;
    }

    /**
     * 取节点浮点字段（缺失/非数返回 {@code null}）。
     *
     * @param node  JSON 对象
     * @param field 字段名
     * @return {@link Double} 值或 {@code null}
     */
    private Double doubleOrNull(JsonNode node, String field) {
        JsonNode value = node.get(field);
        return value != null && value.isNumber() ? value.asDouble() : null;
    }

    /**
     * JSON 对象字段迭代器。
     *
     * @param node JSON 对象节点
     * @return {@link Iterable} 字段条目
     */
    private Iterable<Map.Entry<String, JsonNode>> iterable(JsonNode node) {
        return node::fields;
    }

    /**
     * 字符串非空白判定。
     *
     * @param value 字符串
     * @return boolean 非空返回 {@code true}
     */
    private boolean notBlank(String value) {
        return value != null && !value.isBlank();
    }

    /**
     * 来源：用户输入（U 集合）。
     *
     * @return {@link String} 契约枚举值
     */
    private String sourceOfUser() {
        return "user_input";
    }

    /**
     * 来源：平台已知（P 集合）。
     *
     * @return {@link String} 契约枚举值
     */
    private String sourceOfPlatform() {
        return "platform";
    }

    /**
     * Step 4 校验结果载体。
     *
     * @param guess            校验后的四件套
     * @param scopeVerified    已注入字段来源
     * @param unresolvedFields 被拒绝注入的字段
     */
    private record Verified(AiGuess guess, Map<String, String> scopeVerified,
            List<String> unresolvedFields) {
    }
}
