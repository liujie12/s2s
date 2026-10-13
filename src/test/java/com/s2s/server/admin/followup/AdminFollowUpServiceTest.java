package com.s2s.server.admin.followup;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminFollowUpPageResponse;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.ops.OpsFollowUpService;
import com.s2s.server.ops.dto.FollowUpPage;
import com.s2s.server.ops.entity.OpsFollowUpEntity;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminFollowUpService} 单元测试（[153] B2-5 ⑥ 待运营跟进队列）。
 *
 * <p>守三件事：① RBAC（仅运营专员/超管，其余 40305 且不触达 ops 服务）；
 * ② 列表默认 pending 且透传关键词/网格；③ 处理成功后写审计、失败不写。</p>
 */
class AdminFollowUpServiceTest {

    /** ops 域队列服务（mock）。 */
    private OpsFollowUpService opsFollowUpService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminFollowUpService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        opsFollowUpService = mock(OpsFollowUpService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminFollowUpService(opsFollowUpService, auditLogWriter);
    }

    /**
     * 运营专员可读队列；默认状态 pending、分页归一。
     *
     * @return void
     */
    @Test
    void operatorListsPendingQueue() {
        OpsFollowUpEntity row = new OpsFollowUpEntity();
        row.setId(1L);
        row.setKeyword("搬家");
        row.setGridId("0_0");
        row.setStatus(OpsFollowUpService.STATUS_PENDING);
        row.setTriggeredAt(LocalDateTime.of(2026, 10, 1, 9, 0));
        when(opsFollowUpService.list(eq("pending"), eq(1), eq(20)))
                .thenReturn(new FollowUpPage(List.of(row), 1L, 1, 20));

        AdminFollowUpPageResponse response = service.list(OperatorRole.OPERATOR, null, null, null);

        assertThat(response.items()).hasSize(1);
        assertThat(response.items().get(0).keyword()).isEqualTo("搬家");
        assertThat(response.pageSize()).isEqualTo(20);
    }

    /**
     * 内容审核员/算法运营 → 40305，且不触达 ops 服务。
     *
     * @return void；断言失败即越权可读跟进队列
     */
    @Test
    void nonOperatorDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.AUDITOR, OperatorRole.ALGO}) {
            assertThatThrownBy(() -> service.list(role, null, null, null))
                    .as("角色 %s 不应可读跟进队列", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(opsFollowUpService, never()).list(anyString(), anyInt(), anyInt());
    }

    /**
     * 处理成功 → 调域服务 + 写审计。
     *
     * @return void
     */
    @Test
    void handleWritesAudit() {
        service.handle(OperatorRole.OPERATOR, 5L, 1L, "已补充供给");

        verify(opsFollowUpService).handle(eq(1L), eq(5L), eq("已补充供给"));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 域服务抛错（已处理/不存在）→ 不写审计。
     *
     * @return void
     */
    @Test
    void handleFailureWritesNoAudit() {
        doThrow(BizException.of(ErrorCode.PARAM_INVALID))
                .when(opsFollowUpService).handle(any(Long.class), any(Long.class), any());

        assertThatThrownBy(() -> service.handle(OperatorRole.OPERATOR, 5L, 1L, null))
                .isInstanceOf(BizException.class);
        verify(auditLogWriter, never()).write(any());
    }
}
