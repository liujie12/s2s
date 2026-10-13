package com.s2s.server.admin.access;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.s2s.server.admin.dto.AdminCertAccessContentResponse;
import com.s2s.server.admin.dto.AdminCertAccessCreateRequest;
import com.s2s.server.admin.dto.AdminCertAccessReviewRequest;
import com.s2s.server.admin.entity.AdminCertAccessRequestEntity;
import com.s2s.server.admin.mapper.AdminCertAccessRequestMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

/**
 * {@link AdminCertAccessService} 单元测试（[153] B2-5 §9.10.1；PRD §9.10.1 敏感查看双人复核）。
 *
 * <p>守五件事：① RBAC（仅内容审核员/超管）；② 发起前置（认证不存在 41001 / 重复待复核 40001）；
 * ③ 双人复核（发起人不得自审）；④ 驳回强制理由、非待复核不可复核；
 * ⑤ 打开仅限发起人 + 已通过，且每次打开写审计。</p>
 */
class AdminCertAccessServiceTest {

    /** 复核申请 Mapper（mock）。 */
    private AdminCertAccessRequestMapper mapper;

    /** cert 域服务（mock）。 */
    private CertService certService;

    /** 审计写入器（mock）。 */
    private AuditLogWriter auditLogWriter;

    /** 被测服务。 */
    private AdminCertAccessService service;

    /**
     * 装配被测服务与 mock。
     */
    @BeforeEach
    void setUp() {
        mapper = mock(AdminCertAccessRequestMapper.class);
        certService = mock(CertService.class);
        auditLogWriter = mock(AuditLogWriter.class);
        service = new AdminCertAccessService(mapper, certService, auditLogWriter);
    }

    /**
     * 发起：认证存在且无重复 → 落 pending 行。
     *
     * @return void
     */
    @Test
    void createInsertsPendingWhenCertExists() {
        when(certService.findCert(9L)).thenReturn(cert(9L));
        when(mapper.selectCount(any())).thenReturn(0L);

        service.create(OperatorRole.AUDITOR, 5L, new AdminCertAccessCreateRequest(9L, "核对资质真伪"));

        verify(mapper).insert(any(AdminCertAccessRequestEntity.class));
    }

