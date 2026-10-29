package com.s2s.server.cert;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Duration;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.Map;
import java.util.TreeMap;
import java.util.UUID;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * 阿里云「信息核验 - 身份二要素核验」（{@code Id2MetaVerify}）OpenAPI 客户端。
 *
 * <p>为什么手写签名而不引 SDK：生产构建跑在 CentOS7 + Maven 3.0.5 的离线环境，
 * 新增 SDK 依赖需要连带拉取一整串 aliyun-java-sdk 传递依赖，发版风险远大于收益；
 * 该接口只用到一个 POST + ACS3-HMAC-SHA256 签名，JDK 自带 {@link HttpClient} 即可。</p>
 *
 * <p><b>安全红线</b>：本类不写任何日志——入参是姓名与身份证号明文（编码规范 §4.11）。</p>
 *
 * <p>接口口径（2026-10-29 官方文档）：Endpoint 通用 {@code cloudauth.aliyuncs.com}，
 * Action {@code Id2MetaVerify}，Version {@code 2019-03-07}；请求参数
 * {@code ParamType=normal}、{@code UserName}、{@code IdentifyNum}；响应
 * {@code Code=200} 表示接口调用成功，业务结论看 {@code ResultObject.BizCode}：
 * {@code 1} 一致、{@code 2} 不一致。</p>
 */
public class CloudAuthId2MetaClient {

    /** 接口动作名（固定值，参与签名头 x-acs-action）。 */
    private static final String ACTION = "Id2MetaVerify";

    /** 接口版本（固定值，参与签名头 x-acs-version）。 */
    private static final String VERSION = "2019-03-07";

    /** 签名算法标识（ACS3）。 */
    private static final String ALGORITHM = "ACS3-HMAC-SHA256";

    /** 连接超时（秒）：核验属用户提交路径，宁可快速失败映射 50302 也不长时间挂起。 */
    private static final int CONNECT_TIMEOUT_SECONDS = 3;

    /** 读超时（秒）：上游正常在 1 秒内返回，超过 5 秒视为不可用。 */
    private static final int READ_TIMEOUT_SECONDS = 5;

    /** UTC 时间格式（x-acs-date 要求 ISO8601 秒级，无毫秒）。 */
    private static final DateTimeFormatter ACS_DATE_FORMAT =
            DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss'Z'").withZone(ZoneOffset.UTC);

    /** 业务结论：一致。 */
    private static final String BIZ_CODE_MATCH = "1";

    /** 业务结论：不一致。 */
    private static final String BIZ_CODE_MISMATCH = "2";

    /** JSON 序列化/解析（仅本类使用，无状态可复用）。 */
    private static final ObjectMapper MAPPER = new ObjectMapper();

    /** 服务地址，形如 {@code https://cloudauth.cn-beijing.aliyuncs.com}（不含尾斜杠也可）。 */
    private final String endpoint;

    /** RAM 用户 AccessKeyId（只读）。 */
    private final String accessKeyId;

    /** RAM 用户 AccessKeySecret（只读，任何情况下不外泄）。 */
    private final String accessKeySecret;

    /** HTTP 客户端（JDK 自带，连接池由 JDK 维护）。 */
    private final HttpClient httpClient;

