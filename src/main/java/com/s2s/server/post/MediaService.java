package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.common.constants.NfrAi;
import com.s2s.server.common.constants.NfrMedia;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.common.moderation.MediaAuditChecker;
import com.s2s.server.post.dto.MediaCommitResult;
import com.s2s.server.post.dto.UploadTicket;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.PostMediaMapper;
import java.time.Instant;
import java.util.UUID;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 媒体服务（[125]；详设 §5.3.1 媒体两步式直传）。
 *
 * <p>职责：承载 {@code POST /media/upload/ticket} 与 {@code POST /media/{id}/commit}
 * 的业务逻辑——票据签发、commit 二次校验、EXIF 剥离、原图删除同事务、审核置 pass，
 * 以及发布时的 reject 判定与归属校验。</p>
 */
@Service
public class MediaService implements MediaAuditChecker {

    /** 审核状态：待审核（ticket 后、commit 前）。 */
    static final String AUDIT_PENDING = "pending";

    /** 审核状态：通过。 */
    static final String AUDIT_PASS = "pass";

    /** 审核状态：拒绝。 */
    static final String AUDIT_REJECT = "reject";

    private final PostMediaMapper mediaMapper;
    private final OssClient ossClient;

    /**
     * 构造媒体服务。
     *
     * @param mediaMapper 媒体 Mapper
     * @param ossClient   OSS 客户端（真 SDK 或 dev 桩）
     */
    public MediaService(PostMediaMapper mediaMapper, OssClient ossClient) {
        this.mediaMapper = mediaMapper;
        this.ossClient = ossClient;
    }

