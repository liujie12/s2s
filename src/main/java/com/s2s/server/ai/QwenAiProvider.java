package com.s2s.server.ai;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.s2s.server.ai.dto.CertProfileGuess;
import com.s2s.server.common.constants.NfrAi;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.LocalTime;
import java.time.ZoneId;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/**
 * 通义千问（阿里云百炼 OpenAI 兼容接口）实现（B2-4 阶段①）。
 *
 * <p><b>两种模式</b>：{@code s2s.ai.dry-run=true}（默认）走纯规则的 Scope 内抽取桩；
 * {@code false} 走真实 HTTP 调用（本阶段新增）。业务代码（{@link AiParseService}）两态不动。</p>
 *
 * <p><b>dry-run 不是 AI，也不假装是</b>：它只做「从 scope 里按可验证规则搬运」——
 * 标题 = 用户文本；分类 = 请求已给的叶子类目；价格 = 文本中出现的数字；模板字段 =
 * 文本中出现的模板选项。<b>绝不编造</b>，与 PRD §5.10 的产物约束一致；这也使 dry-run
 * 的输出天然能通过 Step 4 逆向比对。</p>
 *
 * <p><b>真实通道</b>（PRD §5.10 Step 3）：把 Step 2 的 scope 作为 user 消息、把
 * {@link AiParseService} 的严格 Scope 提示词作为 system 消息，POST 到
 * {@code {s2s.ai.endpoint}/chat/completions}（百炼 OpenAI 兼容，官方口径：Bearer 鉴权 +
 * {@code messages[].role/content}）。<b>本类仍不信任模型产物</b>——Step 4 逆向比对由
 * {@link AiParseService} 独立承担。</p>
 *
 * <p><b>多模态（Step 2，2026-10-15）</b>：scope 含 {@code media} 图片时 user 消息改 content
 * 数组（text + image_url 部件）并切 {@code s2s.ai.omni-model}；模式② 音频经
 * {@link #transcribe} 独立转写（input_audio 部件），产物由 {@code AiParseService} 并入
 * U 集合后再走本类 {@link #generate}。图/音均以 OSS 只读签名 URL 入参（官方兼容口径）。</p>
 *
 * <p><b>安全</b>：本类不写业务日志（scope 与模型输出均含用户输入明文，编码规范 §4.11）。</p>
 */
@Component
public class QwenAiProvider implements AiProvider {

    /** 百炼 OpenAI 兼容的对话补全路径（相对 {@code s2s.ai.endpoint}）。 */
    private static final String CHAT_COMPLETIONS_PATH = "/chat/completions";

    /** Authorization 头前缀（Bearer 方案，官方口径）。 */
    private static final String BEARER_PREFIX = "Bearer ";

    /** OpenAI 兼容消息角色。 */
    private static final String ROLE_SYSTEM = "system";
    private static final String ROLE_USER = "user";

    /** 多模态 content 部件类型（官方 OpenAI 兼容口径）。 */
    private static final String PART_TYPE_TEXT = "text";
    private static final String PART_TYPE_IMAGE = "image_url";
    private static final String PART_TYPE_AUDIO = "input_audio";

    /** 顶层思考力度参数名（官方 Chat Completions 口径；仅 omni 档携带，文本档不传）。 */
    private static final String KEY_REASONING_EFFORT = "reasoning_effort";

    /**
     * omni 档思考力度（官方 Chat Completions <b>顶层</b>参数 {@code reasoning_effort}，
     * 非 OpenAI 标准参数）。
     *
     * <p><b>为什么取 {@code none}</b>：Qwen3.8-Omni-Flash 属混合思考模式且<b>默认
     * {@code xhigh}</b>（官方《深度思考》「支持的模型」节：千问3.8 Omni 系列默认开启思考、
     * 通过 {@code reasoning_effort} 调节；《Qwen-Omni》文档同口径）。2026-10-16 线上实测
     * （同一张图同 prompt）：{@code xhigh} 15.5s / {@code high} 16.4s / {@code medium} 9.3s /
     * {@code 不传} 8.4s / {@code minimal} 9.3s / {@code low} 7.9s / {@code none} <b>6.3s</b>。
     * 而本域读上游超时为 {@link NfrAi#UPSTREAM_TIMEOUT_SECONDS} 秒、客户端读取超时同为
     * 10 秒（前端 {@code NfrNetwork.readTimeoutSec}）—— 凡耗时 ≥10s 的档位必然双杀（后端
     * 超时 → 50301；即便后端扛住，前端也先断）。故取实测最快、且 {@code finish_reason=stop}
     * （未截断）的 {@code none}。</p>
     *
     * <p><b>历史订正</b>：原实现传 {@code enable_thinking=false}（那是 Qwen3.8-max/flash
     * 等文本系列的参数），2026-10-16 线上实测其在 omni 档不生效 —— 同一请求仍耗时 8.4s
     * 且 {@code finish_reason=length}（被 {@link NfrAi#UPSTREAM_MAX_TOKENS} 截断）。</p>
     */
    private static final String OMNI_REASONING_EFFORT = "none";

