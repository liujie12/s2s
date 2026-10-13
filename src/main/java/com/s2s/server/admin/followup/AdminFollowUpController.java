package com.s2s.server.admin.followup;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminFollowUpHandleRequest;
import com.s2s.server.admin.dto.AdminFollowUpPageResponse;
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
 * 后台待运营跟进队列控制器（[153] B2-5 ⑥）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminFollowUpService} 判定（运营专员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/follow-ups")
public class AdminFollowUpController {

    /** 后台跟进队列服务。 */
    private final AdminFollowUpService adminFollowUpService;

    /**
     * 构造后台跟进队列控制器。
     *
     * @param adminFollowUpService 后台跟进队列服务
     */
    public AdminFollowUpController(AdminFollowUpService adminFollowUpService) {
        this.adminFollowUpService = adminFollowUpService;
    }

    /**
     * 跟进队列（{@code GET /admin/follow-ups}）。
     *
     * @param http     当前请求（取后台角色）
     * @param status   状态筛选（可选，默认 pending）
     * @param page     页码（可选）
     * @param pageSize 每页条数（可选）
     * @return {@link AdminFollowUpPageResponse} 队列分页
     */
    @GetMapping
    public AdminFollowUpPageResponse list(HttpServletRequest http,
            @RequestParam(required = false) String status,
            @RequestParam(required = false) Integer page,
            @RequestParam(name = "page_size", required = false) Integer pageSize) {
        return adminFollowUpService.list(AdminContext.currentRole(http), status, page, pageSize);
    }

    /**
     * 处理（跟进）队列条目（{@code POST /admin/follow-ups/{id}/handle}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param id      条目 ID
     * @param request 入参（remark）
     */
    @PostMapping("/{id}/handle")
    public void handle(HttpServletRequest http, @PathVariable("id") long id,
            @Valid @RequestBody AdminFollowUpHandleRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminFollowUpService.handle(role, AdminContext.currentAdminId(http), id, request.remark());
    }
}
