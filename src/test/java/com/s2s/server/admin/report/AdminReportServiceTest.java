package com.s2s.server.admin.report;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.times;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminReportBatchHandleRequest;
import com.s2s.server.admin.dto.AdminReportPageResponse;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.contact.ContactService;
import com.s2s.server.contact.dto.ReportTicketPage;
import com.s2s.server.contact.dto.ReportTicketRow;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminReportService} 单元测试（[153] B2-5 ④ 举报工单）。
 *
 * <p>守三件事：① RBAC（仅内容审核员/超管，其余 40305 且不触达 contact 服务）；
 * ② 列表透传风险分与默认状态 pending；③ 处理成功后写审计，失败则不写。</p>
 */
class AdminReportServiceTest {

    /** contact 域服务（mock）。 */
    private ContactService contactService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminReportService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        contactService = mock(ContactService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminReportService(contactService, auditLogWriter);
    }

    /**
     * 内容审核员可读队列；状态缺省 pending、分页参数归一。
     *
     * @return void
     */
    @Test
    void auditorListsPendingTickets() {
        ReportTicketRow row = new ReportTicketRow(1L, 9L, "标题", "fraud", 50, "pending", 0, 50,
                LocalDateTime.of(2026, 10, 1, 9, 0));
        when(contactService.listReportsForAdmin(eq("pending"), eq(1), eq(20)))
                .thenReturn(new ReportTicketPage(List.of(row), 1L, 1, 20));

        AdminReportPageResponse response = service.list(OperatorRole.AUDITOR, null, null, null);

        assertThat(response.items()).hasSize(1);
        assertThat(response.items().get(0).riskScore()).isEqualTo(50);
        assertThat(response.pageSize()).isEqualTo(20);
    }

    /**
     * 运营专员/算法运营 → 40305，且不触达 contact 服务。
     *
     * @return void；断言失败即越权可处理举报
     */
    @Test
    void nonAuditorDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.OPERATOR, OperatorRole.ALGO}) {
            assertThatThrownBy(() -> service.list(role, null, null, null))
                    .as("角色 %s 不应可读举报工单", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(contactService, never()).listReportsForAdmin(anyString(), anyInt(), anyInt());
    }

    /**
     * 处理成功 → 调域服务 + 写审计。
     *
     * @return void
     */
    @Test
    void handleWritesAudit() {
        service.handle(OperatorRole.AUDITOR, 5L, 1L, "offline");

        verify(contactService).handleReport(eq(1L), eq(5L), eq(OperatorRole.AUDITOR), eq("offline"));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 域服务抛错（工单已处理/不存在）→ 不写审计（避免「处理成功」的假留痕）。
     *
     * @return void
     */
    @Test
    void handleFailureWritesNoAudit() {
        doThrow(BizException.of(ErrorCode.PARAM_INVALID))
                .when(contactService).handleReport(any(Long.class), any(Long.class),
                        any(OperatorRole.class), anyString());

        assertThatThrownBy(() -> service.handle(OperatorRole.AUDITOR, 5L, 1L, "offline"))
                .isInstanceOf(BizException.class);
        verify(auditLogWriter, never()).write(any());
    }

    /**
     * 批量处理：超上限 → 40001，且一条都不处理（不静默截断）。
     *
     * @return void；断言失败即超量请求可触发无界写入
     */
    @Test
    void batchRejectsOverLimit() {
        List<Long> tooMany = java.util.stream.LongStream
                .rangeClosed(1, com.s2s.server.common.constants.NfrAdmin.BATCH_MAX + 1)
                .boxed()
                .toList();

        assertThatThrownBy(() -> service.handleBatch(OperatorRole.AUDITOR, 5L,
                new AdminReportBatchHandleRequest(tooMany, "offline")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(contactService, never()).handleReport(any(Long.class), any(Long.class),
                any(OperatorRole.class), anyString());
    }

    /**
     * 批量处理：逐条调域服务 + 逐条写审计。
     *
     * @return void
     */
    @Test
    void batchHandlesEachItemAndAuditsEach() {
        service.handleBatch(OperatorRole.AUDITOR, 5L,
                new AdminReportBatchHandleRequest(List.of(1L, 2L, 3L), "offline"));

        verify(contactService).handleReport(eq(1L), eq(5L), eq(OperatorRole.AUDITOR), eq("offline"));
        verify(contactService).handleReport(eq(2L), eq(5L), eq(OperatorRole.AUDITOR), eq("offline"));
        verify(contactService).handleReport(eq(3L), eq(5L), eq(OperatorRole.AUDITOR), eq("offline"));
        verify(auditLogWriter, times(3)).write(any(AuditEntry.class));
    }

    /**
     * RBAC：非内容审核员/超管 → 40305，且不触达 contact 服务。
     *
     * @param role 被测角色
     * @return void
     */
    @org.junit.jupiter.params.ParameterizedTest
    @org.junit.jupiter.params.provider.EnumSource(names = {"OPERATOR", "ALGO"})
    void batchNonAuditorDenied(OperatorRole role) {
        assertThatThrownBy(() -> service.handleBatch(role, 5L,
                new AdminReportBatchHandleRequest(List.of(1L), "offline")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.NO_PERMISSION);
        verify(contactService, never()).handleReport(any(Long.class), any(Long.class),
                any(OperatorRole.class), anyString());
    }
}