    /**
     * 发起：认证不存在 → 41001。
     *
     * @return void
     */
    @Test
    void createRejectsMissingCert() {
        when(certService.findCert(9L)).thenReturn(null);

        assertThatThrownBy(() -> service.create(OperatorRole.AUDITOR, 5L,
                new AdminCertAccessCreateRequest(9L, "核对")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.POST_GONE);
        verify(mapper, never()).insert(any(AdminCertAccessRequestEntity.class));
    }

    /**
     * 发起：同发起人已有待复核申请 → 40001。
     *
     * @return void
     */
    @Test
    void createRejectsDuplicatePending() {
        when(certService.findCert(9L)).thenReturn(cert(9L));
        when(mapper.selectCount(any())).thenReturn(1L);

        assertThatThrownBy(() -> service.create(OperatorRole.AUDITOR, 5L,
                new AdminCertAccessCreateRequest(9L, "核对")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(mapper, never()).insert(any(AdminCertAccessRequestEntity.class));
    }

    /**
     * 发起：非内容审核员/超管 → 40305，且不触达 cert 服务。
     *
     * @return void
     */
    @Test
    void createDeniedForNonAuditor() {
        assertThatThrownBy(() -> service.create(OperatorRole.OPERATOR, 5L,
                new AdminCertAccessCreateRequest(9L, "核对")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.NO_PERMISSION);
        verify(certService, never()).findCert(anyLong());
    }

    /**
     * 复核通过：另一名管理员批准 → 置 approved + 写审计。
     *
     * @return void
     */
    @Test
    void reviewApprovesByOtherAdminAndAudits() {
        when(mapper.selectById(1L)).thenReturn(pendingRow(1L, 9L, 5L));

        service.review(OperatorRole.AUDITOR, 6L, 1L,
                new AdminCertAccessReviewRequest(true, null));

        verify(mapper).updateById(any(AdminCertAccessRequestEntity.class));
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 复核：发起人自审 → 40001，不写库不写审计。
     *
     * @return void；断言失败即双人复核被绕过
     */
    @Test
    void reviewRejectsSelfApproval() {
        when(mapper.selectById(1L)).thenReturn(pendingRow(1L, 9L, 5L));

        assertThatThrownBy(() -> service.review(OperatorRole.AUDITOR, 5L, 1L,
                new AdminCertAccessReviewRequest(true, null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(mapper, never()).updateById(any(AdminCertAccessRequestEntity.class));
        verify(auditLogWriter, never()).write(any());
    }

    /**
     * 复核：驳回未填理由 → 40001；已复核 → 40001。
     *
     * @return void
     */
    @Test
    void reviewValidatesReasonAndState() {
        when(mapper.selectById(1L)).thenReturn(pendingRow(1L, 9L, 5L));
        assertThatThrownBy(() -> service.review(OperatorRole.AUDITOR, 6L, 1L,
                new AdminCertAccessReviewRequest(false, "  ")))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);

        AdminCertAccessRequestEntity approved = pendingRow(2L, 9L, 5L);
        approved.setStatus(AdminCertAccessService.STATUS_APPROVED);
        when(mapper.selectById(2L)).thenReturn(approved);
        assertThatThrownBy(() -> service.review(OperatorRole.AUDITOR, 6L, 2L,
                new AdminCertAccessReviewRequest(true, null)))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
    }

    /**
     * 打开：发起人本人 + 已通过 → 返回资质图引用 + 写审计。
     *
     * @return void；断言失败即「查看用户脱敏信息」未留痕
     */
    @Test
    void openContentReturnsMaterialAndAudits() {
        AdminCertAccessRequestEntity approved = pendingRow(1L, 9L, 5L);
        approved.setStatus(AdminCertAccessService.STATUS_APPROVED);
        when(mapper.selectById(1L)).thenReturn(approved);
        when(certService.findCert(9L)).thenReturn(cert(9L));

        AdminCertAccessContentResponse response =
                service.openContent(OperatorRole.AUDITOR, 5L, 1L);

        assertThat(response.certId()).isEqualTo(9L);
        assertThat(response.ocrImageRef()).isEqualTo("media-1");
        verify(auditLogWriter).write(any(AuditEntry.class));
    }

    /**
     * 打开：非发起人 → 40305；未通过 → 40001。
     *
     * @return void
     */
    @Test
    void openContentRejectsNonRequesterAndNotApproved() {
        when(mapper.selectById(1L)).thenReturn(pendingRow(1L, 9L, 5L));
        assertThatThrownBy(() -> service.openContent(OperatorRole.AUDITOR, 6L, 1L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.NO_PERMISSION);

        assertThatThrownBy(() -> service.openContent(OperatorRole.AUDITOR, 5L, 1L))
                .isInstanceOf(BizException.class)
                .extracting(e -> ((BizException) e).getErrorCode())
                .isEqualTo(ErrorCode.PARAM_INVALID);
        verify(certService, never()).findCert(anyLong());
    }

    /**
     * 造一条待复核申请行。
     *
     * @param id          申请 ID
     * @param certId      认证 ID
     * @param requesterId 发起人 ID
     * @return {@link AdminCertAccessRequestEntity} 待复核行
     */
    private static AdminCertAccessRequestEntity pendingRow(long id, long certId, long requesterId) {
        AdminCertAccessRequestEntity entity = new AdminCertAccessRequestEntity();
        entity.setId(id);
        entity.setCertId(certId);
        entity.setRequesterId(requesterId);
        entity.setReason("核对资质真伪");
        entity.setStatus(AdminCertAccessService.STATUS_PENDING);
        return entity;
    }

    /**
     * 造一条认证记录。
     *
     * @param id 认证 ID
     * @return {@link CertEntity} 认证记录（含资质图引用）
     */
    private static CertEntity cert(long id) {
        CertEntity entity = new CertEntity();
        entity.setId(id);
        entity.setOcrImageRef("media-1");
        return entity;
    }
}
