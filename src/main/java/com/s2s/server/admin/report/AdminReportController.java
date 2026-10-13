package com.s2s.server.admin.report;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminReportBatchHandleRequest;
import com.s2s.server.admin.dto.AdminReportHandleRequest;
import com.s2s.server.admin.dto.AdminReportPageResponse;
import com.s2s.server.common.audit.OperatorRole;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * 后台举报工单控制器（[153] B2-5 ④）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminReportService} 判定（内容审核员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/reports")
public class AdminReportController {

    /** 后台举报工单服务。 */
    private final AdminReportService adminReportService;

    /**
     * 构造后台举报工单控制器。
     *
     * @param adminReportService 后台举报工单服务
     */
    public AdminReportController(AdminReportService adminReportService) {
        this.adminReportService = adminReportService;
    }

    /**
     * 举报工单队列（{@code GET /admin/reports}）。
     *
     * @param http     当前请求（取后台角色）
     * @param status   状态筛选（可选，默认 pending）
     * @param page     页码（可选）
     * @param pageSize 每页条数（可选）
     * @return {@link AdminReportPageResponse} 工单分页
     */
    @GetMapping
    public AdminReportPageResponse list(HttpServletRequest http,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        return adminReportService.list(AdminContext.currentRole(http), status, page, pageSize);
    }

    /**
     * 处理举报工单（{@code POST /admin/reports/{id}/handle}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param reportId 举报 ID
     * @param request 入参（action）
     */
    @PostMapping("/{id}/handle")
    public void handle(HttpServletRequest http, @PathVariable("id") long reportId,
            @Valid @RequestBody AdminReportHandleRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminReportService.handle(role, AdminContext.currentAdminId(http), reportId,
                request.action());
    }

    /**
     * 批量处理举报工单（{@code POST /admin/reports/batch-handle}；PRD §9.10.1 ④「批量处理」）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参（report_ids + action）
     */
    @PostMapping("/batch-handle")
    public void handleBatch(HttpServletRequest http,
            @Valid @RequestBody AdminReportBatchHandleRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminReportService.handleBatch(role, AdminContext.currentAdminId(http), request);
    }
}
