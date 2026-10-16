package com.s2s.server.post;

import com.aliyun.oss.HttpMethod;
import com.aliyun.oss.OSS;
import com.aliyun.oss.OSSClientBuilder;
import com.aliyun.oss.model.GeneratePresignedUrlRequest;
import com.aliyun.oss.model.ObjectMetadata;
import com.aliyun.oss.model.ProcessObjectRequest;
import com.s2s.server.common.config.SecretsProperties;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Date;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * 阿里云 OSS 真实现（[125]；{@code s2s.oss.mock=false} 时生效）。
 *
 * <p>职责：接阿里云 OSS SDK（V1），实现票据签发、二次校验、EXIF 剥离、原图删除、
 * 访问签名。凭证来自 {@link SecretsProperties}（AK/SK，不入仓库）；endpoint/bucket
 * 来自 {@code s2s.oss.*} 配置。</p>
 *
 * <p>安全约束（安全方案 §5.1）：桶不开公共读、客户端不持长期密钥、原图删除同步、
 * 对象名服务端生成。</p>
 */
@Component
@ConditionalOnProperty(name = "s2s.oss.mock", havingValue = "false")
public class AliyunOssClient implements OssClient {

    /** 票据/访问 URL 有效期（毫秒）；短时效，24h 未 commit 由定时任务清理。 */
    private static final long SIGN_EXPIRATION_MILLIS = 15 * 60 * 1000L;

    /** EXIF 剥离处理串：重编码去除元数据（TODO：真桶联调验证样式）。 */
    private static final String EXIF_STRIP_PROCESS = "image/format,jpg";

    /** 另存为指令前缀：同步图片处理默认不落盘，须显式 {@code sys/saveas} 指定目标键与桶。 */
    private static final String SAVE_AS_PREFIX = "|sys/saveas,o_";

    private final OSS oss;
    private final String bucket;

    /**
     * 构造真 OSS 客户端。
     *
     * @param secrets  凭证（AK/SK）
     * @param endpoint OSS endpoint（如 {@code https://oss-cn-hangzhou.aliyuncs.com}）
     * @param bucket   桶名
     */
    public AliyunOssClient(SecretsProperties secrets,
            @Value("${s2s.oss.endpoint:}") String endpoint,
            @Value("${s2s.oss.bucket:}") String bucket) {
        this.oss = new OSSClientBuilder().build(
                endpoint, secrets.ossAccessKeyId(), secrets.ossAccessKeySecret());
        this.bucket = bucket;
    }

    /**
     * 签发直传 PUT 签名 URL。
     *
     * <p><b>Content-Type 必须纳入签名</b>：OSS V1 直传签名的 StringToSign 含 Content-Type
     * 一行，客户端 PUT 时按契约必带与签发一致的 {@code Content-Type}（App 侧
     * {@code MediaUploadService} 如此，见其 PUT options）。若签发时不绑定，客户端带上
     * Content-Type 即触发 {@code SignatureDoesNotMatch}(403)——2026-10-14 真桶联调实测复现。
     * 故此处用 {@link GeneratePresignedUrlRequest} 显式 {@code setContentType}，使签名与
     * 客户端实际发送的头一致；同时 OSS 会以该 Content-Type 落对象，供 commit 的 HEAD 二次校验比对。</p>
     */
    @Override
    public String signUploadUrl(String objectKey, String contentType) {
        Date expiration = new Date(System.currentTimeMillis() + SIGN_EXPIRATION_MILLIS);
        GeneratePresignedUrlRequest request =
                new GeneratePresignedUrlRequest(bucket, objectKey, HttpMethod.PUT);
        request.setExpiration(expiration);
        request.setContentType(contentType);
        return oss.generatePresignedUrl(request).toString();
    }

    /**
     * HEAD 二次校验实际对象元数据。
     */
    @Override
    public OssObjectMeta headObject(String objectKey) {
        ObjectMetadata meta = oss.getObjectMetadata(bucket, objectKey);
        return new OssObjectMeta(meta.getContentLength(), meta.getContentType());
    }

    /**
     * 剥离 EXIF 生成展示图（OSS 图片处理 + 另存为，重编码去除元数据）。
     *
     * <p><b>必须显式携带 {@code sys/saveas}</b>：OSS 同步图片处理默认「不保存」处理结果，
     * 只把处理后的字节作为响应流返回（官方「另存为（sys/saveas）」口径）。原实现仅调用
     * 处理、未落盘，而 {@code MediaService.commit} 随后删除原图 → {@code display/<key>}
     * 从未存在、对象全失。2026-10-16 真机模式①排障实证：上游 DashScope 报
     * {@code Failed to download multimodal content}，用服务器 AK/SK 直探该键与已删原键均 404。</p>
     *
     * <p>{@code o_}/{@code b_} 取值须为 <b>URL 安全 Base64</b>（{@code +}→{@code -}、
     * {@code /}→{@code _}、去尾 {@code =}）：处理串会进入请求参数，标准 Base64 的
     * {@code +}/{@code /} 会被解码错。</p>
     *
     * @param objectKey 原图对象键
     * @return 展示图对象键（{@code display/<原键>.jpg}）
     */
    @Override
    public String processImage(String objectKey) {
        String displayKey = OssClient.displayKeyOf(objectKey);
        String process = EXIF_STRIP_PROCESS + SAVE_AS_PREFIX + urlSafeBase64(displayKey)
                + ",b_" + urlSafeBase64(bucket);
        oss.processObject(new ProcessObjectRequest(bucket, objectKey, process));
        return displayKey;
    }

    /**
     * URL 安全 Base64 编码（去尾填充），用于 {@code sys/saveas} 的 {@code o_}/{@code b_} 取值。
     *
     * @param value 待编码文本（目标对象键 / 桶名）
     * @return URL 安全 Base64 字符串（无 {@code =} 填充）
     */
    private static String urlSafeBase64(String value) {
        return Base64.getUrlEncoder().withoutPadding()
                .encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }

    /**
     * 删除原图对象（含 GPS EXIF）。
     */
    @Override
    public void deleteObject(String objectKey) {
        oss.deleteObject(bucket, objectKey);
    }

    /**
     * 返回展示图带签名访问 URL。
     */
    @Override
    public String signAccessUrl(String objectKey) {
        Date expiration = new Date(System.currentTimeMillis() + SIGN_EXPIRATION_MILLIS);
        return oss.generatePresignedUrl(bucket, objectKey, expiration, HttpMethod.GET).toString();
    }
}
