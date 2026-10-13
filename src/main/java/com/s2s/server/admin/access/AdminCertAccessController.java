package com.s2s.server.admin.access;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminCertAccessContentResponse;
import com.s2s.server.admin.dto.AdminCertAccessCreateRequest;
import com.s2s.server.admin.dto.AdminCertAccessPageResponse;
import com.s2s.server.admin.dto.AdminCertAccessReviewRequest;
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
 * 后台认证原始信息敏感查看「双人复核」控制器（[153] B2-5 §9.10.1；PRD §9.10.1）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 与「发起人≠复核人」
 * 由 {@link AdminCertAccessService} 判定（内容审核员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/cert-access-requests")
public class AdminCertAccessController {

    /** 敏感查看复核服务。 */
    private final AdminCertAccessService adminCertAccessService;

    /**
     * 构造控制器。
     *
     * @param adminCertAccessService 敏感查看复核服务
     */
    public AdminCertAccessController(AdminCertAccessService adminCertAccessService) {
        this.adminCertAccessService = adminCertAccessService;
    }

    /**
     * 发起认证敏感查看申请（{@code POST /admin/cert-access-requests}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参（cert_id + reason）
     */
    @PostMapping
    public void create(HttpServletRequest http,
            @Valid @RequestBody AdminCertAccessCreateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminCertAccessService.create(role, AdminContext.currentAdminId(http), request);
    }

    /**
     * 复核申请列表（{@code GET /admin/cert-access-requests}）。
     *
     * @param http     当前请求（取后台角色）
     * @param status   复核状态筛选（可选，默认不限）
     * @param page     页码（可选）
     * @param pageSize 每页条数（可选）
     * @return {@link AdminCertAccessPageResponse} 列表分页
     */
    @GetMapping
    public AdminCertAccessPageResponse list(HttpServletRequest http,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        return adminCertAccessService.list(AdminContext.currentRole(http), status, page, pageSize);
    }

    /**
     * 复核一条申请（{@code POST /admin/cert-access-requests/{id}/review}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param id      申请 ID
     * @param request 入参（approved + reason；驳回须填 reason）
     */
    @PostMapping("/{id}/review")
    public void review(HttpServletRequest http, @PathVariable("id") long id,
            @Valid @RequestBody AdminCertAccessReviewRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminCertAccessService.review(role, AdminContext.currentAdminId(http), id, request);
    }

    /**
     * 打开认证原始信息（{@code GET /admin/cert-access-requests/{id}/content}）。
     *
     * <p>仅<b>发起人本人</b>且复核通过后可用；本次打开写审计 {@code cert.sensitive_view}。</p>
     *
     * @param http 当前请求（取后台角色/操作人）
     * @param id   申请 ID
     * @return {@link AdminCertAccessContentResponse} 认证记录 ID + 资质图引用
     */
    @GetMapping("/{id}/content")
    public AdminCertAccessContentResponse openContent(HttpServletRequest http,
            @PathVariable("id") long id) {
        OperatorRole role = AdminContext.currentRole(http);
        return adminCertAccessService.openContent(role, AdminContext.currentAdminId(http), id);
    }
}
