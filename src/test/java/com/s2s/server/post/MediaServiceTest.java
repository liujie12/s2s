package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

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
}
