package com.s2s.server.post;

/**
 * OSS 客户端抽象（[125]；安全方案 §5.1 直传七约束）。
 *
 * <p>职责：把媒体两步直传的 OSS 侧操作抽象为接口，使真实现（阿里云 SDK）与
 * dev 桩可切换；失败注入测试通过 mock 本接口覆盖「原图删除同事务回滚」（KTD6）。</p>
 *
 * <p>真实现 {@code AliyunOssClient} 接阿里云 OSS SDK；dev 桩 {@code DevOssClient}
 * 在 {@code s2s.oss.mock=true}（默认）时生效，供 curl 实测兜底验收。</p>
 */
public interface OssClient {

    /**
     * 签发客户端直传原图的带签名 PUT URL（短时效，客户端不持长期密钥）。
     *
     * @param objectKey   OSS 对象键（服务端 UUID 生成）
     * @param contentType 上传对象 MIME 类型
     * @return 带签名的短时效直传地址
     */
    String signUploadUrl(String objectKey, String contentType);

    /**
     * 二次校验实际对象元数据（不信客户端声明的 size/content_type）。
     *
     * @param objectKey OSS 对象键
     * @return 实际对象元数据（size + content_type）
     */
    OssObjectMeta headObject(String objectKey);

    /**
     * 剥离 EXIF（GPS/设备/拍摄时间）生成展示图。
     *
     * @param objectKey 原图对象键
     * @return 展示图对象键
     */
    String processImage(String objectKey);

    /**
     * 删除原图对象（含 GPS EXIF，须与 commit 同事务同步，禁 @Async）。
     *
     * @param objectKey 原图对象键
     */
    void deleteObject(String objectKey);

    /**
     * 返回对象带签名访问 URL（桶不开公共读，所有读取走带签名临时 URL）。
     *
     * @param objectKey 对象键（展示图）
     * @return 带签名的临时访问地址
     */
    String signAccessUrl(String objectKey);

    /**
     * OSS 对象元数据（HEAD 二次校验结果）。
     *
     * @param sizeBytes   实际字节数
     * @param contentType 实际 MIME 类型
     */
    record OssObjectMeta(long sizeBytes, String contentType) {
    }
}
