package com.s2s.server.admin.followup;

import com.s2s.server.admin.dto.AdminFollowUpPageResponse;
import com.s2s.server.common.audit.AuditEntry;
import com.s2s.server.common.audit.AuditLogWriter;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import com.s2s.server.ops.OpsFollowUpService;
import com.s2s.server.ops.dto.FollowUpPage;
import com.s2s.server.ops.entity.OpsFollowUpEntity;
import java.time.ZoneOffset;
import java.util.List;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

/**
 * 后台待运营跟进队列服务（[153] B2-5 ⑥；PRD §6.4.4）。
 *
 * <p><b>RBAC</b>：跟进队列属「运营专员」职责（PRD §9.10.1 角色表）——运营专员与
 * 超级管理员可操作，其余角色一律 {@code 40305}。</p>
 *
 * <p><b>审计</b>：跟进处理属「必留操作」，落库与审计<b>同事务</b>。</p>
 *
 * <p><b>域边界</b>：队列由 {@code ops} 域承载（写入方是 map 域的空圈检索），
 * 后台经 {@link OpsFollowUpService} 取数与处理（admin 不直连他域 Mapper，编码规范 §4.2）。</p>
 */
@Service
public class AdminFollowUpService {

    /** 审计动作：跟进队列处理。 */
    static final String ACTION_FOLLOW_UP_HANDLE = "followup.handle";

    /** 审计目标类型：跟进队列条目。 */
    static final String TARGET_FOLLOW_UP = "ops_follow_up";

    /** 默认筛选状态：待跟进。 */
    private static final String STATUS_PENDING = OpsFollowUpService.STATUS_PENDING;

    /** ops 域队列服务。 */
    private final OpsFollowUpService opsFollowUpService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台跟进队列服务。
     *
     * @param opsFollowUpService ops 域队列服务
     * @param auditLogWriter     审计写入器
     */
    public AdminFollowUpService(OpsFollowUpService opsFollowUpService,
            AuditLogWriter auditLogWriter) {
        this.opsFollowUpService = opsFollowUpService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 分页列出跟进队列。
     *
     * @param callerRole 调用者角色
     * @param status     状态筛选（null/空 → pending）
     * @param page       页码（null/小于 1 → 1）
     * @param pageSize   每页条数（null → 默认；超上限截断）
     * @return {@link AdminFollowUpPageResponse} 队列分页
     * @throws BizException 非运营专员/超管 → 40305
     */
    public AdminFollowUpPageResponse list(OperatorRole callerRole, String status, Integer page,
            Integer pageSize) {
        requireOperatorOrSuper(callerRole);
        String normalizedStatus = (status == null || status.isBlank()) ? STATUS_PENDING : status;
        int normalizedPage = (page == null || page < 1) ? 1 : page;
        int normalizedSize = pageSize == null || pageSize < 1
                ? NfrAdmin.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrAdmin.PAGE_SIZE_MAX);

        FollowUpPage domainPage =
                opsFollowUpService.list(normalizedStatus, normalizedPage, normalizedSize);
        List<AdminFollowUpPageResponse.Item> items = domainPage.items().stream()
                .map(AdminFollowUpService::toItem)
                .toList();
        return new AdminFollowUpPageResponse(items, domainPage.total(), normalizedPage,
                normalizedSize);
    }

    /**
     * 处理（跟进）一条队列条目（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param id         条目 ID
     * @param remark     处理备注（可空）
     * @throws BizException 非运营专员/超管 → 40305；条目不存在 → 41001；已处理 → 40001
     */
    @Transactional
    public void handle(OperatorRole callerRole, Long adminId, long id, String remark) {
        requireOperatorOrSuper(callerRole);
        opsFollowUpService.handle(id, adminId, remark);
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_FOLLOW_UP_HANDLE,
                TARGET_FOLLOW_UP, id, null, null, remark));
    }

    /**
     * RBAC：运营专员或超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireOperatorOrSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.OPERATOR && callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }

    /**
     * 域实体 → 出参条目。
     *
     * @param entity 队列条目
     * @return {@link AdminFollowUpPageResponse.Item} 出参
     */
    private static AdminFollowUpPageResponse.Item toItem(OpsFollowUpEntity entity) {
        return new AdminFollowUpPageResponse.Item(
                entity.getId(),
                entity.getUserId(),
                entity.getKeyword(),
                entity.getL2CategoryId(),
                entity.getGridId(),
                entity.getStatus(),
                entity.getTriggeredAt() == null ? null
                        : entity.getTriggeredAt().toInstant(ZoneOffset.UTC));
    }
}
