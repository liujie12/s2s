package com.s2s.server.admin;

import com.s2s.server.admin.dto.AdminAuditExportResponse;
import com.s2s.server.admin.dto.AdminLoginRequest;
import com.s2s.server.admin.dto.AdminLoginResult;
import com.s2s.server.common.audit.OperatorRole;
import com.s2s.server.common.audit.dto.AuditLogPage;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import java.time.LocalDateTime;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 运营治理后台控制器（[153] B2-5；详设口径见 PRD §9.10.1）。
 *
 * <p>承载后台 HTTP 入口：{@code POST /admin/login}（登录，匿名）、
 * {@code GET /admin/audit-logs}（审计查询，仅超级管理员）。其余后台端点
 * （7 页业务 API）随后续批次追加。</p>
 *
 * <p>鉴权：类内除 {@code /admin/login} 外的路径由 {@link AdminInterceptor} 统一拦截
 * （见 {@code WebCrosscutConfig} 注册），登录态从 {@link AdminContext} 读取。
 * 越权（角色不足）由服务层抛 {@code 40305}。</p>
 */
@RestController
@RequestMapping("/admin")
public class AdminController {

    /** 后台登录服务。 */
    private final AdminAuthService adminAuthService;

    /** 后台审计查询服务。 */
    private final AdminAuditService adminAuditService;

    /**
     * 构造后台控制器。
     *
     * @param adminAuthService  后台登录服务
     * @param adminAuditService 后台审计查询服务
     */
    public AdminController(AdminAuthService adminAuthService, AdminAuditService adminAuditService) {
        this.adminAuthService = adminAuthService;
        this.adminAuditService = adminAuditService;
    }

    /**
     * 后台登录（{@code POST /admin/login}）。
     *
     * @param request 登录入参（username/password，经 @Valid 校验）
     * @return {@link AdminLoginResult} 后台 Token + 角色
     */
    @PostMapping("/login")
    public AdminLoginResult login(@Valid @RequestBody AdminLoginRequest request) {
        return adminAuthService.login(request.username(), request.password());
    }

    /**
     * 审计留痕查询（{@code GET /admin/audit-logs}；仅超级管理员）。
     *
     * @param http         当前 HTTP 请求（取后台鉴权上下文）
     * @param operatorId   操作人过滤（可选）
     * @param operatorRole 角色过滤（可选；取 {@code OperatorRole#dbValue()}）
     * @param action       动作过滤（可选）
     * @param targetType   目标类型过滤（可选）
     * @param targetId     目标 ID 过滤（可选）
     * @param from         起始时间（可选，ISO-8601）
     * @param to           截止时间（可选，ISO-8601）
     * @param page         页码（可选，默认 1）
     * @param pageSize     每页条数（可选，默认 {@code NfrAdmin.AUDIT_PAGE_SIZE_DEFAULT}）
     * @return {@link AuditLogPage} 分页结果
     */
    @GetMapping("/audit-logs")
    public AuditLogPage auditLogs(HttpServletRequest http,
            @RequestParam(name = "operator_id", required = false) Long operatorId,
            @RequestParam(name = "operator_role", required = false) String operatorRole,
            @RequestParam(required = false) String action,
            @RequestParam(name = "target_type", required = false) String targetType,
            @RequestParam(name = "target_id", required = false) Long targetId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
                    LocalDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
                    LocalDateTime to,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        OperatorRole callerRole = AdminContext.currentRole(http);
        return adminAuditService.queryAuditLogs(callerRole, operatorId, operatorRole, action,
                targetType, targetId, from, to, page, pageSize);
    }

    /**
     * 审计留痕导出为 CSV（{@code GET /admin/audit-logs/export}；仅超级管理员）。
     *
     * <p>过滤维度与 {@link #auditLogs} 一致；CSV 文本经统一响应信封承载
     * （见 {@link AdminAuditExportResponse} 类注释：为何不直出 {@code text/csv}）。
     * 「导出需二次确认」（PRD §9.10.1）由前端在调到本端点前完成。</p>
     *
     * @param http         当前请求（取后台角色）
     * @param operatorId   操作人过滤（可选）
     * @param operatorRole 角色过滤（可选）
     * @param action       动作过滤（可选）
     * @param targetType   目标类型过滤（可选）
     * @param targetId     目标 ID 过滤（可选）
     * @param from         起始时间（可选，ISO-8601）
     * @param to           截止时间（可选，ISO-8601）
     * @return {@link AdminAuditExportResponse} CSV 文本 + 文件名 + 实际行数
     */
    @GetMapping("/audit-logs/export")
    public AdminAuditExportResponse exportAuditLogs(HttpServletRequest http,
            @RequestParam(name = "operator_id", required = false) Long operatorId,
            @RequestParam(name = "operator_role", required = false) String operatorRole,
            @RequestParam(required = false) String action,
            @RequestParam(name = "target_type", required = false) String targetType,
            @RequestParam(name = "target_id", required = false) Long targetId,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
                    LocalDateTime from,
            @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE_TIME)
                    LocalDateTime to) {
        OperatorRole callerRole = AdminContext.currentRole(http);
        return adminAuditService.exportCsv(callerRole, operatorId, operatorRole, action,
                targetType, targetId, from, to);
    }
}
