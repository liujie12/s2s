package com.s2s.server.admin.category;

import com.s2s.server.admin.AdminContext;
import com.s2s.server.admin.dto.AdminCategoryCreateRequest;
import com.s2s.server.admin.dto.AdminCategoryListResponse;
import com.s2s.server.admin.dto.AdminCategoryUpdateRequest;
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
 * 后台分类配置控制器（[153] B2-5 ①）。
 *
 * <p>鉴权由 {@link com.s2s.server.admin.AdminInterceptor} 承担；RBAC 由
 * {@link AdminCategoryService} 判定（运营专员/超管，越权 {@code 40305}）。</p>
 */
@RestController
@RequestMapping("/admin/categories")
public class AdminCategoryController {

    /** 后台分类配置服务。 */
    private final AdminCategoryService adminCategoryService;

    /**
     * 构造后台分类配置控制器。
     *
     * @param adminCategoryService 后台分类配置服务
     */
    public AdminCategoryController(AdminCategoryService adminCategoryService) {
        this.adminCategoryService = adminCategoryService;
    }

    /**
     * 分类全量列表（{@code GET /admin/categories}）。
     *
     * @param http 当前请求（取后台角色）
     * @return {@link AdminCategoryListResponse} 全量分类行
     */
    @GetMapping
    public AdminCategoryListResponse list(HttpServletRequest http) {
        return adminCategoryService.list(AdminContext.currentRole(http));
    }

    /**
     * 新增叶子类目（{@code POST /admin/categories}）。
     *
     * @param http    当前请求（取后台角色/操作人）
     * @param request 入参
     */
    @PostMapping
    public void create(HttpServletRequest http,
            @Valid @RequestBody AdminCategoryCreateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminCategoryService.create(role, AdminContext.currentAdminId(http), request);
    }

    /**
     * 更新类目（{@code PUT /admin/categories/{id}}）。
     *
     * @param http       当前请求（取后台角色/操作人）
     * @param categoryId 类目 ID
     * @param request    入参（null 字段 = 不改）
     */
    @PutMapping("/{id}")
    public void update(HttpServletRequest http, @PathVariable("id") int categoryId,
            @Valid @RequestBody AdminCategoryUpdateRequest request) {
        OperatorRole role = AdminContext.currentRole(http);
        adminCategoryService.update(role, AdminContext.currentAdminId(http), categoryId, request);
    }
}
