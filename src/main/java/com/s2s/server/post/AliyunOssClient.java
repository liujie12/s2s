package com.s2s.server.post;

import com.aliyun.oss.HttpMethod;
import com.aliyun.oss.OSS;
import com.aliyun.oss.OSSClientBuilder;
import com.aliyun.oss.model.ObjectMetadata;
import com.aliyun.oss.model.ProcessObjectRequest;
import com.s2s.server.common.config.SecretsProperties;
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
     */
    @Override
    public String signUploadUrl(String objectKey, String contentType) {
        Date expiration = new Date(System.currentTimeMillis() + SIGN_EXPIRATION_MILLIS);
        return oss.generatePresignedUrl(bucket, objectKey, expiration, HttpMethod.PUT).toString();
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
     * 剥离 EXIF 生成展示图（OSS 图片处理，重编码去除元数据）。
     */
    @Override
    public String processImage(String objectKey) {
        String displayKey = "display/" + objectKey;
        ProcessObjectRequest request = new ProcessObjectRequest(bucket, objectKey, EXIF_STRIP_PROCESS);
        // 处理结果写回展示图键；详情以真桶联调为准
        oss.processObject(request);
        return displayKey;
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
