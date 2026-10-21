package com.s2s.server.notify;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.s2s.server.auth.PushPlatform;
import com.s2s.server.common.constants.NfrPush;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.util.LinkedMultiValueMap;
import org.springframework.util.MultiValueMap;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientException;

/**
 * 小米推送发送器（B2-2 阶段 2；官方服务端 API v3）。
 *
 * <p><b>接口口径（官方文档）</b>：
 * <ul>
 *   <li>端点：{@code POST https://api.xmpush.xiaomi.com/v3/message/regid}（单设备 regid）；</li>
 *   <li>鉴权：头 {@code Authorization: key=<AppSecret>}（{@code key} 必须小写）；</li>
 *   <li>表单：{@code registration_id} / {@code restricted_package_name} / {@code title} /
 *       {@code description} / {@code payload} / {@code notify_type} / {@code pass_through}
 *       及 {@code extra.*}（小米按表单参数接收，非 JSON）；</li>
 *   <li>成功判据：HTTP 2xx 且响应 {@code code=0}。</li>
 * </ul>
 *
 * <p><b>2026 消息分类新规</b>：私信消息必须携带 {@code extra.channel_id} 与
 * {@code extra.template_id}（模板由小米运营平台申请，2026-12-31 前完成接入）。本类把
 * 两者做成可选配置：未配置时按普通通道下发（用于联调与公信类通知），配置后自动附带；
 * 模板变量内容由 {@code s2s.push.xiaomi.template-param} 原样传入（无变量模板传 {@code {}}）。
 * 消息归类属产品口径，不在本类自行推断。</p>
 *
 * <p><b>安全</b>：日志不输出 AppSecret、设备 regid 与通知正文，仅记通道、类型与厂商 code。</p>
 */
@Component
@ConditionalOnProperty(prefix = "s2s.push.xiaomi", name = "enabled", havingValue = "true")
public class XiaomiPushSender implements PushSender {

    /** 日志。 */
    private static final Logger log = LoggerFactory.getLogger(XiaomiPushSender.class);

    /** 单设备下发端点（官方 v3）。 */
    static final String SEND_URL = "https://api.xmpush.xiaomi.com/v3/message/regid";

    /** 成功业务码（官方口径：code=0）。 */
    static final int SUCCESS_CODE = 0;

    /** 透传标志：0 = 通知栏消息（官方口径）。 */
    private static final int PASS_THROUGH_NOTIFICATION = 0;

    /** 通知类型：1 = 默认提示音（官方 DEFAULT_SOUND）。 */
    private static final int NOTIFY_TYPE_SOUND = 1;

    /** 点击行为：1 = 打开 App Launcher Activity（官方口径）。 */
    private static final String NOTIFY_EFFECT_OPEN_APP = "1";

    /** 无变量模板参数（官方口径：无变量模板请传 {@code {}}）。 */
    private static final String EMPTY_TEMPLATE_PARAM = "{}";

    /** HTTP 客户端（{@code PushClientConfig#pushRestClient}）。 */
    private final RestClient restClient;

    /** JSON 序列化（payload 与模板参数校验）。 */
    private final ObjectMapper objectMapper;

    /** 小米 AppSecret（仅服务端持有）。 */
    private final String appSecret;

    /** 应用包名（须与小米后台登记一致）。 */
    private final String packageName;

    /** 私信 channel ID（可空；未配置则不附带）。 */
    private final String channelId;

    /** 私信模板 ID（可空；未配置则不附带）。 */
    private final String templateId;

    /** 模板变量 JSON（可空；仅 templateId 非空时消费）。 */
    private final String templateParam;

    /**
     * 构造小米发送器。
     *
     * @param restClient 通用推送 HTTP 客户端
     * @param objectMapper JSON 序列化器
     * @param appSecret 小米 AppSecret（{@code s2s.push.xiaomi.app-secret}）
     * @param packageName 应用包名（{@code s2s.push.xiaomi.package-name}）
     * @param channelId 私信 channel ID（{@code s2s.push.xiaomi.channel-id}，可空）
     * @param templateId 私信模板 ID（{@code s2s.push.xiaomi.template-id}，可空）
     * @param templateParam 模板变量 JSON（{@code s2s.push.xiaomi.template-param}，可空）
     * @throws IllegalStateException 启用但 AppSecret / 包名为空
     */
    public XiaomiPushSender(@Qualifier("pushRestClient") RestClient restClient,
            ObjectMapper objectMapper,
            @Value("${s2s.push.xiaomi.app-secret:}") String appSecret,
            @Value("${s2s.push.xiaomi.package-name:}") String packageName,
            @Value("${s2s.push.xiaomi.channel-id:}") String channelId,
            @Value("${s2s.push.xiaomi.template-id:}") String templateId,
            @Value("${s2s.push.xiaomi.template-param:}") String templateParam) {
        if (isBlank(appSecret) || isBlank(packageName)) {
            throw new IllegalStateException(
                    "s2s.push.xiaomi.enabled=true 但 XIAOMI_PUSH_APP_SECRET / XIAOMI_PUSH_PACKAGE_NAME 未注入");
        }
        this.restClient = restClient;
        this.objectMapper = objectMapper;
        this.appSecret = appSecret;
        this.packageName = packageName;
        this.channelId = channelId;
        this.templateId = templateId;
        this.templateParam = templateParam;
    }

