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
     * 展示图对象键约定（EXIF 剥离后的可读副本）：{@code "display/" + 原对象键 + ".jpg"}。
     *
     * <p>单源提取（编码规范 §1.1）：图片 commit 后原图被删、只余展示图，两个
     * {@code processImage} 实现与媒体可读键解析（{@code MediaService#readableKeyOf}）
     * 共用同一推导，禁各处复制 {@code "display/"} 字面量。</p>
     *
     * <p>末段 {@code .jpg} 不可省：展示图由 {@code image/format,jpg} 重编码而来，
     * 带扩展名既使 OSS 能按扩展名推定 {@code Content-Type}，也让按 URL 尾缀嗅探
     * 图片类型的消费方（如 AI 上游多模态下载）拿到正确类型。</p>
     *
     * @param objectKey 原对象键
     * @return {@link String} 展示图对象键
     */
    static String displayKeyOf(String objectKey) {
        return "display/" + objectKey + ".jpg";
    }

    /**
     * OSS 图片等比缩放处理参数前缀（AI 入参缩略图；末尾接目标宽度像素值）。
     *
     * <p>单源提取：仅 {@code MediaService} 的 AI 只读签名引用，禁各处复制字面量。</p>
     */
    String IMAGE_RESIZE_PROCESS_PREFIX = "x-oss-process=image/resize,w_";

    /**
     * 给已签名 URL 追加 OSS 图片等比缩放参数（AI 上游入参缩略图，B2-4 提速）。
     *
     * <p><b>为什么可以直接追加</b>：OSS V1 签名的 CanonicalizedResource 只覆盖固定子资源
     * 列表（{@code ?acl}/{@code ?uploadId} 等），{@code x-oss-process} 不在其列、不参与
     * 签名（官方「图片处理」与「签名 URL」口径），故追加不会触发 {@code SignatureDoesNotMatch}。</p>
     *
     * @param signedUrl 带签名的只读访问 URL
     * @param widthPx   等比缩放的目标宽度（像素）
     * @return {@link String} 追加缩放参数后的 URL
     */
    static String withImageResize(String signedUrl, int widthPx) {
        String separator = signedUrl.contains("?") ? "&" : "?";
        return signedUrl + separator + IMAGE_RESIZE_PROCESS_PREFIX + widthPx;
    }

    /**
     * OSS 对象元数据（HEAD 二次校验结果）。
     *
     * @param sizeBytes   实际字节数
     * @param contentType 实际 MIME 类型
     */
    record OssObjectMeta(long sizeBytes, String contentType) {
    }
}
