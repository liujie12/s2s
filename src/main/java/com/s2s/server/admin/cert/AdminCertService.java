package com.s2s.server.admin.cert;

import com.s2s.server.admin.dto.CertReviewPageResponse;
import com.s2s.server.admin.dto.CertReviewRequest;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.dto.CertReviewPage;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台认证审核队列服务（[153] B2-5 ⑤；PRD §9.10.1 ⑤、§4.7）。
 *
 * <p><b>RBAC</b>：认证审核属「内容审核员」职责（PRD §9.10.1 角色表）——内容审核员与
 * 超级管理员可操作，其余角色一律 {@code 40305}。</p>
 *
 * <p><b>审计</b>：认证通过/驳回属 PRD §9.10.1「必留操作」（含驳回强制填写理由）。
 * 审核结论落库与审计写入<b>同事务</b>，审计归属真实操作人（adminId + 后台角色）。</p>
 *
 * <p><b>域边界</b>：{@code cert} 表由 cert 域的 {@link CertService} 提供数据操作
 * （{@code admin} 不直连 cert 域 Mapper，编码规范 §4.2）。</p>
 */
@Service
public class AdminCertService {

    /** 审计动作：认证通过。 */
    static final String ACTION_CERT_APPROVE = "cert.approve";

    /** 审计动作：认证驳回。 */
    static final String ACTION_CERT_REJECT = "cert.reject";

    /** 审计目标类型：认证记录。 */
    static final String TARGET_CERT = "cert";

    /** 审核队列默认状态 = 审核中。 */
    private static final String STATUS_PENDING = "pending";

    /** 认证服务（cert 域 service 接口）。 */
    private final CertService certService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台认证审核服务。
     *
     * @param certService    cert 域服务
     * @param auditLogWriter 审计写入器
     */
    public AdminCertService(CertService certService, AuditLogWriter auditLogWriter) {
        this.certService = certService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 分页列出认证审核队列（按提交时间升序）。
     *
     * @param callerRole 调用者角色
     * @param status     认证状态（null/空 → pending）
     * @param page       页码（null/小于 1 → 1）
     * @param pageSize   每页条数（null → 默认；超上限截断）
     * @return {@link CertReviewPageResponse} 队列分页
     * @throws BizException 非内容审核员/超管 → 40305
     */
    public CertReviewPageResponse listForReview(OperatorRole callerRole, String status,
            Integer page, Integer pageSize) {
        requireAuditorOrSuper(callerRole);
        String normalizedStatus = (status == null || status.isBlank()) ? STATUS_PENDING : status;
        int normalizedPage = (page == null || page < 1) ? 1 : page;
        int normalizedSize = pageSize == null || pageSize < 1
                ? NfrAdmin.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrAdmin.PAGE_SIZE_MAX);

        CertReviewPage domainPage =
                certService.listForReview(normalizedStatus, normalizedPage, normalizedSize);
        List<CertReviewPageResponse.Item> items = domainPage.items().stream()
                .map(AdminCertService::toItem)
                .toList();
        return new CertReviewPageResponse(items, domainPage.total(), normalizedPage, normalizedSize);
    }

    /**
     * 落审核结论（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param certId     认证 ID
     * @param req        入参（approved + rejectReason）
     * @throws BizException 非内容审核员/超管 → 40305；认证不存在 → 41001；驳回未填理由 → 40001
     */
    @Transactional
    public void review(OperatorRole callerRole, Long adminId, long certId, CertReviewRequest req) {
        requireAuditorOrSuper(callerRole);
        boolean approved = Boolean.TRUE.equals(req.approved());
        if (!approved && (req.rejectReason() == null || req.rejectReason().isBlank())) {
            // PRD §9.10.1：驳回与下架强制填写理由
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        CertEntity cert = certService.findCert(certId);
        if (cert == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        certService.markReviewed(certId, approved, req.rejectReason());
        auditLogWriter.write(new AuditEntry(adminId, callerRole,
                approved ? ACTION_CERT_APPROVE : ACTION_CERT_REJECT,
                TARGET_CERT, certId, null, null, approved ? null : req.rejectReason()));
    }

    /**
     * RBAC：内容审核员或超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireAuditorOrSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.AUDITOR && callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }

    /**
     * 域实体 → 出参条目。
     *
     * @param entity cert 实体
     * @return {@link CertReviewPageResponse.Item} 出参
     */
    private static CertReviewPageResponse.Item toItem(CertEntity entity) {
        return new CertReviewPageResponse.Item(
                entity.getId(),
                entity.getUserId(),
                entity.getCertType(),
                entity.getStatus(),
                entity.getSubmittedAt() == null ? null
                        : entity.getSubmittedAt().toInstant(ZoneOffset.UTC));
    }
}
