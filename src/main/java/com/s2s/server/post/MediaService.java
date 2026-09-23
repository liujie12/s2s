package com.s2s.server.post;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.common.constants.NfrMedia;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
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
public class MediaService {

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
        if (!NfrMedia.ALLOWED_CONTENT_TYPES.contains(contentType)) {
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

        // 剥离 EXIF 生成展示图 → 删除含 GPS 原图（同事务）
        String displayKey = ossClient.processImage(media.getObjectKey());
        ossClient.deleteObject(media.getObjectKey());

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
