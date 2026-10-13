package com.s2s.server.admin;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminAuditExportResponse;
import com.s2s.server.common.audit.AuditLogQueryService;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.audit.dto.AuditLogFilter;
import com.s2s.server.common.audit.dto.AuditLogItem;
import com.s2s.server.common.audit.dto.AuditLogPage;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.Instant;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;

/**
 * {@link AdminAuditService} 单元测试（[153] B2-5）。
 *
 * <p>守三件事：① 仅超级管理员可查（其余角色一律 40305，越权统一同码）；
 * ② 权限判定先于数据访问（越权时**不得**触达查询服务）；③ 分页参数归一
 * （页码兜底 1、每页条数默认与上限只引用常量）。</p>
 */
class AdminAuditServiceTest {

    /** 审计查询服务（common 域；mock）。 */
    private AuditLogQueryService queryService;

    /** 被测服务。 */
    private AdminAuditService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        queryService = mock(AuditLogQueryService.class);
        service = new AdminAuditService(queryService);
    }

    /**
     * 超级管理员可查：透传过滤条件与分页。
     *
     * @return void；断言失败即超管也查不了（B2-5 审计验收点失败）
     */
    @Test
    void superAdminCanQuery() {
        AuditLogPage page = new AuditLogPage(List.of(), 0L, 1, NfrAdmin.PAGE_SIZE_DEFAULT);
        when(queryService.query(any(), anyInt(), anyInt())).thenReturn(page);

        AuditLogPage result = service.queryAuditLogs(OperatorRole.SUPER_ADMIN, null, "auditor",
                "cert.approve", "cert", 9L, null, null, null, null);

        assertThat(result).isSameAs(page);
        ArgumentCaptor<AuditLogFilter> captor = ArgumentCaptor.forClass(AuditLogFilter.class);
        verify(queryService).query(captor.capture(), anyInt(), anyInt());
        assertThat(captor.getValue().getOperatorRole()).isEqualTo("auditor");
        assertThat(captor.getValue().getAction()).isEqualTo("cert.approve");
        assertThat(captor.getValue().getTargetId()).isEqualTo(9L);
    }

    /**
     * 非超级管理员 → 40305，且**不触达**查询服务。
     *
     * @return void；断言失败即越权可查（审计泄露）
     */
    @Test
    void nonSuperAdminDeniedWith40305() {
        for (OperatorRole role : List.of(OperatorRole.AUDITOR, OperatorRole.OPERATOR,
                OperatorRole.ALGO, OperatorRole.USER, OperatorRole.SYSTEM)) {
            assertThatThrownBy(() -> service.queryAuditLogs(role, null, null, null, null, null,
                    null, null, null, null))
                    .as("角色 %s 不应可查审计", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(queryService, org.mockito.Mockito.never()).query(any(), anyInt(), anyInt());
    }

    /**
     * 分页归一：页码 null → 1（offset 0）；每页条数超上限 → 截断至上限。
     *
     * @return void；断言失败即可能一次拉全表
     */
    @Test
    void pageParamsNormalized() {
        AuditLogPage page = new AuditLogPage(List.of(), 0L, 1, NfrAdmin.PAGE_SIZE_MAX);
        when(queryService.query(any(), anyInt(), anyInt())).thenReturn(page);

        service.queryAuditLogs(OperatorRole.SUPER_ADMIN, null, null, null, null, null,
                null, null, null, 9999);

        ArgumentCaptor<AuditLogFilter> captor = ArgumentCaptor.forClass(AuditLogFilter.class);
        verify(queryService).query(captor.capture(), anyInt(), anyInt());
        assertThat(captor.getValue().getLimit()).isEqualTo(NfrAdmin.PAGE_SIZE_MAX);
        assertThat(captor.getValue().getOffset()).isZero();
    }

    /**
     * 页码 2 → offset = 每页条数（第 2 页起点）。
     *
     * @return void
     */
    @Test
    void pageTwoOffset() {
        when(queryService.query(any(), anyInt(), anyInt()))
                .thenReturn(new AuditLogPage(List.of(), 0L, 2, 10));

        service.queryAuditLogs(OperatorRole.SUPER_ADMIN, null, null, null, null, null,
                null, null, 2, 10);

        ArgumentCaptor<AuditLogFilter> captor = ArgumentCaptor.forClass(AuditLogFilter.class);
        verify(queryService).query(captor.capture(), anyInt(), anyInt());
        assertThat(captor.getValue().getOffset()).isEqualTo(10);
    }

    /**
     * 超管导出：CSV 含表头 + 数据行；含逗号的字段被引号包裹（RFC 4180）；行数回传正确。
     *
     * @return void；断言失败即导出内容不可用或被注入破坏
     */
    @Test
    void superAdminExportBuildsCsvWithEscaping() {
        AuditLogItem item = new AuditLogItem(1L, 7L, "auditor", "cert.approve", "cert", 9L,
                "{\"a\":1}", null, "理由含,逗号", Instant.parse("2026-10-01T09:00:00Z"));
        AuditLogPage page = new AuditLogPage(List.of(item), 1L, 1, NfrAdmin.AUDIT_EXPORT_MAX_ROWS);
        when(queryService.query(any(), anyInt(), anyInt())).thenReturn(page);

        AdminAuditExportResponse response = service.exportCsv(OperatorRole.SUPER_ADMIN,
                null, "auditor", "cert.approve", null, null, null, null);

        assertThat(response.fileName()).isEqualTo("audit-logs.csv");
        assertThat(response.contentType()).startsWith("text/csv");
        assertThat(response.rowCount()).isEqualTo(1);
        assertThat(response.content())
                .startsWith("id,operator_id,operator_role,action,target_type,target_id,"
                        + "before_value,after_value,reason,created_at\n")
                .contains("\"理由含,逗号\"")
                .contains("2026-10-01T09:00:00Z");
    }

    /**
     * 导出单次上限 = {@link NfrAdmin#AUDIT_EXPORT_MAX_ROWS}（防一次拉全量 OOM）。
     *
     * @return void
     */
    @Test
    void exportCappedAtMaxRows() {
        when(queryService.query(any(), anyInt(), anyInt()))
                .thenReturn(new AuditLogPage(List.of(), 0L, 1, NfrAdmin.AUDIT_EXPORT_MAX_ROWS));

        service.exportCsv(OperatorRole.SUPER_ADMIN, null, null, null, null, null, null, null);

        ArgumentCaptor<AuditLogFilter> captor = ArgumentCaptor.forClass(AuditLogFilter.class);
        verify(queryService).query(captor.capture(), anyInt(), anyInt());
        assertThat(captor.getValue().getLimit()).isEqualTo(NfrAdmin.AUDIT_EXPORT_MAX_ROWS);
        assertThat(captor.getValue().getOffset()).isZero();
    }

    /**
     * 非超级管理员导出 → 40305，且不触达查询服务。
     *
     * @return void；断言失败即越权可导出全量审计
     */
    @Test
    void nonSuperAdminExportDenied() {
        assertThatThrownBy(() -> service.exportCsv(OperatorRole.OPERATOR,
                null, null, null, null, null, null, null))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.NO_PERMISSION);
        verify(queryService, org.mockito.Mockito.never()).query(any(), anyInt(), anyInt());
    }
}
