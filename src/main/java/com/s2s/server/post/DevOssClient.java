package com.s2s.server.post;

import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.stereotype.Component;

/**
 * OSS dev 桩实现（[125]；{@code s2s.oss.mock=true} 时生效，默认开启）。
 *
 * <p>职责：在真桶未就绪时兜底——票据签发、二次校验、图片处理、删除均返回
 * mock 结果，使媒体两步直传链路可端到端联调。真 SDK 路径见 {@link AliyunOssClient}。</p>
 *
 * <p>安全红线：本桩仅用于 dev 联调，<b>生产路径必须为真 SDK</b>（{@code s2s.oss.mock=false}）。</p>
 */
@Component
@ConditionalOnProperty(name = "s2s.oss.mock", havingValue = "true", matchIfMissing = true)
public class DevOssClient implements OssClient {

    /** mock 直传地址前缀。 */
    private static final String MOCK_BASE = "http://mock-oss.local";

    /**
     * 返回 mock 直传地址（不真签名）。
     */
    @Override
    public String signUploadUrl(String objectKey, String contentType) {
        return MOCK_BASE + "/upload/" + objectKey;
    }

    /**
     * 返回 mock 元数据（不真 HEAD）。
     */
    @Override
    public OssObjectMeta headObject(String objectKey) {
        return new OssObjectMeta(0L, "image/jpeg");
    }

    /**
     * 返回 mock 展示图键（原图键前加 display/ 前缀）。
     */
    @Override
    public String processImage(String objectKey) {
        return "display/" + objectKey;
    }

    /**
     * mock 删除：空操作（无真实对象）。
     */
    @Override
    public void deleteObject(String objectKey) {
        // dev 桩无真实对象，删除为空操作
    }

    /**
     * 返回 mock 访问地址。
     */
    @Override
    public String signAccessUrl(String objectKey) {
        return MOCK_BASE + "/access/" + objectKey;
    }
}
