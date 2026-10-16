package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.constants.NfrAi;
import com.s2s.server.common.error.BizException;
import com.s2s.server.post.entity.PostMediaEntity;
import com.s2s.server.post.mapper.PostMediaMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentMatchers;

/**
 * {@link MediaService} 媒体两步直传测试（[125]）。
 *
 * <p>覆盖：票据白名单/大小校验、reject 判定 40902、commit 归属校验。</p>
 */
class MediaServiceTest {

    private PostMediaMapper mediaMapper;
    private OssClient ossClient;
    private MediaService mediaService;

    @BeforeEach
    void setUp() {
        mediaMapper = mock(PostMediaMapper.class);
        ossClient = mock(OssClient.class);
        mediaService = new MediaService(mediaMapper, ossClient);
    }

    @Test
    void createTicketRejectsNonWhitelistContentType() {
        assertThatThrownBy(() -> mediaService.createTicket(1L, "a.jpg", 100, "image/gif"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode().getCode())
                .isEqualTo(40001);
    }

    @Test
    void createTicketRejectsOversize() {
        assertThatThrownBy(() -> mediaService.createTicket(1L, "a.jpg", 30 * 1024 * 1024, "image/jpeg"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode().getCode())
                .isEqualTo(40001);
    }

    @Test
    void ensureNotRejectedThrowsForReject() {
        PostMediaEntity entity = new PostMediaEntity();
        entity.setId(1L);
        entity.setAuditStatus(MediaService.AUDIT_REJECT);
        when(mediaMapper.selectById(1L)).thenReturn(entity);

        assertThatThrownBy(() -> mediaService.ensureNotRejected(1L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode().getCode())
                .isEqualTo(40902);
    }

    @Test
    void ensureNotRejectedAllowsPass() {
        PostMediaEntity entity = new PostMediaEntity();
        entity.setId(1L);
        entity.setAuditStatus(MediaService.AUDIT_PASS);
        when(mediaMapper.selectById(1L)).thenReturn(entity);

        mediaService.ensureNotRejected(1L); // 不抛
    }

    @Test
    void commitRejectsForeignMedia() {
        PostMediaEntity entity = new PostMediaEntity();
        entity.setId(1L);
        entity.setUserId(2L); // 非当前用户
        entity.setObjectKey("k");
        entity.setContentType("image/jpeg");
        when(mediaMapper.selectById(1L)).thenReturn(entity);

        assertThatThrownBy(() -> mediaService.commit(1L, "1"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode().getCode())
                .isEqualTo(40001);
    }

    /**
     * AI 只读签名（B2-4 Step 2）：音频 commit 不删原对象 → 始终用原键。
     */
    @Test
    void signAiReadAccess音频用原键() {
        when(mediaMapper.selectById(1L)).thenReturn(
                media(1L, "k-audio", "audio/wav", MediaService.AUDIT_PASS));
        when(ossClient.signAccessUrl("k-audio", null)).thenReturn("https://oss.test/signed");

        MediaService.AiMediaAccess access = mediaService.signAiReadAccess(1L, "1");

        assertThat(access.accessUrl()).isEqualTo("https://oss.test/signed");
        assertThat(access.contentType()).isEqualTo("audio/wav");
        // 音频不带任何图片处理参数（process 必须为 null）
        verify(ossClient).signAccessUrl("k-audio", null);
    }

    /**
     * AI 只读签名：图片已 commit（pass）原图已删 → 用展示图键。
     */
    @Test
    void signAiReadAccess图片已commit用展示键() {
        when(mediaMapper.selectById(1L)).thenReturn(
                media(1L, "k-img", "image/jpeg", MediaService.AUDIT_PASS));
        when(ossClient.signAccessUrl("display/k-img.jpg",
                        OssClient.imageResizeProcess(NfrAi.AI_INPUT_IMAGE_WIDTH_PX)))
                .thenReturn("https://oss.test/signed");

        MediaService.AiMediaAccess access = mediaService.signAiReadAccess(1L, "1");

        assertThat(access.accessUrl()).isEqualTo("https://oss.test/signed");
        // 缩略参数必须经签名一并传入，**不得**拼进 URL（x-oss-process 属 V1 子资源，拼接会 403）
        verify(ossClient).signAccessUrl("display/k-img.jpg",
                OssClient.imageResizeProcess(NfrAi.AI_INPUT_IMAGE_WIDTH_PX));
    }

    /**
     * AI 只读签名：图片未 commit（pending）原图尚在 → 用原键。
     */
    @Test
    void signAiReadAccess图片未commit用原键() {
        when(mediaMapper.selectById(1L)).thenReturn(
                media(1L, "k-img", "image/jpeg", MediaService.AUDIT_PENDING));
        when(ossClient.signAccessUrl("k-img",
                        OssClient.imageResizeProcess(NfrAi.AI_INPUT_IMAGE_WIDTH_PX)))
                .thenReturn("https://oss.test/signed");

        MediaService.AiMediaAccess access = mediaService.signAiReadAccess(1L, "1");

        // 未 commit 的图片同样带缩略参数（只按「是否音频」分流）
        assertThat(access.accessUrl()).isEqualTo("https://oss.test/signed");
        verify(ossClient).signAccessUrl("k-img",
                OssClient.imageResizeProcess(NfrAi.AI_INPUT_IMAGE_WIDTH_PX));
    }

    /**
     * AI 只读签名：非本人媒体 → 40001（防 IDOR）。
     */
    @Test
    void signAiReadAccess非本人拒绝() {
        PostMediaEntity entity = media(1L, "k", "image/jpeg", MediaService.AUDIT_PASS);
        entity.setUserId(2L);
        when(mediaMapper.selectById(1L)).thenReturn(entity);

        assertThatThrownBy(() -> mediaService.signAiReadAccess(1L, "1"))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode().getCode())
                .isEqualTo(40001);
    }

    /**
     * 造归属当前用户（user_id=1）的媒体实体。
     *
     * @param id          媒体 ID
     * @param key         OSS 对象键
     * @param contentType MIME 类型
     * @param auditStatus 审核状态
     * @return {@link PostMediaEntity} 实体
     */
    private static PostMediaEntity media(Long id, String key, String contentType,
            String auditStatus) {
        PostMediaEntity entity = new PostMediaEntity();
        entity.setId(id);
        entity.setUserId(1L);
        entity.setObjectKey(key);
        entity.setContentType(contentType);
        entity.setAuditStatus(auditStatus);
        return entity;
    }
}
