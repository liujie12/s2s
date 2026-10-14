package com.s2s.server.ai;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Iterator;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

/**
 * 通义千问（阿里云百炼）实现的 dry-run 桩（B2-4 阶段①）。
 *
 * <p>职责：在真实大模型 API 联调前，用「{@code s2s.ai.dry-run} 开关 + 纯规则的 Scope 内
 * 抽取」跑通 AI 发布全链（解析 → 确认页 → 发布）。真服务联调时把
 * {@code s2s.ai.dry-run} 置 {@code false} 并实现真实 HTTP 调用，业务代码
 * （{@link AiParseService}）不动。</p>
 *
 * <p><b>dry-run 不是 AI，也不假装是</b>：它只做「从 scope 里按可验证规则搬运」——
 * 标题 = 用户文本；分类 = 请求已给的叶子类目；价格 = 文本中出现的数字；模板字段 =
 * 文本中出现的模板选项。<b>绝不编造</b>，与 PRD §5.10 的产物约束一致；这也使 dry-run
 * 的输出天然能通过 Step 4 逆向比对。</p>
 *
 * <p><b>真实接入点</b>：走通义千问 OpenAI 兼容 HTTP 接口，key 走环境变量
 * {@code s2s.ai.api-key}（{@code SecretsProperties} 同族），模型名与端点走
 * {@code s2s.ai.*}。见类内 {@code #DRY_RUN_TODO} 注释。</p>
 *
 * <p><b>安全</b>：本类不写任何日志（scope 含用户输入明文，编码规范 §4.11）。</p>
 */
@Component
public class QwenAiProvider implements AiProvider {

    /** 真实现接入点（TODO 列表，联调时逐条落地）。 */
    private static final String DRY_RUN_TODO =
            "TODO(B2-4 联调)：实现通义千问 OpenAI 兼容 HTTP 调用——"
                    + "① 读 s2s.ai.api-key（环境变量）/s2s.ai.model/s2s.ai.endpoint；"
                    + "② 图片与音频经 OSS 签名 URL 以 qwen-omni 多模态入参；"
                    + "③ 超时按 NfrAi.UPSTREAM_TIMEOUT_SECONDS；④ 失败抛 IllegalStateException。";

    /** 数字抽取正则（价格猜测用；简单取首个数字，不做单位推断）。 */
    private static final Pattern NUMBER_PATTERN = Pattern.compile("\\d+(?:\\.\\d+)?");

    /** 标题截断上限（对齐契约 maxLength 40）。 */
    private static final int TITLE_MAX_LENGTH = 40;

    /** 是否走 dry-run mock（默认 true）。真服务联调前置 false 并实现真实 API 分支。 */
    private final boolean dryRun;

    /** JSON 解析器（scopeJson 读取与结果 JSON 构造）。 */
    private final ObjectMapper objectMapper;

    /**
     * 构造通义千问 dry-run 桩。
     *
     * @param dryRun       是否走 dry-run mock（配置 {@code s2s.ai.dry-run}，默认 true）
     * @param objectMapper JSON 解析器
     */
    public QwenAiProvider(@Value("${s2s.ai.dry-run:true}") boolean dryRun,
            ObjectMapper objectMapper) {
        this.dryRun = dryRun;
        this.objectMapper = objectMapper;
    }

    /**
     * 生成四件套（dry-run 为 Scope 内规则抽取）。
     *
     * @param scopeJson     Step 2 产出的 scope JSON（含 text / leaf_category_id / template_fields）
     * @param systemPrompt  系统提示词（dry-run 不使用，仅为真实实现保留）
     * @return {@link String} 与 {@code AiGuess} 同构的 JSON 文本
     * @throws IllegalStateException 非 dry-run 且真实 API 未接入时抛出（调用方映射 50301）
     */
    @Override
    public String generate(String scopeJson, String systemPrompt) {
        if (!dryRun) {
            throw new IllegalStateException(
                    "s2s.ai.dry-run=false，但真实通义千问 API 尚未接入（B2-4 阶段①）。" + DRY_RUN_TODO);
        }
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
