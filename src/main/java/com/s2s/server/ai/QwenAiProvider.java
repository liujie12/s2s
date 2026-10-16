package com.s2s.server.ai;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.s2s.server.common.constants.NfrAi;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;
import org.springframework.web.client.RestClientResponseException;

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
 * <p><b>安全</b>：本类不写业务日志（scope 与模型输出均含用户输入明文，编码规范 §4.11）。
 * 例外：{@link #logUpstreamFailure} 是 <b>B2-4 Step 2 验收期临时诊断</b>，只记录异常类名 /
 * 上游 HTTP 状态码 / 上游错误响应体（上游错误体不含用户输入），定位根因后随即移除。</p>
 */
@Component
public class QwenAiProvider implements AiProvider {

    /** 【临时诊断】日志器：仅用于 B2-4 Step 2 验收期定位 50301 根因，定位后随本补丁移除。 */
    private static final Logger log = LoggerFactory.getLogger(QwenAiProvider.class);

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

    /**
     * omni 档是否开启思考（官方 {@code enable_thinking} 参数，非 OpenAI 标准参数）。
     *
     * <p>固定 {@code false}：Qwen3.8-Omni-Flash 属混合思考模式且<b>默认开启思考</b>
     * （官方《深度思考》《Qwen-Omni》文档，2026-10-15 口径），带思考的看图解析耗时
     * 超过 {@link NfrAi#UPSTREAM_TIMEOUT_SECONDS}（实测超时 → 50301，真机模式① 复现）；
     * 关闭后实测 2.1s 内返回且产物 JSON 正常。官方 Qwen-Omni 文档明确该模型
     * 「支持通过 enable_thinking 开启或关闭思考」，参数合规性已核实。</p>
     */
    private static final boolean OMNI_ENABLE_THINKING = false;

    /** 转写指令（模式② ASR；只要求逐字转写，不夹带生成任务，避免引入转写外产物）。 */
    private static final String TRANSCRIBE_INSTRUCTION =
            "请将这段语音逐字转写为文字，仅输出转写文本，不要输出任何解释。";

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

    /**
     * 构造通义千问实现。
     *
     * @param dryRun       是否走 dry-run mock（配置 {@code s2s.ai.dry-run}，默认 true）
     * @param apiKey       百炼 API Key（配置 {@code s2s.ai.api-key}，默认空；真实通道必填）
     * @param model        文本模型名（配置 {@code s2s.ai.model}）
     * @param omniModel    多模态模型名（配置 {@code s2s.ai.omni-model}）
     * @param aiRestClient 上游 HTTP 客户端（{@code AiClientConfig#aiRestClient}）
     * @param objectMapper JSON 解析器
     */
    public QwenAiProvider(
            @Value("${s2s.ai.dry-run:true}") boolean dryRun,
            @Value("${s2s.ai.api-key:}") String apiKey,
            @Value("${s2s.ai.model}") String model,
            @Value("${s2s.ai.omni-model}") String omniModel,
            RestClient aiRestClient,
            ObjectMapper objectMapper) {
        this.dryRun = dryRun;
        this.apiKey = apiKey;
        this.model = model;
        this.omniModel = omniModel;
        this.aiRestClient = aiRestClient;
        this.objectMapper = objectMapper;
    }

    /**
     * 生成四件套。
     *
     * @param scopeJson     Step 2 产出的 scope JSON（含 text / leaf_category_id / template_fields）
     * @param systemPrompt  系统提示词（严格 Scope 约束，见 {@link AiParseService}）
     * @return {@link String} 与 {@code AiGuess} 同构的 JSON 文本
     * @throws IllegalStateException 上游不可用 / 未配置 Key / 响应结构非法（调用方映射 50301）
     */
    @Override
    public String generate(String scopeJson, String systemPrompt) {
        return dryRun ? generateByRules(scopeJson) : generateByModel(scopeJson, systemPrompt);
    }

    /**
     * 真实通道：调用百炼 OpenAI 兼容对话补全，取回模型输出的 JSON 文本。
     *
     * @param scopeJson    scope JSON（作为 user 消息内容）
     * @param systemPrompt 严格 Scope 提示词（作为 system 消息内容）
     * @return {@link String} 模型输出中提取出的 JSON 对象文本（已去代码块包裹）
     * @throws IllegalStateException 未配置 Key / 上游异常 / 响应结构非法
     */
    private String generateByModel(String scopeJson, String systemPrompt) {
        requireApiKey();
        List<String> imageUrls = extractImageUrls(scopeJson);
        String payload;
        try {
            payload = imageUrls.isEmpty()
                    ? buildChatPayload(scopeJson, systemPrompt, model)
                    : buildMultimodalPayload(scopeJson, systemPrompt, imageUrls);
        } catch (Exception e) {
            logUpstreamFailure("payload-build", e);
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
            logUpstreamFailure("generate", e);
            throw new IllegalStateException("通义千问调用失败", e);
        }
        return extractContent(body);
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
     * @param audioUrl         音频只读短时效 URL
     * @param audioContentType 音频 MIME 类型
     * @return {@link String} 转写文本；dry-run 恒为空串
     * @throws IllegalStateException 未配置 Key / MIME 无 format 映射 / 上游异常 / 响应结构非法
     */
    @Override
    public String transcribe(String audioUrl, String audioContentType) {
        if (dryRun) {
            return "";
        }
        requireApiKey();
        String format = audioFormatOf(audioContentType);
        String payload;
        try {
            payload = buildTranscribePayload(audioUrl, format);
        } catch (Exception e) {
            logUpstreamFailure("transcribe-payload-build", e);
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
            logUpstreamFailure("transcribe", e);
            throw new IllegalStateException("通义千问转写调用失败", e);
        }
        return extractPlainText(body);
    }

    /**
     * 【临时诊断 · 定位后移除】记录上游调用失败的异常类名与上游错误响应体。
     *
     * <p>为什么需要：上游非 2xx 被统一映射为 50301（{@code BizException}），而本类按安全
     * 红线不写业务日志，导致「为什么失败」不可观测。本方法只输出异常类名 / HTTP 状态码 /
     * 上游错误响应体（截断 400 字符）——<b>不含 scope 与模型输出</b>，故不违反「日志禁
     * 出现用户输入明文」红线。</p>
     *
     * @param stage 失败阶段标识（payload-build / generate / transcribe）
     * @param e     捕获到的异常
     */
    private void logUpstreamFailure(String stage, Exception e) {
        if (e instanceof RestClientResponseException rre) {
            String respBody = rre.getResponseBodyAsString();
            String truncated = respBody != null && respBody.length() > 400
                    ? respBody.substring(0, 400) : respBody;
            log.warn("[AI-DIAG] stage={} status={} body={}", stage, rre.getStatusCode().value(), truncated);
        } else {
            log.warn("[AI-DIAG] stage={} class={} msg={}", stage, e.getClass().getName(), e.getMessage());
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
        root.put("enable_thinking", OMNI_ENABLE_THINKING);
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
        root.put("enable_thinking", OMNI_ENABLE_THINKING);
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
     * 从对话补全响应取纯文本（转写用；不做 JSON 对象抽取）。
     *
     * @param body 响应体文本（可空）
     * @return {@link String} choices[0].message.content 原文（去首尾空白）
     * @throws IllegalStateException 响应非 JSON / 缺 content
     */
    private String extractPlainText(String body) {
        JsonNode root;
        try {
            root = objectMapper.readTree(body == null ? "" : body);
        } catch (Exception e) {
            throw new IllegalStateException("通义千问响应不是 JSON", e);
        }
        JsonNode content = root.path("choices").path(0).path("message").path("content");
        if (content.isMissingNode() || content.asText("").isBlank()) {
            throw new IllegalStateException("通义千问响应缺少 choices[0].message.content");
        }
        return content.asText("").strip();
    }

    /**
     * 从对话补全响应中取出 {@code choices[0].message.content} 并剥离代码块包裹。
     *
     * @param body 响应体文本（可空）
     * @return {@link String} 提取出的 JSON 对象文本
     * @throws IllegalStateException 响应非 JSON / 缺 content / content 内无 JSON 对象
     */
    private String extractContent(String body) {
        JsonNode root;
        try {
            root = objectMapper.readTree(body == null ? "" : body);
        } catch (Exception e) {
            throw new IllegalStateException("通义千问响应不是 JSON", e);
        }
        JsonNode content = root.path("choices").path(0).path("message").path("content");
        if (content.isMissingNode() || content.asText("").isBlank()) {
            throw new IllegalStateException("通义千问响应缺少 choices[0].message.content");
        }
        return extractJsonObject(content.asText(""));
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