    /** 转写指令（模式② ASR；只要求逐字转写，不夹带生成任务，避免引入转写外产物）。 */
    private static final String TRANSCRIBE_INSTRUCTION =
            "请将这段语音逐字转写为文字，仅输出转写文本，不要输出任何解释。";

    /**
     * 证照图抽取指令（资质档案预填）。
     *
     * <p>只允许读证件上的既有信息，读不出就省略字段——与「抽取失败不阻断」口径一致，
     * 也避免模型为凑结构而编造证名或有效期。</p>
     */
    private static final String CERT_OCR_INSTRUCTION =
            "你是证件信息读取器，只输出一个 JSON 对象，不要任何解释或 Markdown 代码块。"
            + "读取这张证件照片，输出："
            + "{\"cert_name\":字符串（证件名称，如「家政服务资质」「养老护理员证」）,"
            + "\"expire_at\":字符串（有效期至，格式 YYYY-MM-DD 或 YYYY-MM；"
            + "证件写「长期有效」则省略）}。"
            + "读不出的字段直接省略，禁止猜测。";

    /** 证名截断上限（对齐 {@code cert.cert_name} VARCHAR(64)）。 */
    private static final int CERT_NAME_MAX_LENGTH = 64;

    /** 证照有效期解析正则：取年、月与可选日，忽略「年/月/日」「-」「.」等分隔符。 */
    private static final Pattern CERT_EXPIRE_PATTERN =
            Pattern.compile("(\\d{4})\\D{0,3}(\\d{1,2})(?:\\D{0,3}(\\d{1,2}))?");

    /**
     * 音频 MIME → 上游 {@code input_audio.format} 映射。
     *
     * <p>官方示例取值为扩展名风格（已核实 {@code "wav"}；其余按上传白名单
     * （{@code NfrMedia.AUDIO_CONTENT_TYPES}）逐一对应，真机验收时校准）。</p>
     */
    private static final Map<String, String> AUDIO_FORMAT_BY_MIME = Map.of(
            "audio/mpeg", "mp3",
            "audio/mp4", "m4a",
            "audio/aac", "aac",
            "audio/wav", "wav",
            "audio/x-m4a", "m4a");

    /** 数字抽取正则（价格猜测用；简单取首个数字，不做单位推断）。 */
    private static final Pattern NUMBER_PATTERN = Pattern.compile("\\d+(?:\\.\\d+)?");

    /** 标题截断上限（对齐契约 maxLength 40）。 */
    private static final int TITLE_MAX_LENGTH = 40;

    /** 是否走 dry-run mock（默认 true）。真服务联调前置 false 即走真实 HTTP 分支。 */
    private final boolean dryRun;

    /** 百炼 API Key（{@code s2s.ai.api-key}，环境变量 DASHSCOPE_API_KEY）；dry-run 不消费。 */
    private final String apiKey;

    /** 文本模型名（{@code s2s.ai.model}，如 qwen-plus）；dry-run 不消费。 */
    private final String model;

    /** 多模态模型名（{@code s2s.ai.omni-model}；图入参与 ASR 用）；dry-run 不消费。 */
    private final String omniModel;

    /** 上游 HTTP 客户端（baseUrl + 超时，见 {@code AiClientConfig}）；dry-run 不消费。 */
    private final RestClient aiRestClient;

    /** JSON 解析器（scopeJson 读取、请求体构造与响应解析）。 */
    private final ObjectMapper objectMapper;

