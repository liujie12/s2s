package com.s2s.server.auth;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.s2s.server.common.config.SecretsProperties;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.io.IOException;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

/**
 * 微信开放平台 code → openid 交换组件（B2-6a）。
 *
 * <p>职责：客户端经微信 SDK 拉起授权后拿到一次性 {@code code}（最长 64 字符），
 * 本组件向微信服务器发起 HTTPS GET 换回 {@code openid}（身份归一化键）+
 * {@code access_token}（后续可选：拉微信昵称/头像）。</p>
 *
 * <p>接口口径（微信开放平台 2026-10-15 核实）：
 * <pre>
 *   GET https://api.weixin.qq.com/sns/oauth2/access_token
 *       ?appid={APPID}&amp;secret={SECRET}&amp;code={CODE}&amp;grant_type=authorization_code
 *   成功：{ openid, access_token, expires_in, refresh_token, scope, unionid? }
 *   失败：{ errcode, errmsg }
 * </pre></p>
 *
 * <p><b>凭据未到位时的行为</b>（资质审批中，AppID/AppSecret 未注入）：
 * {@link SecretsProperties#wechatAppId()} 或 {@link SecretsProperties#wechatAppSecret()}
 * 为 null 时直接抛 {@link BizException}（40001 + 明确错误信息「微信开放平台凭据未配置」），
 * 不发 HTTP 请求——消费方据此判定「未配置」并决定是否回 dry-run/mock 模式。</p>
 *
 * <p><b>HTTP 客户端选型</b>：用 JDK 11 {@link java.net.http.HttpClient}（Spring Boot 3 + JDK 21，
 * 原生支持，无需额外依赖 RestTemplate/WebClient）。超时 10 秒，失败/非 200 → 50301。</p>
 */
@Component
public class WechatCodeVerifier {

    /** 微信 code 换 openid 接口 URL 模板（四个参数 appid/secret/code/grant_type）。 */
    private static final String WECHAT_ACCESS_TOKEN_URL =
            "https://api.weixin.qq.com/sns/oauth2/access_token"
                    + "?appid=%s&secret=%s&code=%s&grant_type=authorization_code";

    /** HTTP 请求超时上限（秒）：微信 API 官方无硬性 SLA，但 10 秒是合理上限。 */
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(10);

    /** 微信 API 业务错误码 key（JSON 字段名）。 */
    private static final String FIELD_ERRCODE = "errcode";

    /** 微信 API 业务错误消息 key（JSON 字段名）。 */
    private static final String FIELD_ERRMSG = "errmsg";

    /** 微信 API 成功返回的 openid 字段名。 */
    private static final String FIELD_OPENID = "openid";

    /** 微信 API 成功返回的 access_token 字段名。 */
    private static final String FIELD_ACCESS_TOKEN = "access_token";

    /** 微信 API 成功返回的 expires_in 字段名。 */
    private static final String FIELD_EXPIRES_IN = "expires_in";

    private static final Logger log = LoggerFactory.getLogger(WechatCodeVerifier.class);

    /** 全量凭证配置载体（读取 wechatAppId / wechatAppSecret）。 */
    private final SecretsProperties secrets;

    /** Jackson 反序列化器。 */
    private final ObjectMapper objectMapper;

    /** JDK 11 HttpClient（单例，线程安全）。 */
    private final HttpClient httpClient;

    /**
     * 构造微信 code 验证器：注入凭证配置与 Jackson，构建带超时的 HttpClient。
     *
     * @param secrets      全量凭证配置（wechatAppId / wechatAppSecret 为可选绑定，
     *                     未注入时为 null，调用方须显式判空）
     * @param objectMapper Jackson 反序列化器（与全仓单例复用）
     */
    public WechatCodeVerifier(SecretsProperties secrets, ObjectMapper objectMapper) {
        this.secrets = secrets;
        this.objectMapper = objectMapper;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(REQUEST_TIMEOUT)
                .build();
    }

