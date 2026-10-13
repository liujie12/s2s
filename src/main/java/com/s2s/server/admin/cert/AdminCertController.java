package com.s2s.server.admin.cert;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.CertReviewPageResponse;
import com.s2s.server.admin.dto.CertReviewRequest;
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
 * 后台认证审核控制器（[153] B2-5 ⑤）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminCertService} 判定（内容审核员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/certs")
public class AdminCertController {

    /** 后台认证审核服务。 */
    private final AdminCertService adminCertService;

    /**
     * 构造后台认证审核控制器。
     *
     * @param adminCertService 后台认证审核服务
     */
    public AdminCertController(AdminCertService adminCertService) {
        this.adminCertService = adminCertService;
    }

    /**
     * 认证审核队列（{@code GET /admin/certs}）。
     *
     * @param http     当前请求（取后台角色）
     * @param status   状态筛选（可选，默认 pending）
     * @param page     页码（可选）
     * @param pageSize 每页条数（可选）
     * @return {@link CertReviewPageResponse} 队列分页
     */
    @GetMapping
    public CertReviewPageResponse list(HttpServletRequest http,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        return adminCertService.listForReview(AdminContext.currentRole(http), status, page, pageSize);
    }

    /**
     * 审核认证（{@code POST /admin/certs/{cert_id}/review}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param certId  认证 ID
     * @param request 入参（approved + reject_reason）
     */
    @PostMapping("/{cert_id}/review")
    public void review(HttpServletRequest http, @PathVariable("cert_id") long certId,
            @Valid @RequestBody CertReviewRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminCertService.review(role, AdminContext.currentAdminId(http), certId, request);
    }
}
