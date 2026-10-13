package com.s2s.server.admin.report;

import com.s2s.server.admin.dto.AdminReportBatchHandleRequest;
import com.s2s.server.admin.dto.AdminReportPageResponse;
import com.s2s.server.contact.ContactService;
import com.s2s.server.contact.dto.ReportTicketPage;
import com.s2s.server.contact.dto.ReportTicketRow;
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
 * 后台举报工单服务（[153] B2-5 ④；PRD §9.10.1 ④、§9.10.3）。
 *
 * <p><b>RBAC</b>：举报工单属「内容审核员」职责（PRD §9.10.1 角色表）——内容审核员与
 * 超级管理员可操作，其余角色一律 {@code 40305}。</p>
 *
 * <p><b>审计</b>：工单处理属 PRD §9.10.1「必留操作」，处理落库与审计<b>同事务</b>。
 * 审计记实际动作（{@code false_report}/{@code offline}）便于事后区分「撤回风险分」
 * 与「下架帖子」两类后果。</p>
 *
 * <p><b>域边界</b>：{@code report} 表由 contact 域的 {@link ContactService} 提供数据操作，
 * 风险分与下架由 post 域的 {@code PostModerationService} 执行
 * （admin 不直连他域 Mapper，编码规范 §4.2）。</p>
 */
@Service
public class AdminReportService {

    /** 审计动作：举报工单处理。 */
    static final String ACTION_REPORT_HANDLE = "report.handle";

    /** 审计目标类型：举报工单。 */
    static final String TARGET_REPORT = "report";

    /** 默认筛选状态：待处理。 */
    private static final String STATUS_PENDING = "pending";

    /** contact 域服务（举报读写）。 */
    private final ContactService contactService;

    /** 审计写入器（唯一写入处）。 */
    private final AuditLogWriter auditLogWriter;

    /**
     * 构造后台举报工单服务。
     *
     * @param contactService contact 域服务
     * @param auditLogWriter 审计写入器
     */
    public AdminReportService(ContactService contactService, AuditLogWriter auditLogWriter) {
        this.contactService = contactService;
        this.auditLogWriter = auditLogWriter;
    }

    /**
     * 分页列出举报工单（按被举报帖子累计风险分降序）。
     *
     * @param callerRole 调用者角色
     * @param status     工单状态（null/空 → pending）
     * @param page       页码（null/小于 1 → 1）
     * @param pageSize   每页条数（null → 默认；超上限截断）
     * @return {@link AdminReportPageResponse} 工单分页
     * @throws BizException 非内容审核员/超管 → 40305
     */
    public AdminReportPageResponse list(OperatorRole callerRole, String status, Integer page,
            Integer pageSize) {
        requireAuditorOrSuper(callerRole);
        String normalizedStatus = (status == null || status.isBlank()) ? STATUS_PENDING : status;
        int normalizedPage = (page == null || page < 1) ? 1 : page;
        int normalizedSize = pageSize == null || pageSize < 1
                ? NfrAdmin.PAGE_SIZE_DEFAULT
                : Math.min(pageSize, NfrAdmin.PAGE_SIZE_MAX);

        ReportTicketPage domainPage =
                contactService.listReportsForAdmin(normalizedStatus, normalizedPage, normalizedSize);
        List<AdminReportPageResponse.Item> items = domainPage.items().stream()
                .map(AdminReportService::toItem)
                .toList();
        return new AdminReportPageResponse(items, domainPage.total(), normalizedPage, normalizedSize);
    }

    /**
     * 处理举报工单（同事务写审计）。
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param reportId   举报 ID
     * @param action     处理动作（{@code false_report}/{@code offline}）
     * @throws BizException 非内容审核员/超管 → 40305；举报不存在 → 41001；
     *                      动作非法或工单已处理 → 40001
     */
    @Transactional
    public void handle(OperatorRole callerRole, Long adminId, long reportId, String action) {
        requireAuditorOrSuper(callerRole);
        contactService.handleReport(reportId, adminId, callerRole, action);
        auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_REPORT_HANDLE,
                TARGET_REPORT, reportId, null,
                String.format("{\"action\":\"%s\"}", action), null));
    }

    /**
     * 批量处理举报工单（PRD §9.10.1 ④「批量处理」；整批同事务）。
     *
     * <p><b>为什么整批同事务</b>：举报处理的两个动作都改帖子状态（回撤风险分 / 审核下架），
     * 部分成功会留下「一半下架一半没下」的中间态——运营无法据此判断下一步，
     * 也不符合「工单闭环」的语义。任一条失败即整批回滚。</p>
     *
     * <p><b>审计逐条写</b>：每条工单的处理都是有后果的独立动作（下架某帖 / 回撤某帖风险分），
     * 合并成一条会让「哪个帖子被下架」在审计里不可读。</p>
     *
     * @param callerRole 调用者角色
     * @param adminId    操作人 ID（审计）
     * @param req        入参（reportIds + action）
     * @throws BizException 非内容审核员/超管 → 40305；条数超上限 → 40001；
     *                      任一条不存在 → 41001；任一条已处理或动作非法 → 40001
     */
    @Transactional
    public void handleBatch(OperatorRole callerRole, Long adminId,
            AdminReportBatchHandleRequest req) {
        requireAuditorOrSuper(callerRole);
        if (req.reportIds().size() > NfrAdmin.BATCH_MAX) {
            // 不静默截断：截断会让运营以为「全处理完了」（上限语义见 NfrAdmin.BATCH_MAX）
            throw BizException.of(ErrorCode.PARAM_INVALID);
        }
        for (Long reportId : req.reportIds()) {
            contactService.handleReport(reportId, adminId, callerRole, req.action());
            auditLogWriter.write(new AuditEntry(adminId, callerRole, ACTION_REPORT_HANDLE,
                    TARGET_REPORT, reportId, null,
                    String.format("{\"action\":\"%s\",\"batch\":true}", req.action()), null));
        }
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
     * 域行 → 出参条目。
     *
     * @param row contact 域工单行
     * @return {@link AdminReportPageResponse.Item} 出参
     */
    private static AdminReportPageResponse.Item toItem(ReportTicketRow row) {
        return new AdminReportPageResponse.Item(
                row.reportId(),
                row.postId(),
                row.postTitle(),
                row.reason(),
                row.weight(),
                row.status(),
                row.isFalseReport(),
                row.riskScore(),
                row.createdAt() == null ? null : row.createdAt().toInstant(ZoneOffset.UTC));
    }
}
