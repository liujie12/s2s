package com.s2s.server.notify;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.s2s.server.auth.PushPlatform;
import java.time.Instant;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
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
 * 华为推送发送器（B2-2 阶段 2；官方 REST API v1 + OAuth 2.0 客户端模式）。
 *
 * <p><b>接口口径（官方文档）</b>：
 * <ul>
 *   <li>取 Token：{@code POST https://oauth-login.cloud.huawei.com/oauth2/v3/token}，
 *       表单 {@code grant_type=client_credentials&client_id=<AppID>&client_secret=<AppSecret>}；</li>
 *   <li>发消息：{@code POST https://push-api.cloud.huawei.com/v1/<AppID>/messages:send}，
 *       头 {@code Authorization: Bearer <access_token>}，体为
 *       {@code {"validate_only":false,"message":{...}}}；</li>
 *   <li>成功判据：HTTP 2xx 且业务码 {@code code="80000000"}。</li>
 * </ul>
 * 华为同时提供 v2/v3（projectId + JWT）接口，本项目按「AppID + AppSecret」凭据形态选 v1；
 * 若后续 AGC 侧切换服务账号鉴权，只需替换本类，不改路由与编排。</p>
 *
 * <p><b>未配置即不注册</b>：{@code s2s.push.huawei.enabled=false} 时本 Bean 不存在，
 * {@link PushSenderRegistry} 路由表保持为空，下发走站内兜底 —— 与「不提供假发送器」的
 * 既有取向一致。若显式启用但 AppID/AppSecret 为空，构造期直接失败（不给静默降级留口子）。</p>
 *
 * <p><b>安全</b>：日志不输出 token、AppSecret、设备 token 与通知正文；仅记通道、通知类型
 * 与厂商业务码。</p>
 */
@Component
@ConditionalOnProperty(prefix = "s2s.push.huawei", name = "enabled", havingValue = "true")
public class HuaweiPushSender implements PushSender {

    /** 日志。 */
    private static final Logger log = LoggerFactory.getLogger(HuaweiPushSender.class);

    /** OAuth 2.0 取 Token 端点（官方口径）。 */
    static final String OAUTH_TOKEN_URL = "https://oauth-login.cloud.huawei.com/oauth2/v3/token";

    /** 发消息端点模板（官方 v1，路径参数 = AppID）。 */
    static final String SEND_URL_TEMPLATE = "https://push-api.cloud.huawei.com/v1/%s/messages:send";

    /** 华为成功业务码（官方口径）。 */
    static final String SUCCESS_CODE = "80000000";

    /** Token 提前刷新余量（秒）：避免边界上拿到即将过期的 Token。 */
    private static final long TOKEN_REFRESH_MARGIN_SECONDS = 300;

    /** 点击行为：打开 App 首页（官方 click_action.type=1）。 */
    private static final int CLICK_ACTION_OPEN_APP = 1;

    /** 离线消息合并策略：同一应用待上线消息只下发最新一条（官方 collapse_key=0 语义）。 */
    private static final int COLLAPSE_KEY_DEFAULT = 0;

    /** HTTP 客户端（{@code PushClientConfig#pushRestClient}）。 */
    private final RestClient restClient;

    /** JSON 序列化（构造 data 载荷）。 */
    private final ObjectMapper objectMapper;

    /** 华为 AppID（AGC 应用信息）。 */
    private final String appId;

    /** 华为 AppSecret（仅服务端持有）。 */
    private final String appSecret;

    /** 缓存的 access_token（{@code null} 表示尚未获取）。 */
    private String accessToken;

    /** access_token 过期时刻（epoch 秒）。 */
    private long accessTokenExpiresAt;

    /**
     * 构造华为发送器。
     *
     * @param restClient 通用推送 HTTP 客户端
     * @param objectMapper JSON 序列化器
     * @param appId 华为 AppID（{@code s2s.push.huawei.app-id}）
     * @param appSecret 华为 AppSecret（{@code s2s.push.huawei.app-secret}）
     * @throws IllegalStateException 启用但凭据为空
     */
    public HuaweiPushSender(RestClient restClient, ObjectMapper objectMapper,
            @Value("${s2s.push.huawei.app-id:}") String appId,
            @Value("${s2s.push.huawei.app-secret:}") String appSecret) {
        if (isBlank(appId) || isBlank(appSecret)) {
            throw new IllegalStateException(
                    "s2s.push.huawei.enabled=true 但 HUAWEI_PUSH_APP_ID / HUAWEI_PUSH_APP_SECRET 未注入");
        }
        this.restClient = restClient;
        this.objectMapper = objectMapper;
        this.appId = appId;
        this.appSecret = appSecret;
    }

    /**
     * 本发送器负责的推送通道。
     *
     * @return {@link PushPlatform#HW}
     */
    @Override
    public PushPlatform platform() {
        return PushPlatform.HW;
    }

    /**
     * 向单台华为设备下发一条通知栏消息。
     *
     * <p>Token 失效、厂商限频、网络异常均返回 {@code false} 而不抛异常，避免中断同批
     * 其他设备的下发（接口契约见 {@link PushSender#send}）。</p>
     *
     * @param token 目标设备 Push Token（非 null）
     * @param message 推送载荷
     * @return boolean {@code true} 厂商受理（业务码 80000000）
     */
    @Override
    public boolean send(String token, PushMessage message) {
        String bearer = accessToken();
        if (bearer == null) {
            return false;
        }
        String body = buildRequestBody(token, message);
        try {
            String response = restClient.post()
                    .uri(String.format(SEND_URL_TEMPLATE, appId))
                    .header(HttpHeaders.AUTHORIZATION, "Bearer " + bearer)
                    .contentType(MediaType.APPLICATION_JSON)
                    .body(body)
                    .retrieve()
                    .body(String.class);
            return isSuccess(response);
        } catch (RestClientException e) {
            log.warn("华为推送下发失败（网络/非 2xx）type={} err={}",
                    message.type().wire(), e.getClass().getSimpleName());
            return false;
        }
    }

    /**
     * 取可用的 access_token（带缓存与提前刷新）。
     *
     * <p>同步块内做「双检 + 刷新」，避免并发下发时同时打 OAuth 接口。刷新失败返回
     * {@code null}，由调用方按「未受理」处理。</p>
     *
     * @return {@link String} 可用 Token；获取失败返回 {@code null}
     */
    private synchronized String accessToken() {
        long now = Instant.now().getEpochSecond();
        if (accessToken != null && now < accessTokenExpiresAt) {
            return accessToken;
        }
        MultiValueMap<String, String> form = new LinkedMultiValueMap<>();
        form.add("grant_type", "client_credentials");
        form.add("client_id", appId);
        form.add("client_secret", appSecret);
        try {
            String response = restClient.post()
                    .uri(OAUTH_TOKEN_URL)
                    .contentType(MediaType.APPLICATION_FORM_URLENCODED)
                    .body(form)
                    .retrieve()
                    .body(String.class);
            JsonNode root = response == null ? null : objectMapper.readTree(response);
            String token = root == null ? null : root.path("access_token").asText(null);
            long expiresIn = root == null ? 0 : root.path("expires_in").asLong(0);
            if (isBlank(token) || expiresIn <= TOKEN_REFRESH_MARGIN_SECONDS) {
                log.warn("华为推送 OAuth 响应缺少有效 access_token/expires_in");
                return null;
            }
            accessToken = token;
            accessTokenExpiresAt = now + expiresIn - TOKEN_REFRESH_MARGIN_SECONDS;
            return accessToken;
        } catch (RestClientException e) {
            log.warn("华为推送 OAuth 获取 Token 失败（网络/非 2xx）err={}",
                    e.getClass().getSimpleName());
            return null;
        } catch (Exception e) {
            log.warn("华为推送 OAuth 响应解析失败 err={}", e.getClass().getSimpleName());
            return null;
        }
    }

    /**
     * 构造官方 v1 请求体。
     *
     * <p>{@code data} 是字符串（官方口径），承载与站内通知同源的 {@code type/targetId}，
     * 供客户端点击后跳同一落点；{@code click_action.type=1} 表示打开 App 首页。</p>
     *
     * @param token 目标设备 Token
     * @param message 推送载荷
     * @return {@link String} 请求体 JSON
     */
    private String buildRequestBody(String token, PushMessage message) {
        ObjectNode root = objectMapper.createObjectNode();
        root.put("validate_only", false);
        ObjectNode msg = root.putObject("message");
        msg.putArray("token").add(token);
        ObjectNode notification = msg.putObject("notification");
        notification.put("title", message.title());
        notification.put("body", nullableToEmpty(message.summary()));
        msg.put("data", dataPayload(message));
        ObjectNode android = msg.putObject("android");
        android.put("collapse_key", COLLAPSE_KEY_DEFAULT);
        ObjectNode androidNotification = android.putObject("notification");
        androidNotification.putObject("click_action").put("type", CLICK_ACTION_OPEN_APP);
        return root.toString();
    }

    /**
     * 构造客户端跳转载荷（与站内通知同源字段）。
     *
     * @param message 推送载荷
     * @return {@link String} JSON 字符串，如 {@code {"type":"interaction","targetId":123}}
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
     * 判定厂商业务码是否为成功。
     *
     * @param response 响应体（可能为 null）
     * @return boolean {@code true} 业务码 = 80000000
     */
    private boolean isSuccess(String response) {
        if (response == null) {
            return false;
        }
        try {
            JsonNode root = objectMapper.readTree(response);
            String code = root.path("code").asText("");
            if (SUCCESS_CODE.equals(code)) {
                return true;
            }
            log.warn("华为推送未受理 code={} msg={}", code, root.path("msg").asText(""));
            return false;
        } catch (Exception e) {
            log.warn("华为推送响应解析失败 err={}", e.getClass().getSimpleName());
            return false;
        }
    }

    /**
     * 空值归一为空串（华为 body 不接受 null）。
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
