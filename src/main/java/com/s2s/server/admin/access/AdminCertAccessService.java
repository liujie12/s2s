package com.s2s.server.admin.access;

import com.baomidou.mybatisplus.core.conditions.query.QueryWrapper;
import com.s2s.server.admin.dto.AdminCertAccessContentResponse;
import com.s2s.server.admin.dto.AdminCertAccessCreateRequest;
import com.s2s.server.admin.dto.AdminCertAccessPageResponse;
import com.s2s.server.admin.dto.AdminCertAccessReviewRequest;
import com.s2s.server.admin.entity.AdminCertAccessRequestEntity;
import com.s2s.server.admin.mapper.AdminCertAccessRequestMapper;
import com.s2s.server.cert.CertService;
import com.s2s.server.cert.entity.CertEntity;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.LocalDateTime;
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台认证原始信息敏感查看「双人复核」服务（[153] B2-5 §9.10.1；PRD §9.10.1）。
 *
 * <p><b>业务闭环</b>（PRD §9.10.1「查看身份证后 4 位以外的任何认证原始信息，需另一名
 * 管理员在后台确认后方可打开，配合 §4.7 只存哈希的口径」）：
 * 管理员 A {@link #create 发起申请}（pending）→ 管理员 B {@link #review 复核}
 * （通过 / 驳回，<b>B 必须与 A 不同</b>）→ A {@link #openContent 打开}（仅 {@code approved}
 * 可打开；本次打开写审计 {@code cert.sensitive_view}）。</p>
 *
 * <p><b>RBAC</b>：本能力属「内容审核员」职责（认证审核链的下游）——内容审核员与超级管理员
 * 可操作，其余角色 {@code 40305}。发起人≠复核人由服务判定（职责分离）。</p>
 *
 * <p><b>审计</b>：复核（通过/驳回）与打开均属「必留操作」，与各自 DB 写入<b>同事务</b>。
 * 打开动作即 PRD §9.10.1「查看用户脱敏信息」的落点。</p>
 *
 * <p><b>域边界</b>：{@code cert} 表经 cert 域 {@link CertService} 读取（不直连他域 Mapper）；
 * 本域自有 {@code admin_cert_access_request} 表经 {@link AdminCertAccessRequestMapper}。</p>
 */
@Service
public class AdminCertAccessService {

    /** 复核状态：待复核。 */
    static final String STATUS_PENDING = "pending";

    /** 复核状态：已通过。 */
    static final String STATUS_APPROVED = "approved";

    /** 复核状态：已驳回。 */
    static final String STATUS_REJECTED = "rejected";

    /** 审计动作：复核敏感查看申请。 */
    static final String ACTION_ACCESS_REVIEW = "cert.access_review";

    /** 审计动作：打开认证原始信息（PRD §9.10.1「查看用户脱敏信息」必留）。 */
    static final String ACTION_SENSITIVE_VIEW = "cert.sensitive_view";

    /** 审计目标类型：认证记录。 */
    static final String TARGET_CERT = "cert";

    /** 复核申请 Mapper（本域自有）。 */
    private final AdminCertAccessRequestMapper mapper;

    /** cert 域服务（认证存在性校验 + 资质图引用读取）。 */
    private final CertService certService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造敏感查看复核服务。
     *
     * @param mapper         复核申请 Mapper
     * @param certService    cert 域服务
     * @param auditLogWriter 审计写入器
     */
    public AdminCertAccessService(AdminCertAccessRequestMapper mapper, CertService certService,
            AuditLogWriter auditLogWriter) {
        this.mapper = mapper;
        this.certService = certService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 发起一条敏感查看复核申请（落 pending）。
     *
     * @param callerRole 调用者角色
     * @param adminId    发起人 ID（= {@code admin_user.id}）
     * @param req        入参（certId + reason）
     * @throws BizException 非内容审核员/超管 → 40305；认证不存在 → 41001；
     *         同发起人对该认证已有待复核申请 → 40001
     */
    @Transactional
    public void create(OperatorRole callerRole, Long adminId, AdminCertAccessCreateRequest req) {
        requireAuditorOrSuper(callerRole);
        if (certService.findCert(req.certId()) == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (hasPendingDuplicate(req.certId(), adminId)) {
            // 同一发起人对同一条认证的重复申请无意义（复核仍需另一人），挡在入口避免刷队列
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        AdminCertAccessRequestEntity entity = new AdminCertAccessRequestEntity();
        entity.setCertId(req.certId());
        entity.setRequesterId(adminId);
        entity.setReason(req.reason());
        entity.setStatus(STATUS_PENDING);
        mapper.insert(entity);
    }

    /**
     * 分页列出复核申请（按申请时间倒序）。
     *
     * @param callerRole 调用者角色
     * @param status     复核状态筛选（null/空 → 不限）
     * @param page       页码（null/小于 1 → 1）
     * @param pageSize   每页条数（null → 默认；超上限截断）
     * @return {@link AdminCertAccessPageResponse} 列表分页
     * @throws BizException 非内容审核员/超管 → 40305
     */
    public AdminCertAccessPageResponse list(OperatorRole callerRole, String status, Integer page,
            Integer pageSize) {
        requireAuditorOrSuper(callerRole);
        int normalizedPage = (page == null || page < 1) ? 1 : page;
        int normalizedSize = pageSize == null || pageSize < 1
                ? NfrAdmin.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrAdmin.PAGE_SIZE_MAX);

        long total = mapper.countByStatus(status);
        List<AdminCertAccessPageResponse.Item> items = mapper
                .selectPageByStatus(status, (normalizedPage - 1) * normalizedSize, normalizedSize)
                .stream()
                .map(AdminCertAccessService::toItem)
                .toList();
        return new AdminCertAccessPageResponse(items, total, normalizedPage, normalizedSize);
    }

    /**
     * 复核一条申请（通过 / 驳回；同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    复核人 ID（须与发起人不同）
     * @param id         申请 ID
     * @param req        入参（approved + reason）
     * @throws BizException 非内容审核员/超管 → 40305；申请不存在 → 41001；
     *         已复核或不处于待复核 / 复核人=发起人 / 驳回未填理由 → 40001
     */
    @Transactional
    public void review(OperatorRole callerRole, Long adminId, long id,
            AdminCertAccessReviewRequest req) {
        requireAuditorOrSuper(callerRole);
        AdminCertAccessRequestEntity entity = mapper.selectById(id);
        if (entity == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (!STATUS_PENDING.equals(entity.getStatus())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        if (adminId.equals(entity.getRequesterId())) {
            // 双人复核：发起人不得自审（PRD §9.10.1「需另一名管理员确认」）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        boolean approved = Boolean.TRUE.equals(req.approved());
        if (!approved && (req.reason() == null || req.reason().isBlank())) {
            // PRD §9.10.1：驳回强制填写理由
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        AdminCertAccessRequestEntity patch = new AdminCertAccessRequestEntity();
        patch.setId(id);
        patch.setStatus(approved ? STATUS_APPROVED : STATUS_REJECTED);
        patch.setReviewerId(adminId);
        patch.setReviewedAt(LocalDateTime.now());
        mapper.updateById(patch);
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_ACCESS_REVIEW,
                TARGET_CERT, entity.getCertId(), null, null, approved ? null : req.reason()));
    }

    /**
     * 打开认证原始信息（仅发起人本人、且已复核通过；写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    调用人 ID（须为申请发起人）
     * @param id         申请 ID
     * @return {@link AdminCertAccessContentResponse} 认证记录 ID + 资质图引用
     * @throws BizException 非内容审核员/超管或非发起人 → 40305；申请不存在/认证不存在 → 41001；
     *         尚未复核通过 → 40001
     */
    @Transactional
    public AdminCertAccessContentResponse openContent(OperatorRole callerRole, Long adminId, long id) {
        requireAuditorOrSuper(callerRole);
        AdminCertAccessRequestEntity entity = mapper.selectById(id);
        if (entity == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        if (!adminId.equals(entity.getRequesterId())) {
            // 越权统一同码（安全方案 §8.1）：非本人不得打开
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
        if (!STATUS_APPROVED.equals(entity.getStatus())) {
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        CertEntity cert = certService.findCert(entity.getCertId());
        if (cert == null) {
            throw BizException.of(ErrorCode.POST_GONE);
        }
        // 打开即「查看用户脱敏信息」（PRD §9.10.1 必留操作），与本次读取同事务留痕
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_SENSITIVE_VIEW,
                TARGET_CERT, entity.getCertId(), null, null, entity.getReason()));
        return new AdminCertAccessContentResponse(cert.getId(), cert.getOcrImageRef());
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
     * 判定是否已存在「同发起人 + 同认证」的待复核申请（去重，见 {@link #create}）。
     *
     * @param certId      目标认证 ID
     * @param requesterId 发起人 ID
     * @return boolean；存在待复核同条件申请时 {@code true}
     */
    private boolean hasPendingDuplicate(Long certId, Long requesterId) {
        return mapper.selectCount(new QueryWrapper<AdminCertAccessRequestEntity>()
                .eq("cert_id", certId)
                .eq("requester_id", requesterId)
                .eq("status", STATUS_PENDING)) > 0;
    }

    /**
     * 域实体 → 出参条目。
     *
     * @param entity 复核申请实体
     * @return {@link AdminCertAccessPageResponse.Item} 出参
     */
    private static AdminCertAccessPageResponse.Item toItem(AdminCertAccessRequestEntity entity) {
        return new AdminCertAccessPageResponse.Item(
                entity.getId(),
                entity.getCertId(),
                entity.getRequesterId(),
                entity.getReason(),
                entity.getStatus(),
                entity.getReviewerId(),
                entity.getReviewedAt() == null ? null
                        : entity.getReviewedAt().toInstant(ZoneOffset.UTC),
                entity.getCreatedAt() == null ? null
                        : entity.getCreatedAt().toInstant(ZoneOffset.UTC));
    }
}
