package com.s2s.server.admin;

import com.s2s.server.admin.dto.AdminAuditExportResponse;
import com.s2s.server.common.audit.AuditLogQueryService;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.audit.dto.AuditLogFilter;
import com.s2s.server.common.audit.dto.AuditLogItem;
import com.s2s.server.common.audit.dto.AuditLogPage;
import com.s2s.server.common.constants.NfrAdmin;
import com.s2s.server.common.error.BizException;
import com.s2s.server.common.error.ErrorCode;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import org.springframework.stereotype.Service;

/**
 * 后台审计查询服务（[153] B2-5；{@code GET /admin/audit-logs} + {@code GET /admin/audit-logs/export}）。
 *
 * <p><b>RBAC（PRD §9.10.1 / 安设 §8.2）</b>：审计留痕**仅超级管理员可查/可导出**；
 * 其余角色（内容审核员 / 运营专员 / 算法运营）一律拒绝，越权统一返 {@code 40305}
 * （NO_PERMISSION）——「一切越权必须返同一个码」是安全方案 §8.1 的硬口径
 * （按资源类型各返不同码会成为可枚举的信息通道）。</p>
 *
 * <p>权限判定在本服务、数据访问在 {@code AuditLogQueryService}（common 域）——
 * 分离使「换个调用方就绕过权限」不可能发生（权限随调用入口走）。</p>
 */
@Service
public class AdminAuditService {

    /** 导出文件名（固定名 + 前端可加时间戳；服务端不拼时钟避免与客户端展示口径分叉）。 */
    private static final String EXPORT_FILE_NAME = "audit-logs.csv";

    /** 导出内容类型（前端据此设置保存类型）。 */
    private static final String EXPORT_CONTENT_TYPE = "text/csv; charset=UTF-8";

    /** CSV 表头（列序与 {@link #appendCsvRow} 严格一致）。 */
    private static final String CSV_HEADER =
            "id,operator_id,operator_role,action,target_type,target_id,"
                    + "before_value,after_value,reason,created_at";

    /** 审计查询服务（common 域，读路径唯一实现处）。 */
    private final AuditLogQueryService auditLogQueryService;

    /**
     * 构造后台审计查询服务。
     *
     * @param auditLogQueryService 审计查询服务
     */
    public AdminAuditService(AuditLogQueryService auditLogQueryService) {
        this.auditLogQueryService = auditLogQueryService;
    }

    /**
     * 查询审计留痕（仅超级管理员）。
     *
     * @param callerRole   调用者角色（来自 {@link AdminContext}）
     * @param operatorId   操作人过滤（null = 不限）
     * @param operatorRole 角色过滤（null = 不限；[153] 起支持按四角色筛选）
     * @param action       动作过滤（null = 不限）
     * @param targetType   目标类型过滤（null = 不限）
     * @param targetId     目标 ID 过滤（null = 不限）
     * @param from         起始时间（含；null = 不限）
     * @param to           截止时间（含；null = 不限）
     * @param page         页码（null/小于 1 归一为 1）
     * @param pageSize     每页条数（null 取默认；超过上限截断至上限）
     * @return {@link AuditLogPage} 分页结果
     * @throws BizException 非超级管理员 → 40305
     */
    public AuditLogPage queryAuditLogs(OperatorRole callerRole, Long operatorId,
            String operatorRole, String action, String targetType, Long targetId,
            LocalDateTime from, LocalDateTime to, Integer page, Integer pageSize) {
        requireSuper(callerRole);
        int normalizedPage = (page == null || page < 1) ? 1 : page;
        int normalizedSize = normalizePageSize(pageSize);
        AuditLogFilter filter = buildFilter(operatorId, operatorRole, action, targetType, targetId,
                from, to, normalizedSize, (normalizedPage - 1) * normalizedSize);
        return auditLogQueryService.query(filter, normalizedPage, normalizedSize);
    }

    /**
     * 导出审计留痕为 CSV（仅超级管理员；PRD §9.10.1「导出需二次确认」）。
     *
     * <p>过滤维度与 {@link #queryAuditLogs} 完全一致（复用 {@link #buildFilter}），
     * 单次导出上限 {@link NfrAdmin#AUDIT_EXPORT_MAX_ROWS}——超上限只导出前 N 行，
     * 由调用方按需收窄筛选（见该常量注释）。</p>
     *
     * @param callerRole   调用者角色
     * @param operatorId   操作人过滤（null = 不限）
     * @param operatorRole 角色过滤（null = 不限）
     * @param action       动作过滤（null = 不限）
     * @param targetType   目标类型过滤（null = 不限）
     * @param targetId     目标 ID 过滤（null = 不限）
     * @param from         起始时间（含；null = 不限）
     * @param to           截止时间（含；null = 不限）
     * @return {@link AdminAuditExportResponse} CSV 文本 + 文件名 + 实际行数
     * @throws BizException 非超级管理员 → 40305
     */
    public AdminAuditExportResponse exportCsv(OperatorRole callerRole, Long operatorId,
            String operatorRole, String action, String targetType, Long targetId,
            LocalDateTime from, LocalDateTime to) {
        requireSuper(callerRole);
        int cap = NfrAdmin.AUDIT_EXPORT_MAX_ROWS;
        AuditLogFilter filter = buildFilter(operatorId, operatorRole, action, targetType, targetId,
                from, to, cap, 0);
        List<AuditLogItem> items = auditLogQueryService.query(filter, 1, cap).items();
        return new AdminAuditExportResponse(EXPORT_FILE_NAME, EXPORT_CONTENT_TYPE,
                toCsv(items), items.size());
    }

