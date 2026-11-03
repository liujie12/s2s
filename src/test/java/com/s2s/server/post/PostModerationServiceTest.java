package com.s2s.server.post;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.notify.NotifyType;
import com.s2s.server.notify.PushDispatchService;
import com.s2s.server.post.entity.PostEntity;
import com.s2s.server.post.mapper.PostMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link PostModerationService} 审核下架测试。
 *
 * <p>守的是：下架成功后必须给作者写一条系统通知；帖子已非 active 时不下架、不通知。</p>
 */
class PostModerationServiceTest {

    /** 帖子 ID。 */
    private static final long POST_ID = 10L;

    /** 作者 ID。 */
    private static final Long AUTHOR_ID = 100L;

    /** post 表 Mapper（mock）。 */
    private PostMapper postMapper;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 通知写入编排（mock）。 */
    private PushDispatchService pushDispatchService;

    /** 被测服务。 */
    private PostModerationService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        postMapper = mock(PostMapper.class);
        auditLogWriter = mock(AuditLogWriter.class);
        pushDispatchService = mock(PushDispatchService.class);
        service = new PostModerationService(postMapper, auditLogWriter, pushDispatchService);
    }

    /**
     * active 帖子下架成功：更新状态、写审计、通知作者。
     *
     * @return void；断言失败即下架后作者收不到通知
     */
    @Test
    void auditTakedownNotifiesAuthor() {
        when(postMapper.selectById(POST_ID)).thenReturn(activePost());

        boolean changed = service.auditTakedown(POST_ID, 1L, OperatorRole.SUPER_ADMIN);

        assertThat(changed).isTrue();
        verify(postMapper).updateById(any(PostEntity.class));
        verify(auditLogWriter).write(any(AuditEntry.class));
        verify(pushDispatchService).dispatch(eq(AUTHOR_ID), eq(NotifyType.SYSTEM),
                any(String.class), any(String.class), eq(POST_ID));
    }

    /**
     * 已下架帖子：幂等返回 false，不写审计、不发通知。
     *
     * @return void；断言失败即会重复下架/重复通知
     */
    @Test
    void auditTakedownSkipsInactivePost() {
        PostEntity archived = activePost();
        archived.setStatus(PostStatus.DB_ARCHIVED);
        when(postMapper.selectById(POST_ID)).thenReturn(archived);

        boolean changed = service.auditTakedown(POST_ID, 1L, OperatorRole.SUPER_ADMIN);

        assertThat(changed).isFalse();
        verify(postMapper, never()).updateById(any(PostEntity.class));
        verify(pushDispatchService, never()).dispatch(any(), any(), any(), any(), any());
    }

    /**
     * 构造 active 帖子。
     *
     * @return {@link PostEntity} 测试帖子
     */
    private PostEntity activePost() {
        PostEntity post = new PostEntity();
        post.setId(POST_ID);
        post.setUserId(AUTHOR_ID);
        post.setTitle("测试发布");
        post.setStatus(PostStatus.DB_ACTIVE);
        return post;
    }
}