    /** AI 费用台账（真实调用按响应 usage 折算微元后记账；dry-run 不写）。 */
    private final AiCostLedger costLedger;

    /**
     * 构造通义千问实现。
     *
     * @param dryRun       是否走 dry-run mock（配置 {@code s2s.ai.dry-run}，默认 true）
     * @param apiKey       百炼 API Key（配置 {@code s2s.ai.api-key}，默认空；真实通道必填）
     * @param model        文本模型名（配置 {@code s2s.ai.model}）
     * @param omniModel    多模态模型名（配置 {@code s2s.ai.omni-model}）
     * @param aiRestClient 上游 HTTP 客户端（{@code AiClientConfig#aiRestClient}）
     * @param objectMapper JSON 解析器
     * @param costLedger   AI 费用台账（真实调用记账）
     */
    public QwenAiProvider(
            @Value("${s2s.ai.dry-run:true}") boolean dryRun,
            @Value("${s2s.ai.api-key:}") String apiKey,
            @Value("${s2s.ai.model}") String model,
            @Value("${s2s.ai.omni-model}") String omniModel,
            RestClient aiRestClient,
            ObjectMapper objectMapper,
            AiCostLedger costLedger) {
        this.dryRun = dryRun;
        this.apiKey = apiKey;
        this.model = model;
        this.omniModel = omniModel;
        this.aiRestClient = aiRestClient;
        this.objectMapper = objectMapper;
        this.costLedger = costLedger;
    }

    /**
     * 生成四件套。
     *
     * @param userId       发起调用的用户 ID（真实通道记账用；dry-run 忽略）
     * @param scopeJson    Step 2 产出的 scope JSON（含 text / leaf_category_id / template_fields）
     * @param systemPrompt 系统提示词（严格 Scope 约束，见 {@link AiParseService}）
     * @return {@link String} 与 {@code AiGuess} 同构的 JSON 文本
     * @throws IllegalStateException 上游不可用 / 未配置 Key / 响应结构非法（调用方映射 50301）
     */
    @Override
    public String generate(Long userId, String scopeJson, String systemPrompt) {
        return dryRun ? generateByRules(scopeJson) : generateByModel(userId, scopeJson, systemPrompt);
    }