    /**
     * 构造客户端。
     *
     * @param endpoint        服务地址（如 {@code https://cloudauth.cn-beijing.aliyuncs.com}）
     * @param accessKeyId     RAM 用户 AccessKeyId
     * @param accessKeySecret RAM 用户 AccessKeySecret
     */
    public CloudAuthId2MetaClient(String endpoint, String accessKeyId, String accessKeySecret) {
        this.endpoint = endpoint.endsWith("/")
                ? endpoint.substring(0, endpoint.length() - 1)
                : endpoint;
        this.accessKeyId = accessKeyId;
        this.accessKeySecret = accessKeySecret;
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(CONNECT_TIMEOUT_SECONDS))
                .build();
    }

    /**
     * 核验姓名与身份证号是否一致。
     *
     * @param realName 姓名明文
     * @param idCard   18 位身份证号明文
     * @return {@code true} 一致；{@code false} 不一致
     * @throws IllegalStateException 上游不可用（网络/非 200/Code 非 200/响应结构非法），
     *                               调用方映射 {@code 50302}
     */
    public boolean verify(String realName, String idCard) {
        final String body;
        try {
            body = MAPPER.writeValueAsString(Map.of(
                    "ParamType", "normal",
                    "UserName", realName,
                    "IdentifyNum", idCard));
        } catch (Exception exception) {
            throw new IllegalStateException("构造信息核验请求体失败", exception);
        }

        final HttpResponse<String> response;
        try {
            response = httpClient.send(buildRequest(body), HttpResponse.BodyHandlers.ofString());
        } catch (InterruptedException exception) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("信息核验调用被中断", exception);
        } catch (Exception exception) {
            throw new IllegalStateException("信息核验调用失败", exception);
        }

        return parseVerdict(response.statusCode(), response.body());
    }

    /**
     * 构造带 ACS3 签名的 HTTPS 请求。
     *
     * @param body 请求体 JSON（已序列化）
     * @return {@link HttpRequest}：POST 到 endpoint 根路径
     */
    private HttpRequest buildRequest(String body) {
        final URI uri = URI.create(endpoint + "/");
        final String hashedPayload = sha256Hex(body.getBytes(StandardCharsets.UTF_8));

        // 参与签名的头：全部小写、按字典序，值取 trim 后的原文
        final Map<String, String> signed = new TreeMap<>();
        signed.put("content-type", "application/json");
        signed.put("host", uri.getHost());
        signed.put("x-acs-action", ACTION);
        signed.put("x-acs-content-sha256", hashedPayload);
        signed.put("x-acs-date", ACS_DATE_FORMAT.format(Instant.now()));
        signed.put("x-acs-signature-nonce", UUID.randomUUID().toString());
        signed.put("x-acs-version", VERSION);

        final StringBuilder canonicalHeaders = new StringBuilder();
        signed.forEach((name, value) -> canonicalHeaders
                .append(name).append(':').append(value.trim()).append('\n'));
        final String signedHeaders = String.join(";", signed.keySet());

        final String canonicalRequest = "POST\n"
                + "/\n"
                + "\n"
                + canonicalHeaders
                + "\n"
                + signedHeaders + "\n"
                + hashedPayload;
        final String stringToSign = ALGORITHM + "\n"
                + sha256Hex(canonicalRequest.getBytes(StandardCharsets.UTF_8));
        final String signature = hmacSha256Hex(accessKeySecret, stringToSign);

        final HttpRequest.Builder builder = HttpRequest.newBuilder(uri)
                .timeout(Duration.ofSeconds(READ_TIMEOUT_SECONDS))
                .header("Authorization", ALGORITHM
                        + " Credential=" + accessKeyId
                        + ",SignedHeaders=" + signedHeaders
                        + ",Signature=" + signature)
                .POST(HttpRequest.BodyPublishers.ofString(body, StandardCharsets.UTF_8));
        signed.forEach(builder::header);

        return builder.build();
    }

    /**
     * 解析响应并给出核验结论。
     *
     * @param statusCode HTTP 状态码
     * @param responseBody 响应体 JSON
     * @return {@code true} 一致；{@code false} 不一致
     * @throws IllegalStateException 非 200 / Code 非 200 / 结构非法
     */
    private boolean parseVerdict(int statusCode, String responseBody) {
        if (statusCode != 200) {
            throw new IllegalStateException("信息核验 HTTP 状态异常: " + statusCode);
        }
        final JsonNode root;
        try {
            root = MAPPER.readTree(responseBody);
        } catch (Exception exception) {
            throw new IllegalStateException("信息核验响应不是 JSON", exception);
        }
        final String code = root.path("Code").asText("");
        if (!"200".equals(code)) {
            throw new IllegalStateException("信息核验接口调用失败，Code=" + code);
        }
        final String bizCode = root.path("ResultObject").path("BizCode").asText("");
        if (BIZ_CODE_MATCH.equals(bizCode)) {
            return true;
        }
        if (BIZ_CODE_MISMATCH.equals(bizCode)) {
            return false;
        }
        throw new IllegalStateException("信息核验响应缺少可判定的 BizCode");
    }

    /**
     * 计算 SHA-256 并转小写十六进制。
     *
     * @param bytes 待摘要字节
     * @return 十六进制串
     */
    private static String sha256Hex(byte[] bytes) {
        try {
            final byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            return toHex(digest);
        } catch (Exception exception) {
            throw new IllegalStateException("SHA-256 计算失败", exception);
        }
    }

    /**
     * 计算 HMAC-SHA256 并转小写十六进制。
     *
     * @param secret 密钥
     * @param data   待签名文本
     * @return 十六进制串
     */
    private static String hmacSha256Hex(String secret, String data) {
        try {
            final Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
            return toHex(mac.doFinal(data.getBytes(StandardCharsets.UTF_8)));
        } catch (Exception exception) {
            throw new IllegalStateException("HMAC-SHA256 计算失败", exception);
        }
    }

    /**
     * 字节数组转小写十六进制串。
     *
     * @param bytes 字节数组
     * @return 十六进制字符串
     */
    private static String toHex(byte[] bytes) {
        final StringBuilder builder = new StringBuilder(bytes.length * 2);
        for (byte value : bytes) {
            builder.append(Character.forDigit((value >> 4) & 0xF, 16))
                    .append(Character.forDigit(value & 0xF, 16));
        }
        return builder.toString();
    }
}