    /**
     * RBAC：仅超级管理员。
     *
     * @param callerRole 调用者角色
     * @throws BizException 不满足 → 40305
     */
    private void requireSuper(OperatorRole callerRole) {
        if (callerRole != OperatorRole.SUPER_ADMIN) {
            throw BizException.of(ErrorCode.NO_PERMISSION);
        }
    }

    /**
     * 组装审计过滤条件（查询与导出共用，保证两处筛选口径天然一致）。
     *
     * @param operatorId   操作人过滤（null = 不限）
     * @param operatorRole 角色过滤（null = 不限）
     * @param action       动作过滤（null = 不限）
     * @param targetType   目标类型过滤（null = 不限）
     * @param targetId     目标 ID 过滤（null = 不限）
     * @param from         起始时间（含；null = 不限）
     * @param to           截止时间（含；null = 不限）
     * @param limit        每页/本次条数（LIMIT）
     * @param offset       偏移量（OFFSET）
     * @return {@link AuditLogFilter} 过滤条件
     */
    private static AuditLogFilter buildFilter(Long operatorId, String operatorRole, String action,
            String targetType, Long targetId, LocalDateTime from, LocalDateTime to,
            int limit, int offset) {
        AuditLogFilter filter = new AuditLogFilter();
        filter.setOperatorId(operatorId);
        filter.setOperatorRole(operatorRole);
        filter.setAction(action);
        filter.setTargetType(targetType);
        filter.setTargetId(targetId);
        filter.setFrom(from);
        filter.setTo(to);
        filter.setLimit(limit);
        filter.setOffset(offset);
        return filter;
    }

    /**
     * 归一每页条数：默认 {@link NfrAdmin#PAGE_SIZE_DEFAULT}，上限
     * {@link NfrAdmin#PAGE_SIZE_MAX}（防一次拉全表）。
     *
     * @param pageSize 原始每页条数（可空）
     * @return int 归一后的每页条数
     */
    private int normalizePageSize(Integer pageSize) {
        if (pageSize == null || pageSize < 1) {
            return NfrAdmin.PAGE_SIZE_DEFAULT;
        }
        return Math.min(pageSize, NfrAdmin.PAGE_SIZE_MAX);
    }

    /**
     * 把审计行拼成 CSV 文本（含表头，行尾 {@code \n}）。
     *
     * @param items 审计行
     * @return {@link String} CSV 文本
     */
    private static String toCsv(List<AuditLogItem> items) {
        StringBuilder builder = new StringBuilder(CSV_HEADER).append('\n');
        for (AuditLogItem item : items) {
            appendCsvRow(builder, item);
        }
        return builder.toString();
    }

    /**
     * 追加一行 CSV（列序与 {@link #CSV_HEADER} 严格一致）。
     *
     * @param builder 目标缓冲
     * @param item    审计行
     */
    private static void appendCsvRow(StringBuilder builder, AuditLogItem item) {
        builder.append(item.id() == null ? "" : item.id()).append(',')
                .append(item.operatorId() == null ? "" : item.operatorId()).append(',')
                .append(csvField(item.operatorRole())).append(',')
                .append(csvField(item.action())).append(',')
                .append(csvField(item.targetType())).append(',')
                .append(item.targetId() == null ? "" : item.targetId()).append(',')
                .append(csvField(item.beforeValue())).append(',')
                .append(csvField(item.afterValue())).append(',')
                .append(csvField(item.reason())).append(',')
                .append(item.createdAt() == null
                        ? "" : DateTimeFormatter.ISO_INSTANT.format(item.createdAt()))
                .append('\n');
    }

    /**
     * CSV 字段转义（RFC 4180）：含逗号/双引号/换行时用双引号包裹，内部双引号翻倍；
     * {@code null} 视为空串。
     *
     * @param value 原始字段值
     * @return {@link String} 转义后的字段
     */
    private static String csvField(String value) {
        if (value == null) {
            return "";
        }
        if (value.indexOf(',') < 0 && value.indexOf('"') < 0
                && value.indexOf('\n') < 0 && value.indexOf('\r') < 0) {
            return value;
        }
        return '"' + value.replace("\"", "\"\"") + '"';
    }
}
