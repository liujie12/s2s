package com.s2s.server.admin.cert;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.CertReviewPageResponse;
import com.s2s.server.admin.dto.CertReviewRequest;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertReviewPage;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.LocalDateTime;
import java.util.List;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminCertService} 单元测试（[153] B2-5 ⑤ 认证审核队列）。
 *
 * <p>守四件事：① RBAC（仅内容审核员/超管，其余 40305 且不触达 cert 服务）；
 * ② 驳回必须带理由（否则 40001）；③ 认证不存在 → 41001；④ 通过/驳回各写对应审计动作。</p>
 */
class AdminCertServiceTest {

    /** cert 域服务（mock）。 */
    private CertService certService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminCertService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        certService = mock(CertService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminCertService(certService, auditLogWriter);
    }

    /**
     * 内容审核员可读队列；状态缺省为 pending。
     *
     * @return void；断言失败即审核员看不到队列
     */
    @Test
    void auditorCanListPendingQueue() {
        when(certService.listForReview(eq("pending"), eq(1), eq(20)))
                .thenReturn(new CertReviewPage(List.of(certEntity()), 1L, 1, 20));

        CertReviewPageResponse response =
                service.listForReview(OperatorRole.AUDITOR, null, null, null);

        assertThat(response.total()).isEqualTo(1L);
        assertThat(response.items()).hasSize(1);
        assertThat(response.items().get(0).certId()).isEqualTo(9L);
    }

    /**
     * 运营专员/算法运营/普通用户 → 40305，且不触达 cert 服务。
     *
     * @return void；断言失败即越权可审认证
     */
    @Test
    void nonAuditorDenied() {
        for (OperatorRole role : new OperatorRole[] {OperatorRole.OPERATOR, OperatorRole.ALGO,
                OperatorRole.USER}) {
            assertThatThrownBy(() -> service.listForReview(role, null, null, null))
                    .as("角色 %s 不应可审认证", role)
                    .isInstanceOf(BizException.class)
                    .extracting(e -> ((BizException) e).getErrorCode())
                    .isEqualTo(ErrorCode.NO_PERMISSION);
        }
        verify(certService, never()).listForReview(any(), org.mockito.ArgumentMatchers.anyInt(),
                org.mockito.ArgumentMatchers.anyInt());
    }

    /**
     * 驳回未填理由 → 40001（PRD §9.10.1 强制填写）。
     *
     * @return void
     */
    @Test
    void rejectWithoutReasonRejected() {
        assertThatThrownBy(() -> service.review(OperatorRole.AUDITOR, 1L, 9L,
                new CertReviewRequest(false, "  ")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(certService, never()).markReviewed(anyLong(), anyBoolean(), any());
    }

    /**
     * 认证不存在 → 41001，且不落审核结论。
     *
     * @return void
     */
    @Test
    void missingCertRejected() {
        when(certService.findCert(999L)).thenReturn(null);

        assertThatThrownBy(() -> service.review(OperatorRole.AUDITOR, 1L, 999L,
                new CertReviewRequest(true, null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(certService, never()).markReviewed(anyLong(), anyBoolean(), any());
    }

    /**
     * 通过 → 落结论 + 写 cert.approve 审计。
     *
     * @return void
     */
    @Test
    void approveWritesDecisionAndAudit() {
        when(certService.findCert(9L)).thenReturn(certEntity());

        service.review(OperatorRole.AUDITOR, 5L, 9L, new CertReviewRequest(true, null));

        verify(certService).markReviewed(eq(9L), eq(true), any());
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 驳回 → 落结论 + 写 cert.reject 审计（带理由）。
     *
     * @return void
     */
    @Test
    void rejectWritesDecisionAndAudit() {
        when(certService.findCert(9L)).thenReturn(certEntity());

        service.review(OperatorRole.SUPER_ADMIN, 5L, 9L, new CertReviewRequest(false, "证照模糊"));

        verify(certService).markReviewed(eq(9L), eq(false), eq("证照模糊"));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 构造 cert 行。
     *
     * @return {@link CertEntity} 认证记录
     */
    private CertEntity certEntity() {
        CertEntity entity = new CertEntity();
        entity.setId(9L);
        entity.setUserId(100L);
        entity.setCertType("personal_qualification");
        entity.setStatus("pending");
        entity.setSubmittedAt(LocalDateTime.of(2026, 10, 1, 9, 0));
        return entity;
    }
}
