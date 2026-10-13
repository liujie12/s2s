package com.s2s.server.ops;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.ops.entity.OpsFollowUpEntity;
import com.s2s.server.ops.mapper.OpsFollowUpMapper;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link OpsFollowUpService} 单元测试（[153] B2-5 ⑥；PRD §6.4.4）。
 *
 * <p>守三件事：① 去重（同条件已有 pending 则不再入队）；② 入队落 pending；
 * ③ 处理状态机（缺失 41001 / 已处理 40001）。</p>
 */
class OpsFollowUpServiceTest {

    /** 队列 Mapper（mock）。 */
    private OpsFollowUpMapper mapper;

    /** 被测服务。 */
    private OpsFollowUpService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        mapper = mock(OpsFollowUpMapper.class);
        service = new OpsFollowUpService(mapper);
    }

    /**
     * 无同条件 pending → 入队一条 pending。
     *
     * @return void
     */
    @Test
    void enqueueInsertsPendingRow() {
        when(mapper.selectCount(any())).thenReturn(0L);

        service.enqueue(7L, "搬家", 101, "0_0");

        verify(mapper).insert(any(OpsFollowUpEntity.class));
    }

    /**
     * 已有同条件 pending → 跳过（不刷爆队列）。
     *
     * @return void；断言失败即重复空搜可无限入队
     */
    @Test
    void enqueueSkipsDuplicatePending() {
        when(mapper.selectCount(any())).thenReturn(1L);

        service.enqueue(7L, "搬家", 101, "0_0");

        verify(mapper, never()).insert(any(OpsFollowUpEntity.class));
    }

    /**
     * 游客入队（userId 为 null）也应可写。
     *
     * @return void
     */
    @Test
    void enqueueAllowsGuest() {
        when(mapper.selectCount(any())).thenReturn(0L);

        service.enqueue(null, "搬家", null, "0_0");

        verify(mapper).insert(any(OpsFollowUpEntity.class));
    }

    /**
     * 处理缺失条目 → 41001；已处理 → 40001。
     *
     * @return void
     */
    @Test
    void handleValidatesExistenceAndStatus() {
        when(mapper.selectById(9L)).thenReturn(null);
        assertThatThrownBy(() -> service.handle(9L, 1L, null))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);

        OpsFollowUpEntity handled = new OpsFollowUpEntity();
        handled.setId(10L);
        handled.setStatus(OpsFollowUpService.STATUS_HANDLED);
        when(mapper.selectById(10L)).thenReturn(handled);
        assertThatThrownBy(() -> service.handle(10L, 1L, null))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 处理 pending 条目 → 置 handled + 记处理人。
     *
     * @return void
     */
    @Test
    void handleMarksHandled() {
        OpsFollowUpEntity pending = new OpsFollowUpEntity();
        pending.setId(11L);
        pending.setStatus(OpsFollowUpService.STATUS_PENDING);
        when(mapper.selectById(11L)).thenReturn(pending);

        service.handle(11L, 3L, "已联系发布者补充供给");

        verify(mapper).updateById(any(OpsFollowUpEntity.class));
        assertThat(pending.getStatus()).isEqualTo(OpsFollowUpService.STATUS_PENDING);
    }
}