    /**
     * 真实通道：调用百炼 OpenAI 兼容对话补全，取回模型输出的 JSON 文本，并按响应
     * {@code usage} 折算费用记入台账。
     *
     * @param userId       发起调用的用户 ID（记账归属）
     * @param scopeJson    scope JSON（作为 user 消息内容）
     * @param systemPrompt 严格 Scope 提示词（作为 system 消息内容）
     * @return {@link String} 模型输出中提取出的 JSON 对象文本（已去代码块包裹）
     * @throws IllegalStateException 未配置 Key / 上游异常 / 响应结构非法
     */
    private String generateByModel(Long userId, String scopeJson, String systemPrompt) {
        requireApiKey();
        List<String> imageUrls = extractImageUrls(scopeJson);
        String payload;
        try {
            payload = imageUrls.isEmpty()
                    ? buildChatPayload(scopeJson, systemPrompt, model)
                    : buildMultimodalPayload(scopeJson, systemPrompt, imageUrls);
        } catch (Exception e) {
            throw new IllegalStateException("构造通义千问请求体失败", e);
        }
        String body;
        try {
            body = aiRestClient.post()
                    .uri(CHAT_COMPLETIONS_PATH)
                    .header(HttpHeaders.AUTHORIZATION, BEARER_PREFIX + apiKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(payload)
                    .retrieve()
                    .body(String.class);
        } catch (RestClientException e) {
            // 含网络超时（ResourceAccessException）与非 2xx（RestClientResponseException）
            throw new IllegalStateException("通义千问调用失败", e);
        }
        JsonNode root = parseResponse(body);
        String content = extractContentNode(root);
        boolean multimodal = !imageUrls.isEmpty();
        recordCost(userId, root,
                multimodal ? NfrAi.PRICE_OMNI_INPUT_MICROYUAN_PER_1K
                        : NfrAi.PRICE_TEXT_INPUT_MICROYUAN_PER_1K,
                multimodal ? NfrAi.PRICE_OMNI_OUTPUT_MICROYUAN_PER_1K
                        : NfrAi.PRICE_TEXT_OUTPUT_MICROYUAN_PER_1K);
        return extractJsonObject(content);
    }

    /**
     * 构造 OpenAI 兼容的对话补全请求体。
     *
     * @param scopeJson    scope JSON（user 消息内容）
     * @param systemPrompt 系统提示词（system 消息内容）
     * @param modelName    模型名（文本档）
     * @return {@link String} 请求体 JSON
     * @throws Exception JSON 序列化失败
     */
    private String buildChatPayload(String scopeJson, String systemPrompt, String modelName)
            throws Exception {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("model", modelName);
        ArrayNode messages = root.putArray("messages");
        ObjectNode system = messages.addObject();
        system.put("role", ROLE_SYSTEM);
        system.put("content", systemPrompt == null ? "" : systemPrompt);
        ObjectNode user = messages.addObject();
        user.put("role", ROLE_USER);
        user.put("content", scopeJson == null ? "{}" : scopeJson);
        // 输出上限单源引用常量（禁写死数字）；不设 temperature/response_format —— 用未在官方
        // 兼容表内确认的参数会带来不确定性，产物的确定性由 Step 4 逆向比对而非采样参数保证
        root.put("max_tokens", NfrAi.UPSTREAM_MAX_TOKENS);
        return objectMapper.writeValueAsString(root);
    }

    /**
     * 音频转写（模式② ASR，独立调用；2026-10-15 用户裁定）。
     *
     * <p>dry-run 返回空串（桩不做 ASR，模式② 依赖客户端 {@code voiceText}，与 Step 2 前
     * 行为一致）；真实通道把音频 URL 交多模态模型逐字转写，取回纯文本（不做 JSON 抽取）。</p>
     *
     * @param userId           发起调用的用户 ID（真实通道记账）
     * @param audioUrl         音频只读短时效 URL
     * @param audioContentType 音频 MIME 类型
     * @return {@link String} 转写文本；dry-run 恒为空串
     * @throws IllegalStateException 未配置 Key / MIME 无 format 映射 / 上游异常 / 响应结构非法
     */
    @Override
    public String transcribe(Long userId, String audioUrl, String audioContentType) {
        if (dryRun) {
            return "";
        }
        requireApiKey();
        String format = audioFormatOf(audioContentType);
        String payload;
        try {
            payload = buildTranscribePayload(audioUrl, format);
        } catch (Exception e) {
            throw new IllegalStateException("构造通义千问转写请求体失败", e);
        }
        String body;
        try {
            body = aiRestClient.post()
                    .uri(CHAT_COMPLETIONS_PATH)
                    .header(HttpHeaders.AUTHORIZATION, BEARER_PREFIX + apiKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(payload)
                    .retrieve()
                    .body(String.class);
        } catch (RestClientException e) {
            // 含网络超时与非 2xx；口径与 generateByModel 一致
            throw new IllegalStateException("通义千问转写调用失败", e);
        }
        JsonNode root = parseResponse(body);
        String text = extractPlainTextNode(root);
        // 转写链路输入是音频：按音频单价保守计；输出仍按 omni 文本输出价
        recordCost(userId, root,
                NfrAi.PRICE_AUDIO_INPUT_MICROYUAN_PER_1K,
                NfrAi.PRICE_OMNI_OUTPUT_MICROYUAN_PER_1K);
        return text;
    }

    /**
     * 从证照图抽取证名与有效期（资质档案预填）。
     *
     * <p>dry-run 返回空结果（桩不做 OCR，前端按「读不出来」处理，用户手填）；
     * 真实通道把证照图交多模态模型，取回 JSON 后逐字段宽松解析——读不出即留空，
     * 不抛异常，避免「图糊了」把添加资质整条流程挡死。</p>
     *
     * @param userId      发起调用的用户 ID（真实通道记账）
     * @param imageUrl    证照图只读短时效 URL
     * @param contentType 图片 MIME 类型（多模态入参只用 URL，保留以便换供应商时使用）
     * @return {@link CertProfileGuess} 证名与有效期（均可空）
     * @throws IllegalStateException 未配置 Key / 上游异常 / 响应结构非法
     */
    @Override
    public CertProfileGuess extractCertProfile(Long userId, String imageUrl, String contentType) {
        if (dryRun) {
            return CertProfileGuess.empty();
        }
        requireApiKey();
        String payload;
        try {
            payload = buildCertOcrPayload(imageUrl);
        } catch (Exception e) {
            throw new IllegalStateException("构造通义千问证照抽取请求体失败", e);
        }
        String body;
        try {
            body = aiRestClient.post()
                    .uri(CHAT_COMPLETIONS_PATH)
                    .header(HttpHeaders.AUTHORIZATION, BEARER_PREFIX + apiKey)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(payload)
                    .retrieve()
                    .body(String.class);
        } catch (RestClientException e) {
            // 含网络超时与非 2xx；口径与 generateByModel 一致
            throw new IllegalStateException("通义千问证照抽取调用失败", e);
        }
        JsonNode root = parseResponse(body);
        String content = contentOf(root);
        recordCost(userId, root,
                NfrAi.PRICE_OMNI_INPUT_MICROYUAN_PER_1K,
                NfrAi.PRICE_OMNI_OUTPUT_MICROYUAN_PER_1K);
        return parseCertProfile(content);
    }

    /**
     * 构造证照抽取请求体（单图 + 抽取指令，走多模态档）。
     *
     * @param imageUrl 证照图只读签名 URL
     * @return {@link String} 请求体 JSON
     * @throws Exception JSON 序列化失败
     */
    private String buildCertOcrPayload(String imageUrl) throws Exception {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("model", omniModel);
        ArrayNode messages = root.putArray("messages");
        ObjectNode user = messages.addObject();
        user.put("role", ROLE_USER);
        ArrayNode content = user.putArray("content");
        ObjectNode textPart = content.addObject();
        textPart.put("type", PART_TYPE_TEXT);
        textPart.put("text", CERT_OCR_INSTRUCTION);
        ObjectNode imagePart = content.addObject();
        imagePart.put("type", PART_TYPE_IMAGE);
        imagePart.putObject("image_url").put("url", imageUrl);
        root.put(KEY_REASONING_EFFORT, OMNI_REASONING_EFFORT);
        root.put("max_tokens", NfrAi.UPSTREAM_MAX_TOKENS);
        return objectMapper.writeValueAsString(root);
    }

    /**
     * 解析证照抽取的模型输出（宽松解析：任何字段读不出都留空，不抛异常）。
     *
     * @param content 模型输出原文（可含代码块包裹）
     * @return {@link CertProfileGuess} 证名与有效期（均可空）
     */
    private CertProfileGuess parseCertProfile(String content) {
        if (content == null || content.isBlank()) {
            return CertProfileGuess.empty();
        }
        JsonNode node;
        try {
            node = objectMapper.readTree(extractJsonObject(content));
        } catch (Exception e) {
            return CertProfileGuess.empty();
        }
        String certName = node.path("cert_name").asText("").strip();
        if (certName.length() > CERT_NAME_MAX_LENGTH) {
            certName = certName.substring(0, CERT_NAME_MAX_LENGTH);
        }
        String expireRaw = node.path("expire_at").asText("").strip();
        return new CertProfileGuess(certName.isBlank() ? null : certName,
                parseCertExpireAt(expireRaw));
    }

    /**
     * 解析证照上的有效期文本为到期时刻。
     *
     * <p>证件只给年月时落**当月最后一天 23:59:59**（该月内仍有效，与额度/到期任务
     * 的「已过即失效」口径一致）；给了具体日期则落当日 23:59:59。时区取 JVM 默认，
     * 与库内 {@code DATETIME} 的写入基准一致。</p>
     *
     * @param raw 模型给出的有效期文本（如 {@code 2027-06}、{@code 2027年6月30日}）
     * @return {@link Instant} 到期时刻；无法解析返回 {@code null}
     */
    private Instant parseCertExpireAt(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        Matcher matcher = CERT_EXPIRE_PATTERN.matcher(raw);
        if (!matcher.find()) {
            return null;
        }
        try {
            int year = Integer.parseInt(matcher.group(1));
            int month = Integer.parseInt(matcher.group(2));
            if (month < 1 || month > 12) {
                return null;
            }
            LocalDate date = LocalDate.of(year, month, 1);
            String dayText = matcher.group(3);
            if (dayText != null) {
                int day = Integer.parseInt(dayText);
                if (day < 1 || day > date.lengthOfMonth()) {
                    return null;
                }
                date = date.withDayOfMonth(day);
            } else {
                date = date.withDayOfMonth(date.lengthOfMonth());
            }
            return LocalDateTime.of(date, LocalTime.of(23, 59, 59))
                    .atZone(ZoneId.systemDefault()).toInstant();
        } catch (RuntimeException e) {
            // 年份越界等非法值 → 视为读不出（不抛，流程不阻断）
            return null;
        }
    }

    /**
     * 真实通道前置：API Key 必须已配置。
     *
     * @throws IllegalStateException 未配置 Key（配置缺失属部署缺陷：不打印 Key，也不回退
     *         dry-run——静默降级会掩盖线上故障）
     */
    private void requireApiKey() {
        if (apiKey == null || apiKey.isBlank()) {
            throw new IllegalStateException(
                    "s2s.ai.dry-run=false，但未配置 s2s.ai.api-key（环境变量 DASHSCOPE_API_KEY）");
        }
    }

    /**
     * 构造多模态对话补全请求体（scope 含图片时）：user 消息为 content 数组
     * （text + image_url 部件，官方 OpenAI 兼容口径），模型切多模态档。
     *
     * @param scopeJson    scope JSON（text 部件内容）
     * @param systemPrompt 系统提示词（system 消息内容）
     * @param imageUrls    图片只读签名 URL 列表（image_url 部件）
     * @return {@link String} 请求体 JSON
     * @throws Exception JSON 序列化失败
     */
    private String buildMultimodalPayload(String scopeJson, String systemPrompt,
            List<String> imageUrls) throws Exception {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("model", omniModel);
        ArrayNode messages = root.putArray("messages");
        ObjectNode system = messages.addObject();
        system.put("role", ROLE_SYSTEM);
        system.put("content", systemPrompt == null ? "" : systemPrompt);
        ObjectNode user = messages.addObject();
        user.put("role", ROLE_USER);
        ArrayNode content = user.putArray("content");
        ObjectNode textPart = content.addObject();
        textPart.put("type", PART_TYPE_TEXT);
        textPart.put("text", scopeJson == null ? "{}" : scopeJson);
        for (String url : imageUrls) {
            ObjectNode imagePart = content.addObject();
            imagePart.put("type", PART_TYPE_IMAGE);
            imagePart.putObject("image_url").put("url", url);
        }
        root.put(KEY_REASONING_EFFORT, OMNI_REASONING_EFFORT);
        root.put("max_tokens", NfrAi.UPSTREAM_MAX_TOKENS);
        return objectMapper.writeValueAsString(root);
    }

    /**
     * 构造音频转写请求体（input_audio 部件，官方 OpenAI 兼容口径）；转写恒走多模态档。
     *
     * @param audioUrl 音频只读签名 URL
     * @param format   上游 {@code input_audio.format}（由 MIME 映射）
     * @return {@link String} 请求体 JSON
     * @throws Exception JSON 序列化失败
     */
    private String buildTranscribePayload(String audioUrl, String format) throws Exception {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("model", omniModel);
        ArrayNode messages = root.putArray("messages");
        ObjectNode user = messages.addObject();
        user.put("role", ROLE_USER);
        ArrayNode content = user.putArray("content");
        ObjectNode textPart = content.addObject();
        textPart.put("type", PART_TYPE_TEXT);
        textPart.put("text", TRANSCRIBE_INSTRUCTION);
        ObjectNode audioPart = content.addObject();
        audioPart.put("type", PART_TYPE_AUDIO);
        ObjectNode inputAudio = audioPart.putObject("input_audio");
        inputAudio.put("data", audioUrl);
        inputAudio.put("format", format);
        root.put(KEY_REASONING_EFFORT, OMNI_REASONING_EFFORT);
        root.put("max_tokens", NfrAi.UPSTREAM_MAX_TOKENS);
        return objectMapper.writeValueAsString(root);
    }

    /**
     * 从 scope JSON 提取图片 URL（{@code media[]} 中 {@code type=image} 项）。
     *
     * @param scopeJson scope JSON
     * @return {@link List} 图片 URL 列表；无 media / 解析失败返回空表（不阻塞文本通道，
     *         scope 合法性由 Step 4 兜底）
     */
    private List<String> extractImageUrls(String scopeJson) {
        List<String> urls = new ArrayList<>();
        try {
            JsonNode media = objectMapper.readTree(scopeJson == null ? "{}" : scopeJson)
                    .path("media");
            if (media.isArray()) {
                for (JsonNode item : media) {
                    if ("image".equals(item.path("type").asText(""))) {
                        String url = item.path("url").asText("");
                        if (!url.isBlank()) {
                            urls.add(url);
                        }
                    }
                }
            }
        } catch (Exception e) {
            return List.of();
        }
        return urls;
    }

    /**
     * 音频 MIME 映射上游 {@code input_audio.format}。
     *
     * @param contentType 音频 MIME 类型
     * @return {@link String} format 取值
     * @throws IllegalStateException 白名单外 MIME（调用方映射 50301）
     */
    private String audioFormatOf(String contentType) {
        String format = AUDIO_FORMAT_BY_MIME.get(contentType == null ? "" : contentType);
        if (format == null) {
            throw new IllegalStateException("音频 MIME 无上游 format 映射");
        }
        return format;
    }

    /**
     * 解析响应体为 JSON 树。
     *
     * @param body 响应体文本（可空）
     * @return {@link JsonNode} 根节点
     * @throws IllegalStateException 响应不是 JSON
     */
    private JsonNode parseResponse(String body) {
        try {
            return objectMapper.readTree(body == null ? "" : body);
        } catch (Exception e) {
            throw new IllegalStateException("通义千问响应不是 JSON", e);
        }
    }

    /**
     * 从对话补全响应取纯文本（转写用；不做 JSON 对象抽取）。
     *
     * @param root 已解析的响应根节点
     * @return {@link String} choices[0].message.content 原文（去首尾空白）
     * @throws IllegalStateException 缺 content
     */
    private String extractPlainTextNode(JsonNode root) {
        String content = contentOf(root);
        if (content.isBlank()) {
            throw new IllegalStateException("通义千问响应缺少 choices[0].message.content");
        }
        return content.strip();
    }

    /**
     * 从对话补全响应中取出 {@code choices[0].message.content}（未剥离代码块）。
     *
     * @param root 已解析的响应根节点
     * @return {@link String} content 原文；缺失时返回空串
     */
    private String contentOf(JsonNode root) {
        JsonNode content = root.path("choices").path(0).path("message").path("content");
        return content.isMissingNode() ? "" : content.asText("");
    }

    /**
     * 从对话补全响应中取出 {@code choices[0].message.content} 并剥离代码块包裹。
     *
     * @param root 已解析的响应根节点
     * @return {@link String} 提取出的 JSON 对象文本
     * @throws IllegalStateException 缺 content / content 内无 JSON 对象
     */
    private String extractContentNode(JsonNode root) {
        String content = contentOf(root);
        if (content.isBlank()) {
            throw new IllegalStateException("通义千问响应缺少 choices[0].message.content");
        }
        return content;
    }

    /**
     * 按上游 {@code usage} 折算本次调用费用并记入台账。
     *
     * <p>兼容 OpenAI 字段名（{@code prompt_tokens}/{@code completion_tokens}）与
     * DashScope 字段名（{@code input_tokens}/{@code output_tokens}）。两者都缺失时按
     * {@link NfrAi#COST_FALLBACK_PER_CALL_MICROYUAN} 兜底，避免「无 usage 即免费」。</p>
     *
     * @param userId              用户 ID
     * @param root                响应根节点
     * @param inputPricePer1K     输入单价（微元/千 token）
     * @param outputPricePer1K    输出单价（微元/千 token）
     */
    private void recordCost(Long userId, JsonNode root, long inputPricePer1K, long outputPricePer1K) {
        JsonNode usage = root.path("usage");
        long inputTokens = tokenOf(usage, "prompt_tokens", "input_tokens");
        long outputTokens = tokenOf(usage, "completion_tokens", "output_tokens");
        long cost = (inputTokens <= 0L && outputTokens <= 0L)
                ? NfrAi.COST_FALLBACK_PER_CALL_MICROYUAN
                : tokenCost(inputTokens, inputPricePer1K) + tokenCost(outputTokens, outputPricePer1K);
        costLedger.record(userId, cost);
    }

    /**
     * 从 usage 节点读取 token 数（先试主字段、再试别名，缺失返回 0）。
     *
     * @param usage     usage 节点
     * @param primary   主字段名（OpenAI 口径）
     * @param alternate 别名字段名（DashScope 口径）
     * @return long token 数；缺失或非数字返回 0
     */
    private long tokenOf(JsonNode usage, String primary, String alternate) {
        JsonNode node = usage.path(primary);
        if (!node.isNumber()) {
            node = usage.path(alternate);
        }
        return node.isNumber() ? node.asLong() : 0L;
    }

    /**
     * token 数折算费用（微元），向上取整（保守，宁多不少）。
     *
     * @param tokens        token 数
     * @param pricePer1K    每千 token 单价（微元）
     * @return long 费用（微元）；tokens ≤ 0 返回 0
     */
    private long tokenCost(long tokens, long pricePer1K) {
        if (tokens <= 0L) {
            return 0L;
        }
        return (tokens * pricePer1K + 999L) / 1000L;
    }

    /**
     * 剥掉模型常见的 {@code ```json} 代码块与前后解释文字，只留 JSON 对象。
     *
     * @param raw 模型输出原文
     * @return {@link String} 从首个 {@code {} 到末个 {@code }} 的子串
     * @throws IllegalStateException 不含 JSON 对象
     */
    private String extractJsonObject(String raw) {
        String text = raw.strip();
        int start = text.indexOf('{');
        int end = text.lastIndexOf('}');
        if (start < 0 || end <= start) {
            throw new IllegalStateException("通义千问输出未包含 JSON 对象");
        }
        return text.substring(start, end + 1);
    }

    /**
     * dry-run 通道：Scope 内规则抽取（原桩逻辑，逐字节保留）。
     *
     * @param scopeJson scope JSON
     * @return {@link String} 与 {@code AiGuess} 同构的 JSON 文本
     * @throws IllegalStateException 内部 JSON 组装失败
     */
    private String generateByRules(String scopeJson) {
        try {
            JsonNode scope = objectMapper.readTree(scopeJson == null ? "{}" : scopeJson);
            ObjectNode guess = objectMapper.createObjectNode();

            String text = scope.path("text").asText("");
            // 标题：用户文本前 40 字；无文本则不猜
            if (!text.isBlank()) {
                guess.put("title", abbreviate(text.strip()));
            }

            // 分类：仅回显请求已给的叶子类目（platform，P 集合）
            if (scope.hasNonNull("leaf_category_id")) {
                guess.put("leaf_category_id", scope.get("leaf_category_id").asInt());
            }

            Matcher number = NUMBER_PATTERN.matcher(text);
            if (number.find()) {
                guess.put("price", Double.parseDouble(number.group()));
            }

            // 模板字段：值必须是该字段选项之一且出现在文本中（P 集合）
            ObjectNode templateValues = objectMapper.createObjectNode();
            JsonNode fields = scope.path("template_fields");
            if (fields.isArray()) {
                for (JsonNode field : fields) {
                    String key = field.path("key").asText("");
                    if (key.isBlank()) {
                        continue;
                    }
                    JsonNode options = field.path("options");
                    if (!options.isArray()) {
                        continue;
                    }
                    for (Iterator<JsonNode> it = options.elements(); it.hasNext(); ) {
                        String option = it.next().asText("");
                        if (!option.isBlank() && text.contains(option)) {
                            templateValues.put(key, option);
                            break;
                        }
                    }
                }
            }
            if (!templateValues.isEmpty()) {
                guess.set("template_values", templateValues);
            }
            return objectMapper.writeValueAsString(guess);
        } catch (Exception e) {
            // 内部 JSON 组装失败属缺陷，映射为上游不可用（50301），不泄漏细节
            throw new IllegalStateException("AI dry-run 生成失败", e);
        }
    }

    /**
     * 标题截断到契约上限。
     *
     * @param value 原始文本
     * @return {@link String} 截断后的标题
     */
    private String abbreviate(String value) {
        return value.length() <= TITLE_MAX_LENGTH ? value : value.substring(0, TITLE_MAX_LENGTH);
    }
}