    /**
     * 本发送器负责的推送通道。
     *
     * @return {@link PushPlatform#MI}
     */
    @Override
    public PushPlatform platform() {
        return PushPlatform.MI;
    }

    /**
     * 向单台小米设备下发一条通知栏消息。
     *
     * <p>网络异常、非 2xx、厂商业务码非 0 均返回 {@code false}，不抛异常中断同批其他设备。</p>
     *
     * @param token 目标设备 regid（非 null）
     * @param message 推送载荷
     * @return boolean {@code true} 厂商受理（code=0）
     */
    @Override
    public boolean send(String token, PushMessage message) {
        MultiValueMap<String, String> form = buildForm(token, message);
        try {
            String response = restClient.post()
                    .uri(SEND_URL)
                    .header(HttpHeaders.AUTHORIZATION, "key=" + appSecret)
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .retrieve()
                    .body(String.class);
            return isSuccess(response);
        } catch (RestClientException e) {
            log.warn("小米推送下发失败（网络/非 2xx）type={} err={}",
                    message.type().wire(), e.getClass().getSimpleName());
            return false;
        }
    }

    /**
     * 构造官方表单参数。
     *
     * @param token 目标设备 regid
     * @param message 推送载荷
     * @return {@link MultiValueMap} 表单参数（编码由 RestClient 负责）
     */
    private MultiValueMap<String, String> buildForm(String token, PushMessage message) {
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("registration_id", token);
        form.add("restricted_package_name", packageName);
        form.add("title", truncate(message.title(), NfrPush.XIAOMI_TITLE_MAX_CHARS));
        form.add("description",
                truncate(nullableToEmpty(message.summary()), NfrPush.XIAOMI_DESCRIPTION_MAX_CHARS));
        form.add("payload", dataPayload(message));
        form.add("notify_type", String.valueOf(NOTIFY_TYPE_SOUND));
        form.add("pass_through", String.valueOf(PASS_THROUGH_NOTIFICATION));
        form.add("extra.notify_effect", NOTIFY_EFFECT_OPEN_APP);
        if (!isBlank(channelId) && !isBlank(templateId)) {
            form.add("extra.channel_id", channelId);
            form.add("extra.template_id", templateId);
            form.add("extra.template_param", templateParamOrDefault());
        }
        return form;
    }

    /**
     * 构造客户端跳转载荷（与站内通知同源字段）。
     *
     * @param message 推送载荷
     * @return {@link String} JSON 字符串
     */
    private String dataPayload(PushMessage message) {
        ObjectNode data = objectMapper.createObjectNode();
        data.put("type", message.type().wire());
        if (message.targetId() != null) {
            data.put("targetId", message.targetId());
        }
        return data.toString();
    }

    /**
     * 取模板变量 JSON：未配置时返回空对象（官方允许无变量模板传 {@code {}}）。
     *
     * @return {@link String} 模板变量 JSON
     */
    private String templateParamOrDefault() {
        return isBlank(templateParam) ? EMPTY_TEMPLATE_PARAM : templateParam;
    }

    /**
     * 判定厂商业务码是否为成功。
     *
     * @param response 响应体（可能为 null）
     * @return boolean {@code true} code=0
     */
    private boolean isSuccess(String response) {
        if (response == null) {
            return false;
        }
        try {
            JsonNode root = objectMapper.readTree(response);
            int code = root.path("code").asInt(-1);
            if (code == SUCCESS_CODE) {
                return true;
            }
            log.warn("小米推送未受理 code={} description={}", code,
                    root.path("description").asText(""));
            return false;
        } catch (Exception e) {
            log.warn("小米推送响应解析失败 err={}", e.getClass().getSimpleName());
            return false;
        }
    }

    /**
     * 按字符数截断（中英文均按 1 计，与小米官方口径一致），避免超长被厂商拒收。
     *
     * @param value 原值
     * @param maxChars 最大字符数
     * @return {@link String} 截断后的字符串
     */
    private static String truncate(String value, int maxChars) {
        if (value == null) {
            return "";
        }
        int codePoints = value.codePointCount(0, value.length());
        if (codePoints <= maxChars) {
            return value;
        }
        int end = value.offsetByCodePoints(0, maxChars);
        return value.substring(0, end);
    }

    /**
     * 空值归一为空串。
     *
     * @param value 原值
     * @return {@link String} 非 null 字符串
     */
    private static String nullableToEmpty(String value) {
        return value == null ? "" : value;
    }

    /**
     * 判断字符串是否为空白。
     *
     * @param value 待判值
     * @return boolean {@code true} null 或全空白
     */
    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
