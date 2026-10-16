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
    default String signAccessUrl(String objectKey) {
        return signAccessUrl(objectKey, null);
    }

    /**
     * 返回对象带签名访问 URL，可携带 OSS 图片处理参数。
     *
     * <p><b>{@code imageProcess} 必须经 SDK 一起参与签名</b>：{@code x-oss-process} 是
     * OSS V1 签名的**子资源（SubResource）之一**，会被纳入 CanonicalizedResource ——
     * 若在已签名 URL 上**字符串拼接**该参数，签名与实际请求不匹配，OSS 直接回
     * {@code 403 SignatureDoesNotMatch}（2026-10-17 线上实测：DashScope 侧表现为
     * {@code Failed to download multimodal content}，与「对象不存在」同文案，极难分辨）。
     * 故此处把它交给 {@code GeneratePresignedUrlRequest#setProcess} 统一计算。</p>
     *
     * @param objectKey    对象键（展示图）
     * @param imageProcess OSS 图片处理参数（如 {@code image/resize,w_1024}）；null = 原图直出
     * @return 带签名的临时访问地址
     */
    String signAccessUrl(String objectKey, String imageProcess);

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
     * <p>取值**不含** {@code x-oss-process=} 前缀 —— 该参数必须经
     * {@link #signAccessUrl(String, String)} 交给 SDK 一起签名，**不得**拼进 URL
     * （子资源不参与签名会导致 {@code 403}）。</p>
     */
    String IMAGE_RESIZE_PROCESS_PREFIX = "image/resize,w_";

    /**
     * 构造 OSS 图片等比缩放处理参数（供 {@link #signAccessUrl(String, String)} 使用）。
     *
     * @param widthPx 等比缩放的目标宽度（像素）
     * @return {@link String} 处理参数取值（如 {@code image/resize,w_1024}）
     */
    static String imageResizeProcess(int widthPx) {
        return IMAGE_RESIZE_PROCESS_PREFIX + widthPx;
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
