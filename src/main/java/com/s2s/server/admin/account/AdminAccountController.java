package com.s2s.server.admin.account;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminAccountCreateRequest;
import com.s2s.server.admin.dto.AdminAccountListResponse;
import com.s2s.server.admin.dto.AdminAccountUpdateRequest;
import com.s2s.server.admin.dto.AdminPasswordResetRequest;
import com.s2s.server.common.audit.OperatorRole;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.Valid;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * 后台账号与角色管理控制器（[153] B2-5；PRD §9.10.1 超管专属）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminAccountService} 判定（**仅超管**，其余 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/accounts")
public class AdminAccountController {

    /** 后台账号服务。 */
    private final AdminAccountService adminAccountService;

    /**
     * 构造后台账号控制器。
     *
     * @param adminAccountService 后台账号服务
     */
    public AdminAccountController(AdminAccountService adminAccountService) {
        this.adminAccountService = adminAccountService;
    }

    /**
     * 账号列表（{@code GET /admin/accounts}）。
     *
     * @param http 当前请求（取后台角色）
     * @return {@link AdminAccountListResponse} 全部账号
     */
    @GetMapping
    public AdminAccountListResponse list(HttpServletRequest http) {
        return adminAccountService.list(AdminContext.currentRole(http));
    }

    /**
     * 新建账号（{@code POST /admin/accounts}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参
     */
    @PostMapping
    public void create(HttpServletRequest http,
            @Valid @RequestBody AdminAccountCreateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminAccountService.create(role, AdminContext.currentAdminId(http), request);
    }

    /**
     * 修改账号角色/状态（{@code PUT /admin/accounts/{id}}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param id      账号 ID
     * @param request 入参（null = 不改）
     */
    @PutMapping("/{id}")
    public void update(HttpServletRequest http, @PathVariable("id") long id,
            @Valid @RequestBody AdminAccountUpdateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminAccountService.update(role, AdminContext.currentAdminId(http), id, request);
    }

    /**
     * 重置口令（{@code POST /admin/accounts/{id}/password}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param id      账号 ID
     * @param request 入参（new_password）
     */
    @PostMapping("/{id}/password")
    public void resetPassword(HttpServletRequest http, @PathVariable("id") long id,
            @Valid @RequestBody AdminPasswordResetRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminAccountService.resetPassword(role, AdminContext.currentAdminId(http), id,
                request.newPassword());
    }
}