    /**
     * 签发 OSS 直传票据（两步式第 1 步）。
     *
     * @param userId      上传者 user_id（归属校验落列）
     * @param filename    原始文件名（仅记录）
     * @param size        文件字节数
     * @param contentType MIME 类型
     * @return {@link UploadTicket}（media_id + upload_url + expire_at）
     * @throws BizException content_type 不在白名单 / size 超限 → 40001
     */
    public UploadTicket createTicket(Long userId, String filename, int size, String contentType) {
        if (!NfrMedia.ALLOWED_CONTENT_TYPES.contains(contentType)
                && !NfrMedia.AUDIO_CONTENT_TYPES.contains(contentType)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (size > NfrMedia.MAX_SIZE_BYTES) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        String objectKey = UUID.randomUUID().toString();
        PostMediaEntity entity = new PostMediaEntity();
        entity.setPostId(null);
        entity.setUserId(userId);
        entity.setObjectKey(objectKey);
        entity.setAuditStatus(AUDIT_PENDING);
        entity.setContentType(contentType);
        entity.setSizeBytes(size);
        mediaMapper.insert(entity);

        String mediaId = String.valueOf(entity.getId());
        String uploadUrl = ossClient.signUploadUrl(objectKey, contentType);
        return new UploadTicket(mediaId, uploadUrl, Instant.now().plusSeconds(15 * 60));
    }

    /**
     * 确认媒体上传完成（两步式第 2 步）。
     *
     * <p>链路（安全方案 §5.2，🔴 阻塞）：HEAD 二次校验 → 归属校验 → 剥离 EXIF 生成
     * 展示图 → 删除含 GPS 原图（同事务同步，禁 @Async）→ Noop 审核置 pass。</p>
     *
     * @param userId  当前用户 user_id
     * @param mediaId 媒体 ID（路径参数）
     * @return {@link MediaCommitResult}
     * @throws BizException media 不存在/非本人/二次校验不符 → 40001
     */
    @Transactional
    public MediaCommitResult commit(Long userId, String mediaId) {
        PostMediaEntity media = loadOwned(userId, mediaId);

        // HEAD 二次校验：不信客户端声明的 size/content_type
        OssClient.OssObjectMeta meta = ossClient.headObject(media.getObjectKey());
        if (meta.contentType() == null || !meta.contentType().equals(media.getContentType())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }

        // 剥离 EXIF 生成展示图 → 删除含 GPS 原图（同事务）。
        // B2-4 音频（模式②）：无 EXIF 且 OSS 图片处理不适用，跳过处理链，以原对象为可访问对象。
        String displayKey;
        if (NfrMedia.AUDIO_CONTENT_TYPES.contains(media.getContentType())) {
            displayKey = media.getObjectKey();
        } else {
            displayKey = ossClient.processImage(media.getObjectKey());
            ossClient.deleteObject(media.getObjectKey());
        }

        // Noop 审核（Batch1 立即 pass）
        media.setAuditStatus(AUDIT_PASS);
        mediaMapper.updateById(media);

        return new MediaCommitResult(mediaId, ossClient.signAccessUrl(displayKey), AUDIT_PASS, null);
    }

    /**
     * 校验媒体是否被拒绝（发布/预检图片过审 40902）。
     *
     * <p>{@code reject} → 40902；{@code pending}/{@code pass} 放行（对齐 openapi
     * 「pending 允许提交发布」三态双视角）。</p>
     *
     * @param mediaId 媒体 ID
     * @throws BizException {@code audit_status=reject} 时抛 40902
     */
    public void ensureNotRejected(Long mediaId) {
        PostMediaEntity media = mediaMapper.selectById(mediaId);
        if (media != null && AUDIT_REJECT.equals(media.getAuditStatus())) {
            throw BizException.of(ErrorCode.IMAGE_REJECTED);
        }
    }

    /**
     * AI 上行读取授权（B2-4 阶段① Step 2）：为「本人媒体」签发只读短时效 GET 签名 URL。
     *
     * <p>可读对象键解析见 {@link #readableKeyOf}（音频→原键；图片 pass→展示键；
     * 图片 pending→原键）。</p>
     *
     * <p><b>图片额外携带等比缩放</b>（2026-10-17 提速）：上游需先下载图片再编码，耗时随
     * 像素量上升，故图片签名 URL 携带 {@code x-oss-process} 缩略参数，目标宽度取
     * {@link NfrAi#AI_INPUT_IMAGE_WIDTH_PX}。<b>该参数必须经
     * {@link OssClient#signAccessUrl(String, String)} 与签名一并计算</b> —— 它属 V1 签名
     * 子资源，拼到已签名 URL 上会 403。音频不加（走原对象、转写用）。</p>
     *
     * @param userId  当前用户 user_id（归属校验，防 IDOR）
     * @param mediaId 媒体 ID
     * @return {@link AiMediaAccess} 只读签名 URL + 媒体 MIME（音频转写按 MIME 推上游 format）
     * @throws BizException 媒体不存在/非本人 → 40001
     */
    public AiMediaAccess signAiReadAccess(Long userId, String mediaId) {
        PostMediaEntity media = loadOwned(userId, mediaId);
        String imageProcess = NfrMedia.AUDIO_CONTENT_TYPES.contains(media.getContentType())
                ? null
                : OssClient.imageResizeProcess(NfrAi.AI_INPUT_IMAGE_WIDTH_PX);
        String accessUrl = ossClient.signAccessUrl(readableKeyOf(media), imageProcess);
        return new AiMediaAccess(accessUrl, media.getContentType());
    }

    /**
     * 校验媒体属于当前用户（不签发 URL、不产生副作用）。
     *
     * <p>供非 media 域在上传后、引用前做归属校验（如资质档案引用证照图）。</p>
     *
     * @param userId  当前用户 user_id
     * @param mediaId 媒体 ID
     * @throws BizException 媒体不存在/非本人 → 40001
     */
    public void ensureOwned(Long userId, String mediaId) {
        loadOwned(userId, mediaId);
    }

    /**
     * 校验媒体是「本人已 commit 的图片」（举报凭证引用前的闸门）。
     *
     * <p>与 {@link #ensureOwned} 的差别是多了两道：未 commit（{@code pending}）的记录
     * 尚未经 HEAD 二次校验与 EXIF 剥离，后台按它取图会拿到不存在或未处理的对象；
     * 音频不在举报凭证的允许范围内（客户端只提供图片入口）。任一不满足均回
     * {@code 40001} —— 与归属校验同一码值，不新增错误码。</p>
     *
     * @param userId  当前用户 user_id
     * @param mediaId 媒体 ID
     * @throws BizException 媒体不存在/非本人/未 commit/非图片 → 40001
     */
    public void ensureOwnedCommittedImage(Long userId, String mediaId) {
        PostMediaEntity media = loadOwned(userId, mediaId);
        boolean committedImage = AUDIT_PASS.equals(media.getAuditStatus())
                && NfrMedia.ALLOWED_CONTENT_TYPES.contains(media.getContentType());
        if (!committedImage) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
    }

    /**
     * 校验媒体是否已过审（{@link MediaAuditChecker} 的真实实现）。
     *
     * <p>媒体不存在或未过审一律返回 {@code 40902}：头像引用 {@code media_id}
     * 是唯一消费点，语义上等价于「这张图不能作为头像使用」。</p>
     *
     * @param mediaId 媒体 ID（已 commit 的 media_id）
     * @throws BizException 媒体不存在 / 未过审 → {@code 40902}；media_id 非数字 → {@code 40001}
     */
    @Override
    public void checkApproved(String mediaId) {
        PostMediaEntity media = mediaMapper.selectById(parseMediaId(mediaId));
        if (media == null || !AUDIT_PASS.equals(media.getAuditStatus())) {
            throw BizException.of(ErrorCode.IMAGE_REJECTED);
        }
    }

    /**
     * 解析本人头像媒体为可读对象键（写入 {@code user.avatar_url} 的稳定引用）。
     *
     * <p>为什么存对象键而不是签名 URL：OSS 签名 URL 只有 15 分钟有效期，落库后
     * 很快失效；对象键稳定，读取时由 {@code AvatarUrlAssembler} 现签。</p>
     *
     * @param userId  当前用户 user_id（归属校验，防 IDOR）
     * @param mediaId 媒体 ID（已 commit 的 avatar_media_id）
     * @return {@link String} 可读对象键（展示图键）
     * @throws BizException 非本人 / 不存在 / 非图片 → {@code 40001}；未过审 → {@code 40902}
     */
    public String readableAvatarKey(Long userId, String mediaId) {
        PostMediaEntity media = loadOwned(userId, mediaId);
        if (!AUDIT_PASS.equals(media.getAuditStatus())) {
            throw BizException.of(ErrorCode.IMAGE_REJECTED);
        }
        if (!NfrMedia.ALLOWED_CONTENT_TYPES.contains(media.getContentType())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return readableKeyOf(media);
    }

    /**
     * 为「本人媒体」签发普通只读 GET 签名 URL（catalog 展示用，不带缩放参数）。
     *
     * <p>与 {@link #signAiReadAccess} 的区别：后者给 AI 上游用、图片带等比缩放参数；
     * 本方法给前端展示用，原样出图。</p>
     *
     * @param userId  当前用户 user_id（归属校验，防 IDOR）
     * @param mediaId 媒体 ID
     * @return {@link String} 只读签名 URL
     * @throws BizException 媒体不存在/非本人 → 40001
     */
    public String signOwnedReadUrl(Long userId, String mediaId) {
        PostMediaEntity media = loadOwned(userId, mediaId);
        return ossClient.signAccessUrl(readableKeyOf(media));
    }

    /**
     * 为媒体签发「任意登录/游客可读」的普通只读 GET 签名 URL（证照图公开展示用）。
     *
     * <p><b>为什么不做归属校验</b>：2026-10-29 用户裁定详情页资质栏展示证照图
     * （缩略图 + 可点开大图，暂不打码），详情页对游客开放，故该 URL 不做归属判断。
     * 其余场景仍必须走 {@link #signOwnedReadUrl} 防 IDOR。</p>
     *
     * @param mediaId 媒体 ID
     * @return {@link String} 只读签名 URL；媒体行不存在返回 {@code null}
     */
    public String signPublicReadUrl(String mediaId) {
        if (mediaId == null || mediaId.isBlank()) {
            return null;
        }
        PostMediaEntity media = mediaMapper.selectById(mediaId);
        return media == null ? null : ossClient.signAccessUrl(readableKeyOf(media));
    }

    /**
     * 为后台复核查看举报凭证签发只读 URL（**不做归属校验**）。
     *
     * <p>与 {@link #signPublicReadUrl} 的实现相同，分列只为让调用点可读：那个方法面向
     * 「详情页公开证照」，本方法面向「已鉴权后台的举报复核」。举报凭证可能含敏感内容，
     * 任何把它接到前台页面的改动都应在代码审查时一眼可见。</p>
     *
     * <p><b>容错</b>：工单可能引用已删除的媒体（历史行或清理任务），或存着非数字 ID。
     * 这类条目不阻断整条工单的查看，返回 {@code null} 由调用方过滤——少一张图
     * 好过整页打不开。</p>
     *
     * @param mediaId 媒体 ID 字符串（举报 {@code evidence} 数组元素）
     * @return {@link String} 只读签名 URL；空白/非数字/媒体不存在时返回 {@code null}
     */
    public String signAdminEvidenceUrl(String mediaId) {
        if (mediaId == null || mediaId.isBlank()) {
            return null;
        }
        final Long id;
        try {
            id = Long.valueOf(mediaId);
        } catch (NumberFormatException exception) {
            return null;
        }
        PostMediaEntity media = mediaMapper.selectById(id);
        return media == null ? null : ossClient.signAccessUrl(readableKeyOf(media));
    }

    /**
     * 为「帖子已过审首图」签发只读 GET 签名 URL（消息 Tab 会话行缩略图，R3）。
     *
     * <p>调用方（chat 列表）已在 SQL 里按 {@code audit_status='pass'} 过滤，
     * 故这里只按「已 commit 图片」口径取展示图键（原图已被 EXIF 链处理掉），
     * 不再做视角分流；无图时返回 {@code null}，由客户端渲染占位块。</p>
     *
     * @param objectKey 帖子首图原对象键；null/空白表示该帖无图
     * @return {@link String} 只读签名 URL；无图时 {@code null}
     */
    public String signCommittedImageUrl(String objectKey) {
        if (objectKey == null || objectKey.isBlank()) {
            return null;
        }
        return ossClient.signAccessUrl(OssClient.displayKeyOf(objectKey));
    }

    /**
     * 删除「本人媒体」的 OSS 对象与登记行（资质删除时清理证照原件）。
     *
     * <p>只清理尚未挂到帖子上的媒体（{@code post_id IS NULL}）：一旦被帖子引用，
     * 删对象会让帖子图片裂图，故直接跳过——资质删除不应连带破坏帖子内容。</p>
     *
     * @param userId  当前用户 user_id（归属校验，防 IDOR）
     * @param mediaId 媒体 ID
     * @throws BizException 媒体不存在/非本人 → 40001
     */
    public void deleteOwnedMedia(Long userId, String mediaId) {
        PostMediaEntity media = loadOwned(userId, mediaId);
        if (media.getPostId() != null) {
            return;
        }
        ossClient.deleteObject(readableKeyOf(media));
        mediaMapper.deleteById(media.getId());
    }

    /**
     * 解析媒体「可签名读取」的 OSS 对象键（同源口径单点，禁各处自行判分支）。
     *
     * <p>音频 {@code commit} 不走 EXIF 链、原对象始终保留 → 用原键；图片已 commit
     * （{@code pass}）原图已删（见 {@link #commit}）→ 用展示图键；图片未 commit
     * （{@code pending}）原图尚在 → 用原键。</p>
     *
     * @param media 媒体实体
     * @return 可签名访问的对象键
     */
    static String readableKeyOf(PostMediaEntity media) {
        boolean committedImage = !NfrMedia.AUDIO_CONTENT_TYPES.contains(media.getContentType())
                && AUDIT_PASS.equals(media.getAuditStatus());
        return committedImage ? OssClient.displayKeyOf(media.getObjectKey()) : media.getObjectKey();
    }

    /**
     * AI 只读访问载体（B2-4 阶段① Step 2）。
     *
     * @param accessUrl   只读短时效 GET 签名 URL（与上传 PUT 签名两套，勿复用）
     * @param contentType 媒体 MIME 类型
     */
    public record AiMediaAccess(String accessUrl, String contentType) {
    }

    /**
     * 加载当前用户拥有的媒体（归属校验）。
     *
     * <p>媒体不存在或非本人一律 40001（不透露资源是否存在，防 IDOR 枚举）。</p>
     *
     * @param userId  当前用户 user_id
     * @param mediaId 媒体 ID（字符串）
     * @return 归属当前用户的媒体实体
     * @throws BizException media_id 非数字 / 不存在 / 非本人 → 40001
     */
    private PostMediaEntity loadOwned(Long userId, String mediaId) {
        Long id = parseMediaId(mediaId);
        PostMediaEntity media = mediaMapper.selectById(id);
        if (media == null || !media.getUserId().equals(userId)) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        return media;
    }

    /**
     * 解析 media_id 字符串为 Long（post_media.id）。
     *
     * @param mediaId 媒体 ID 字符串
     * @return 数字 ID
     * @throws BizException 非数字 → 40001
     */
    private Long parseMediaId(String mediaId) {
        try {
            return Long.valueOf(mediaId);
        } catch (NumberFormatException e) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
    }
}