    /**
     * 用客户端传来的 code 向微信服务器交换 openid + access_token。
     *
     * @param code 微信授权 code（一次性，最长 64 字符，来自客户端微信 SDK）
     * @return {@link WechatTokenResult} 含 openid（必填，身份归一化键）+ accessToken + expiresIn
     * @throws BizException 凭据未配置 → 40001；code 无效/过期 → 40001（微信 errcode 原样透出）；
     *                     HTTP/网络失败 → 50301
     */
    public WechatTokenResult verify(String code) {
        String appId = secrets.wechatAppId();
        String appSecret = secrets.wechatAppSecret();

        if (appId == null || appSecret == null) {
            log.warn("微信开放平台凭据未配置（AppID/AppSecret 未注入），拒绝 code→openid 交换——请检查环境变量 WECHAT_APP_ID / WECHAT_APP_SECRET");
            throw BizException.of(ErrorCode.INTERNAL_ERROR);
        }

        String url = String.format(WECHAT_ACCESS_TOKEN_URL,
                urlEncode(appId), urlEncode(appSecret), urlEncode(code));

        HttpRequest request = HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(REQUEST_TIMEOUT)
                .GET()
                .build();

        HttpResponse<String> response;
        try {
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (IOException | InterruptedException exception) {
            log.warn("微信 code→openid 交换 HTTP 失败：{}", exception.getMessage());
            throw BizException.of(ErrorCode.CERT_UNAVAILABLE);
        }

        if (response.statusCode() != 200) {
            log.warn("微信 code→openid 交换 HTTP 非 200：status={}, body={}",
                    response.statusCode(), response.body());
            throw BizException.of(ErrorCode.CERT_UNAVAILABLE);
        }

        JsonNode root;
        try {
            root = objectMapper.readTree(response.body());
        } catch (IOException exception) {
            log.warn("微信返回体反序列化失败：body={}", response.body());
            throw BizException.of(ErrorCode.CERT_UNAVAILABLE);
        }

        // 微信 API 业务错误（code 无效/过期/重复使用等）
        if (root.has(FIELD_ERRCODE)) {
            int errcode = root.get(FIELD_ERRCODE).asInt();
            String errmsg = root.path(FIELD_ERRMSG).asText("unknown");
            log.info("微信 code 换 openid 业务错误：errcode={}, errmsg={}", errcode, errmsg);
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        String openid = root.path(FIELD_OPENID).asText();
        String accessToken = root.path(FIELD_ACCESS_TOKEN).asText();
        int expiresIn = root.path(FIELD_EXPIRES_IN).asInt();
        if (openid.isBlank()) {
            log.warn("微信返回体缺 openid：body={}", response.body());
            throw BizException.of(ErrorCode.CERT_UNAVAILABLE);
        }
        return new WechatTokenResult(openid, accessToken, expiresIn);
    }

    /**
     * URL 编码：微信官方接口要求四个参数（appid/secret/code/grant_type）做 URL encode。
     * 使用 UTF-8，与微信文档口径一致。
     *
     * @param value 待编码字符串
     * @return URL 编码后的字符串
     */
    private static String urlEncode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    /**
     * 微信 code→openid 交换成功结果（值对象）。
     *
     * <p>{@code openid}：微信给每个应用下每个用户的唯一标识（长度约 28 字符），
     * 本项目以此为 {@code user_identity.identity_value_enc} 的明文源，盲索引与手机号同范式。</p>
     *
     * <p>{@code accessToken}：2 小时有效期，后续可选用于拉微信昵称/头像（scope=snsapi_userinfo）；
     * 当前 B2-6a 仅做登录，拉资料作为 Batch2 后置项，accessToken 暂时落库留痕即可。</p>
     *
     * <p>{@code expiresIn}：accessToken 有效期（秒），供客户端展示/续期提示。</p>
     *
     * @param openid      微信用户在本应用下的唯一标识（必填，身份归一化键）
     * @param accessToken 微信接口调用凭证（可选，用于后续拉资料）
     * @param expiresIn   accessToken 有效期（秒）
     */
    public record WechatTokenResult(String openid, String accessToken, int expiresIn) {
    }
}
